--!strict
-- Authoritative combat server. Clients predict and claim hits; every claim is checked here before any
-- damage, stun, knockback or block result is applied. Stage 3: M1 combo and blocking.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage.Modules
local Config = require(Modules.Config)
local StateHandler = require(Modules.StateHandler)
local HitboxService = require(Modules.HitboxService)
local Moves = require(Modules.Moves)
local Ragdoll = require(script.Parent.Ragdoll)
local MalevolentShrine = require(script.Parent.MalevolentShrine)

local now = StateHandler.Now

local remotes = Instance.new("Folder")
remotes.Name = "CombatRemotes"
local Input = Instance.new("RemoteEvent")
Input.Name = "Input" -- client -> server: actions and hit claims
Input.Parent = remotes
local Effects = Instance.new("RemoteEvent")
Effects.Name = "Effects" -- server -> clients: swings and hit results for animations and VFX
Effects.Parent = remotes
remotes.Parent = ReplicatedStorage

local COMBO_LENGTH = #Config.M1.Damage

export type Move = {
	Name: string,
	Damage: number,
	Stun: number,
	IsM1: boolean?,
	IsJab: boolean?,
	PerfectBlockable: boolean?, -- perfect block works on it even though it isn't an M1
	GuardBreak: boolean?,
	Knockback: number?, -- studs/s away from the attacker
	Launch: number?, -- studs/s upward; the target is Launched for Stun seconds instead of stunned
	SlamVelocity: number?, -- studs/s downward
	RagdollTime: number?, -- ragdolls the target instead of stunning
	NoCancel: boolean?, -- that ragdoll can't be dashed out of (true downslam)
	UpsideDown: boolean?, -- ignores stun immunity right after the target got up
	UsesBuff: boolean?, -- Critical / Black Flash apply even though it isn't an M1
	WallTrigger: boolean?, -- can start a wall combo
	Shockwave: boolean?,
}

type Swing = { move: Moves.Move, start: number, hits: { [Model]: boolean }, landed: boolean, noCancel: boolean }
type Defense = {
	meter: number,
	meterTime: number,
	buff: string?,
	buffUntil: number,
	chain: number,
	hitCount: number,
	lastHit: number,
	lastJabStun: number,
	jabStunned: boolean, -- the current stun came from a jab (immunity when it runs out)
}
type Dash = { direction: string, start: number, duration: number, jabbed: boolean }

local swings: { [Model]: Swing } = setmetatable({}, { __mode = "k" }) :: any
local defenses: { [Model]: Defense } = setmetatable({}, { __mode = "k" }) :: any
local dashes: { [Model]: Dash } = setmetatable({}, { __mode = "k" }) :: any

local function defenseOf(char: Model): Defense
	local d = defenses[char]
	if not d then
		d = {
			meter = 0,
			meterTime = 0,
			buff = nil,
			buffUntil = 0,
			chain = 0,
			hitCount = 0,
			lastHit = 0,
			lastJabStun = -math.huge,
			jabStunned = false,
		}
		defenses[char] = d
	end
	return d
end

-- Wall combo: armed when a wall-trigger hit pins the target against a wall; a front dash cashes it in.
local wallPending: { [Model]: { target: Model, untilTime: number } } = setmetatable({}, { __mode = "k" }) :: any

local function wallBehind(target: Model, attacker: Model, away: Vector3): boolean
	local rt = HitboxService.RootOf(target)
	if not rt then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { target, attacker, HitboxService.VFXFolder() }
	return workspace:Raycast(rt.Position, away * Config.WallCombo.WallDistance, params) ~= nil
end

local function armWallCombo(attacker: Model, target: Model)
	local untilTime = now() + Config.WallCombo.Window
	wallPending[attacker] = { target = target, untilTime = untilTime }
	attacker:SetAttribute("WallComboUntil", untilTime) -- lets the attacker's client dash out of endlag in time
end

-- Holds a world velocity on a character for `duration` (the target's own client simulates it).
local function push(char: Model, velocity: Vector3, duration: number)
	local root = HitboxService.RootOf(char)
	if not root then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "Knockback"
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = attachment
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = math.huge
	lv.VectorVelocity = velocity
	lv.Parent = attachment
	attachment.Parent = root
	task.delay(duration, function()
		attachment:Destroy()
	end)
end

-- Blocked only when the attacker is in front: dot(defender look, toward attacker) > DotThreshold.
local function blockFaces(defender: Model, attacker: Model): boolean
	local rd, ra = HitboxService.RootOf(defender), HitboxService.RootOf(attacker)
	if not rd or not ra then
		return false
	end
	local toward = (ra.Position - rd.Position) * Vector3.new(1, 0, 1)
	if toward.Magnitude < 1e-3 then
		return true
	end
	local look = rd.CFrame.LookVector * Vector3.new(1, 0, 1)
	return look.Unit:Dot(toward.Unit) > Config.Block.DotThreshold
end

-- Perfect block: Critical, or Black Flash if already buffed and the chain allows it.
local function grantBuff(d: Defense)
	local t = now()
	if t >= d.buffUntil then
		d.buff = nil
		d.chain = 0
	end
	d.buff = if d.buff and d.chain < Config.Block.BlackFlashMaxChain then "BlackFlash" else "Critical"
	d.buffUntil = t + Config.Block.BuffDuration
end

-- The one place a hit is resolved: block, perfect block, block meter, guard break, damage, stun, knockback.
-- Returns "Hit" or "Blocked".
local function resolveHit(attacker: Model, target: Model, move: Move): string
	StateHandler.Ensure(target)
	local t = now()
	local hum = target:FindFirstChildOfClass("Humanoid") :: Humanoid
	local ad, td = defenseOf(attacker), defenseOf(target)
	local kind = "Hit"
	local guardBroken = false

	if StateHandler.Is(target, "Blocking") and blockFaces(target, attacker) then
		if move.GuardBreak then
			guardBroken = true
		elseif (move.IsM1 or move.PerfectBlockable) and t - StateHandler.Number(target, "BlockStartTime") <= Config.Block.PerfectWindow then
			grantBuff(td)
			Effects:FireAllClients("Hit", attacker, target, "PerfectBlock", move.Name)
			return "Blocked"
		else
			td.meter = math.max(0, td.meter - Config.Block.MeterRegen * (t - td.meterTime)) + Config.Block.MeterPerHit
			td.meterTime = t
			if td.meter < Config.Block.MeterMax then
				Effects:FireAllClients("Hit", attacker, target, "Blocked", move.Name)
				return "Blocked"
			end
			td.meter = 0
			StateHandler.SetFlag(target, "Blocking", false)
			StateHandler.Stun(target, Config.Block.GuardBreakStun, true)
			Effects:FireAllClients("Hit", attacker, target, "GuardBreak", move.Name)
			return "Blocked"
		end
	end

	td.hitCount = if t - td.lastHit <= Config.Stun.DecayResetTime then td.hitCount + 1 else 1
	td.lastHit = t
	local damage = move.Damage
	if Config.Stun.DamageDecayEnabled then
		damage *= Config.Stun.DamageDecay ^ (td.hitCount - 1)
	end
	if (move.IsM1 or move.UsesBuff) and ad.buff and t < ad.buffUntil then
		local blackFlash = ad.buff == "BlackFlash"
		if blackFlash and move.UsesBuff then
			damage = Config.Block.BlackFlashHeavyPercent * hum.MaxHealth -- heavy moves deal a flat total
		else
			damage *= if blackFlash then Config.Block.BlackFlashMultiplier else Config.Block.CritMultiplier
		end
		ad.chain = if blackFlash then ad.chain + 1 else 0
		kind = ad.buff :: string
		ad.buff = nil
	end
	if guardBroken then
		kind = "GuardBreak"
		StateHandler.SetFlag(target, "Blocking", false)
	end
	hum:TakeDamage(damage)

	if move.RagdollTime then
		-- upside-down tech: right after getting up, a downslam ignores the get-up immunity
		local tech = move.UpsideDown == true
			and t - StateHandler.Number(target, "GotUpTime") <= Config.Downslam.UpsideDownWindow
		Ragdoll.Apply(target, move.RagdollTime, tech, move.NoCancel)
	elseif move.Launch then
		if not StateHandler.IsStunImmune(target) then
			StateHandler.Interrupt(target)
			StateHandler.SetTimed(target, "Launched", move.Stun)
			td.jabStunned = false
		end
	else
		local stun = if guardBroken then math.max(move.Stun, Config.Block.GuardBreakStun) else move.Stun
		if move.IsJab and t - td.lastJabStun <= Config.Jab.RepeatWindow then
			stun *= Config.Jab.RepeatScale -- anti stun-lock
		end
		if StateHandler.Stun(target, stun) then
			-- only a jab stun that runs out untouched grants immunity; any other stun replaces it
			td.jabStunned = move.IsJab == true
			if move.IsJab then
				td.lastJabStun = t
			end
		end
	end

	local rt, ra = HitboxService.RootOf(target), HitboxService.RootOf(attacker)
	if rt and ra then
		local away = (rt.Position - ra.Position) * Vector3.new(1, 0, 1)
		away = if away.Magnitude > 1e-3 then away.Unit else ra.CFrame.LookVector
		local velocity = away * (move.Knockback or 0)
			+ Vector3.new(0, (move.Launch or 0) - (move.SlamVelocity or 0), 0)
		if velocity.Magnitude > 0 then
			push(target, velocity, Config.Stun.KnockbackTime)
		end
		if move.WallTrigger and wallBehind(target, attacker, away) then
			armWallCombo(attacker, target)
		end
	end
	if move.Shockwave then
		Effects:FireAllClients("Shockwave", target)
	end

	Effects:FireAllClients("Hit", attacker, target, kind, move.Name)
	return "Hit"
end

local AIR_STATES: { [Enum.HumanoidStateType]: boolean } = {
	[Enum.HumanoidStateType.Jumping] = true,
	[Enum.HumanoidStateType.Freefall] = true,
}

local function grounded(char: Model): boolean
	local root = HitboxService.RootOf(char)
	if not root then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char, HitboxService.VFXFolder() }
	return workspace:Raycast(root.Position, Vector3.new(0, -Config.Ragdoll.GroundCheck, 0), params) ~= nil
end

-- Server-side view of "in the air". Vertical speed replicates sooner than position, and the Humanoid state
-- may not replicate at all for a player's character, so any of the three counts.
local function airborne(char: Model): boolean
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = HitboxService.RootOf(char)
	if not hum or not root then
		return false
	end
	return AIR_STATES[hum:GetState()] == true
		or math.abs(root.AssemblyLinearVelocity.Y) > Config.Server.AirSpeed
		or not grounded(char)
end

-- `info` = { jumpHeld, sinceJump } from the client. Those only pick between moves; air/ground, combo
-- position and cooldowns are all checked here.
local function onM1(char: Model, info: any)
	local jumpHeld = type(info) == "table" and info.jumpHeld == true
	local claimedSinceJump = if type(info) == "table" then info.sinceJump else nil
	local clientSinceJump = if type(claimedSinceJump) == "number" and claimedSinceJump == claimedSinceJump
		then math.max(claimedSinceJump, 0)
		else math.huge
	-- side and back dashes don't lock you: an M1 can come out mid-dash while the dash keeps moving
	local dash = dashes[char]
	local outOfSideDash = StateHandler.Is(char, "Dashing")
		and dash ~= nil
		and dash.direction ~= "Front"
		and not StateHandler.Is(char, "Attacking")
		and not StateHandler.IsLocked(char)
	if not (StateHandler.CanAct(char) or outOfSideDash) or StateHandler.Is(char, "Blocking") then
		return
	end
	local t = now()
	if t < StateHandler.Number(char, "M1ReadyTime") then
		return
	end
	if outOfSideDash then
		StateHandler.Clear(char, "Dashing")
	end
	-- spaced clicks keep the combo while the gap stays under ComboResetTime
	local count = StateHandler.Number(char, "ComboCount")
	local stale = t - StateHandler.Number(char, "LastM1Time") > Config.M1.ComboResetTime
	if stale then
		char:SetAttribute("AirThird", false)
	end
	local inAir = airborne(char)
	-- the jump age only matters while the server agrees you're in the air
	local sinceJump = math.min(clientSinceJump, t - StateHandler.Number(char, "JumpTime"))
	local index = if stale or count >= COMBO_LENGTH then 1 else count + 1
	local move = Moves.Choose({
		index = index,
		airborne = inAir,
		jumpHeld = jumpHeld,
		sinceJump = sinceJump,
		comboActive = not stale and count > 0 and count < COMBO_LENGTH,
		recentJab = t - StateHandler.Number(char, "LastJabTime") <= Config.Jab.Stun,
		uppercutReady = t >= StateHandler.Number(char, "UppercutReadyTime"),
		downslamReady = t >= StateHandler.Number(char, "DownslamReadyTime"),
	})
	local total = Moves.Total(move)
	if Config.Server.DebugMoves then
		print(string.format("[M1] %s -> %s (next hit %d, air=%s, jumpHeld=%s, sinceJump=%.2f)",
			char.Name, move.Name, index, tostring(inAir), tostring(jumpHeld), math.min(sinceJump, 99)))
	end

	local noCancel = false
	if move.Index then
		char:SetAttribute("ComboCount", move.Index)
		if move.Index == 3 then
			char:SetAttribute("AirThird", inAir) -- M1, M1, airborne M1, downslam = true downslam
		end
	elseif move == Moves.Downslam then
		noCancel = Config.Downslam.TrueDownslam and char:GetAttribute("AirThird") == true
		char:SetAttribute("DownslamReadyTime", t + Config.Downslam.Cooldown)
		char:SetAttribute("ComboCount", 0)
		char:SetAttribute("AirThird", false)
	elseif move == Moves.Uppercut then
		char:SetAttribute("ComboCount", 0)
	end
	char:SetAttribute("LastM1Time", t)
	char:SetAttribute("BlockReadyTime", t + total + Config.M1.BlockLockout)
	char:SetAttribute("EndlagFrom", t + move.Startup + move.Active) -- any dash may cancel the swing from here
	char:SetAttribute("DashCancelUntil", if move.DashCancel then t + total else 0)
	StateHandler.SetTimed(char, "Attacking", total)
	local swing: Swing = { move = move, start = t, hits = {}, landed = false, noCancel = noCancel }
	swings[char] = swing
	Effects:FireAllClients("Swing", char, move.Name, total)

	task.delay(move.Startup + move.Active + Config.Server.HitGrace, function()
		if swings[char] ~= swing then
			return
		end
		if move.Launch then
			local cooldown = if swing.landed then Config.Uppercut.CooldownHit else Config.Uppercut.CooldownMiss
			char:SetAttribute("UppercutReadyTime", swing.start + cooldown)
		elseif move.Index == COMBO_LENGTH and not swing.landed and StateHandler.Is(char, "Attacking") then
			StateHandler.Stun(char, Config.M1.WhiffStun, true) -- a whiffed finisher leaves the attacker open
		end
	end)
end

-- Validates a client's claim that its current swing hit `target`.
local function onM1Hit(char: Model, target: any)
	if typeof(target) ~= "Instance" or not target:IsA("Model") or target == char then
		return
	end
	local swing = swings[char]
	if not swing or not StateHandler.Is(char, "Attacking") or StateHandler.IsLocked(char) then
		return
	end
	local move = swing.move
	local since = now() - swing.start
	if since < move.Startup * Config.Server.MinStartupFraction or since > move.Startup + move.Active + Config.Server.HitGrace then
		return
	end
	local hum = target:FindFirstChildOfClass("Humanoid")
	if swing.hits[target] or not hum or hum.Health <= 0 or HitboxService.SameTeam(char, target) then
		return
	end
	if HitboxService.Distance(char, target) > Config.Server.MaxHitDistance or not HitboxService.LineOfSight(char, target) then
		return
	end
	if StateHandler.IsInvulnerable(target) then
		return
	end

	swing.hits[target] = true
	resolveHit(char, target, {
		Name = move.Name,
		Damage = move.Damage or (move.Percent :: number) * hum.MaxHealth,
		Stun = move.Stun,
		IsM1 = move.IsM1,
		GuardBreak = move.GuardBreak,
		Knockback = move.Knockback,
		Launch = move.Launch,
		SlamVelocity = move.SlamVelocity,
		RagdollTime = move.RagdollTime,
		NoCancel = swing.noCancel,
		UpsideDown = move.RagdollTime ~= nil and Config.Downslam.UpsideDownTech,
		UsesBuff = move.UsesBuff,
		WallTrigger = move.WallTrigger,
		Shockwave = move.Shockwave,
	})
	swing.landed = true -- a blocked hit still connected, so it isn't a whiff
	if move.Index == COMBO_LENGTH then
		char:SetAttribute("M1ReadyTime", now() + Config.M1.FinisherCooldown)
	end
end

StateHandler.OnExpire.Stunned = function(char: Model)
	local d = defenses[char]
	if d and d.jabStunned then
		d.jabStunned = false
		if Config.Jab.ImmunityAfterEnabled then
			StateHandler.GrantStunImmunity(char, Config.Jab.ImmunityAfter)
		end
	end
end

-- Dashes ----------------------------------------------------------------------

local DIRECTIONS: { [string]: boolean } = { Front = true, Back = true, Left = true, Right = true }

local function dashDuration(direction: string): number
	return if direction == "Front" then Config.Dash.FrontDuration else Config.Dash.SideDuration
end

local WALL_MOVE: Move = {
	Name = "WallCombo",
	Damage = 0, -- set per target from WallCombo.DamagePercent
	Stun = Config.WallCombo.Stun,
}

-- Authorizes a dash. The owning client moves its own character; the server owns cooldowns, i-frames and state.
-- From a ragdoll it is the evasive: any direction, on the ground, not launched, not a no-cancel ragdoll, and
-- on its own long cooldown instead of the dash's. Any dash may cancel a swing's endlag (after its active frames).
local function onDash(char: Model, direction: any)
	if type(direction) ~= "string" or not DIRECTIONS[direction] then
		return
	end
	local t = now()
	local pending = wallPending[char]
	local wall = direction == "Front"
		and pending ~= nil
		and t <= pending.untilTime + Config.Server.HitGrace
		and t >= StateHandler.Number(char, "WallComboReadyTime")
	local dashCancel = direction == "Front" and t <= StateHandler.Number(char, "DashCancelUntil")
	local inEndlag = t >= StateHandler.Number(char, "EndlagFrom")
	local outOfEndlag = StateHandler.Is(char, "Attacking") and not StateHandler.IsLocked(char) and (wall or dashCancel or inEndlag)

	local evasive = StateHandler.Is(char, "Ragdolled")
	if evasive then
		local denied = t < StateHandler.Number(char, "EvasiveReadyTime")
			or StateHandler.Is(char, "Launched")
			or char:GetAttribute("RagdollNoCancel") == true
			or not grounded(char)
		if denied then
			return
		end
	elseif not (StateHandler.CanAct(char) or outOfEndlag) or StateHandler.Is(char, "Blocking") then
		return
	end
	local isSide = direction ~= "Front" -- left, right and back share a cooldown
	local readyName = if isSide then "SideDashReadyTime" else "DashReadyTime"
	if not evasive and t < StateHandler.Number(char, readyName) then
		return
	end
	if evasive then
		Ragdoll.Recover(char) -- joints back and 0.5s stun immunity
		StateHandler.Clear(char, "Stunned")
		StateHandler.SetTimed(char, "IFrames", Config.Ragdoll.EvasiveIFrames)
		char:SetAttribute("EvasiveReadyTime", t + Config.Ragdoll.EvasiveCooldown)
		Effects:FireAllClients("Evasive", char)
	end
	if outOfEndlag then
		StateHandler.Clear(char, "Attacking")
	end
	local duration = dashDuration(direction)
	if not evasive then
		char:SetAttribute(readyName, t + (if isSide then Config.Dash.SideCooldown else Config.Dash.FrontCooldown))
	end
	StateHandler.SetTimed(char, "IFrames", if direction == "Front" then Config.Dash.FrontIFrames else Config.Dash.SideBackIFrames)
	StateHandler.SetTimed(char, "Dashing", duration)
	dashes[char] = { direction = direction, start = t, duration = duration, jabbed = wall }
	Effects:FireAllClients("Dash", char, direction, duration)

	if wall and pending then
		wallPending[char] = nil
		local target = pending.target
		local hum = target:FindFirstChildOfClass("Humanoid")
		local inReach = HitboxService.Distance(char, target) <= Config.WallCombo.MaxRange
			and HitboxService.LineOfSight(char, target)
		if hum and hum.Health > 0 and inReach and not StateHandler.IsInvulnerable(target) then
			local move = table.clone(WALL_MOVE)
			move.Damage = Config.WallCombo.DamagePercent * hum.MaxHealth
			if resolveHit(char, target, move) == "Hit" then
				char:SetAttribute("WallComboReadyTime", t + Config.WallCombo.Cooldown)
			end
		end
	end

	local root = HitboxService.RootOf(char)
	if Config.Dash.Debug and root then
		local cf = root.CFrame
		local vector = ({
			Front = cf.LookVector,
			Back = -cf.LookVector,
			Left = -cf.RightVector,
			Right = cf.RightVector,
		})[direction] * Vector3.new(1, 0, 1)
		local startPos = root.Position
		print(string.format("[Dash] %s dir=%s vector=%s", char.Name, direction, tostring(vector.Unit)))
		task.delay(duration + 0.1, function()
			-- server-side positions trail the owner slightly, so this reads a little short
			print(string.format("[Dash] %s travelled %.1f studs", char.Name, ((root.Position - startPos) * Vector3.new(1, 0, 1)).Magnitude))
		end)
	end
end

-- Validates a client's claim that its front dash ran into `target`.
local function onJabHit(char: Model, target: any)
	if typeof(target) ~= "Instance" or not target:IsA("Model") or target == char then
		return
	end
	local function reject(reason: string)
		if Config.Server.DebugMoves then
			print(string.format("[Jab] %s -> %s rejected: %s", char.Name, target.Name, reason))
		end
	end
	local dash = dashes[char]
	if not dash or dash.direction ~= "Front" or dash.jabbed or StateHandler.IsLocked(char) then
		return reject("no active front dash")
	end
	if now() - dash.start > dash.duration + Config.Server.HitGrace then
		return reject("too late in the dash")
	end
	local hum = target:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 or HitboxService.SameTeam(char, target) or StateHandler.IsInvulnerable(target) then
		return reject("target dead, teammate or in i-frames")
	end
	-- Your client moves your own character, so the server's copy of you trails the dash. Allow the distance the
	-- dash can cover in HitGrace seconds on top of the normal reach, or fast dashes get their hits thrown away.
	local reach = Config.Server.MaxHitDistance + Config.Dash.FrontStartSpeed * Config.Server.HitGrace
	local distance = HitboxService.Distance(char, target)
	if distance > reach then
		return reject(string.format("too far (%.1f > %.1f studs)", distance, reach))
	end
	if not HitboxService.LineOfSight(char, target) then
		return reject("no line of sight")
	end

	dash.jabbed = true
	local close = distance <= Config.Jab.CloseRange
	local result = resolveHit(char, target, {
		Name = "DashJab",
		Damage = (if close then Config.Jab.ClosePercent else Config.Jab.DamagePercent) * hum.MaxHealth,
		Stun = Config.Jab.Stun,
		IsJab = true,
		PerfectBlockable = true,
		Knockback = if close and Config.Jab.CloseKnockback then Config.Jab.CloseKnockbackSpeed else nil,
	})
	-- the jab ends the dash; a blocked jab leaves the attacker open, a landed one lets follow-ups start at hit 1
	StateHandler.Clear(char, "Dashing")
	char:SetAttribute("ComboCount", 0)
	if result == "Hit" then
		char:SetAttribute("LastJabTime", now()) -- a jump + click inside the jab stun is the mini uppercut
	elseif result == "Blocked" then
		StateHandler.SetTimed(char, "Attacking", Config.Jab.BlockedRecovery)
		char:SetAttribute("EndlagFrom", now() + Config.Jab.BlockedRecovery) -- a blocked jab can't be dashed out of
	end
	Effects:FireAllClients("Swing", char, "DashJab", Config.Jab.Startup + Config.Jab.Active + Config.Jab.Endlag)
end

local function onBlock(char: Model, holding: any)
	if type(holding) ~= "boolean" then
		return
	end
	if not holding then
		StateHandler.SetFlag(char, "Blocking", false)
	elseif StateHandler.CanAct(char) and now() >= StateHandler.Number(char, "BlockReadyTime") then
		char:SetAttribute("BlockStartTime", now())
		StateHandler.SetFlag(char, "Blocking", true)
	end
end

-- Anti-spam: fixed one-second window per player.
local budget: { [Player]: { count: number, start: number } } = {}

local function allow(player: Player): boolean
	local t = os.clock()
	local b = budget[player]
	if not b or t - b.start >= 1 then
		budget[player] = { count = 1, start = t }
		return true
	end
	b.count += 1
	return b.count <= Config.Server.RateLimit
end

Input.OnServerEvent:Connect(function(player: Player, action: any, arg: any)
	if not allow(player) or type(action) ~= "string" then
		return
	end
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	if not char or not hum or hum.Health <= 0 then
		return
	end
	StateHandler.Ensure(char)
	if action == "M1" then
		onM1(char, arg)
	elseif action == "M1Hit" then
		onM1Hit(char, arg)
	elseif action == "Block" then
		onBlock(char, arg)
	elseif action == "Dash" then
		onDash(char, arg)
	elseif action == "JabHit" then
		onJabHit(char, arg)
	elseif action == "Skill" and arg == "MalevolentShrine" then
		if Config.Server.DebugMoves then
			print("[Shrine] server got the skill input from " .. player.Name)
		end
		MalevolentShrine.Cast(char) -- validates state, cooldown and one-at-a-time itself
	end
end)

Players.PlayerRemoving:Connect(function(player)
	budget[player] = nil
end)

-- Records when each character leaves the ground by jumping (the uppercut input window starts there).
local function trackJumps(char: Model)
	local hum = char:WaitForChild("Humanoid") :: Humanoid
	hum.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Jumping then
			char:SetAttribute("JumpTime", now())
		end
	end)
end
local function onPlayerAdded(player: Player)
	player.CharacterAdded:Connect(trackJumps)
	if player.Character then
		task.spawn(trackJumps, player.Character)
	end
end
Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in Players:GetPlayers() do
	onPlayerAdded(player)
end

-- Resolves hits between two throwaway rigs and checks the block, perfect block and guard break rules.
local function selfTest()
	local function rig(position: Vector3, look: Vector3): Model
		local model = Instance.new("Model")
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Anchored = true
		root.CFrame = CFrame.lookAt(position, position + look)
		root.Parent = model
		Instance.new("Humanoid").Parent = model
		StateHandler.Init(model)
		return model
	end
	local attacker = rig(Vector3.new(0, 0, 0), Vector3.new(0, 0, -1))
	local target = rig(Vector3.new(0, 0, -3), Vector3.new(0, 0, 1)) -- facing the attacker
	local targetHum = target:FindFirstChildOfClass("Humanoid") :: Humanoid
	local jab: Move = { Name = "Test", Damage = 3, Stun = 0.45, IsM1 = true }

	local ok, err = pcall(function()
		assert(resolveHit(attacker, target, jab) == "Hit" and targetHum.Health == 97, "a plain hit deals damage")
		assert(StateHandler.Is(target, "Stunned"), "a plain hit stuns")
		StateHandler.Clear(target, "Stunned")

		target:SetAttribute("BlockStartTime", now() - 1)
		StateHandler.SetFlag(target, "Blocking", true)
		assert(resolveHit(attacker, target, jab) == "Blocked" and targetHum.Health == 97, "a front block takes no damage")

		target:SetAttribute("BlockStartTime", now())
		resolveHit(attacker, target, jab)
		assert(defenseOf(target).buff == "Critical", "a perfect block grants Critical")

		local finisher: Move = { Name = "Test4", Damage = 4, Stun = 0.6, IsM1 = true, GuardBreak = true }
		target:SetAttribute("BlockStartTime", now() - 1)
		assert(resolveHit(attacker, target, finisher) == "Hit", "a guard breaker goes through block")
		assert(not StateHandler.Is(target, "Blocking") and StateHandler.Is(target, "Stunned"), "guard break drops the block and stuns")
		StateHandler.Clear(target, "Stunned")

		local jabMove: Move = { Name = "TestJab", Damage = 4, Stun = Config.Jab.Stun, IsJab = true, PerfectBlockable = true }
		local before = now()
		resolveHit(attacker, target, jabMove)
		local firstEnd = StateHandler.Number(target, "StunEndTime") - before
		assert(math.abs(firstEnd - Config.Jab.Stun) < 0.05, "first jab stuns for the full duration")
		StateHandler.Clear(target, "Stunned")
		resolveHit(attacker, target, jabMove)
		local secondEnd = StateHandler.Number(target, "StunEndTime") - now()
		assert(math.abs(secondEnd - Config.Jab.Stun * Config.Jab.RepeatScale) < 0.05, "a repeat jab within the window is halved")
		StateHandler.Clear(target, "Stunned")

		target:SetAttribute("BlockStartTime", now() - 1)
		StateHandler.SetFlag(target, "Blocking", true)
		local up: Move = { Name = "TestUp", Damage = 5, Stun = 1.2, GuardBreak = true, Launch = 48 }
		assert(resolveHit(attacker, target, up) == "Hit" and StateHandler.Is(target, "Launched"), "uppercut breaks block and launches")
		StateHandler.Clear(target, "Launched")

		local ad = defenseOf(attacker)
		ad.buff, ad.buffUntil = "BlackFlash", now() + 4
		local before = targetHum.Health
		local slam: Move = { Name = "TestSlam", Damage = 6, Stun = 0, RagdollTime = 2, NoCancel = true, UsesBuff = true }
		resolveHit(attacker, target, slam)
		assert(StateHandler.Is(target, "Ragdolled") and target:GetAttribute("RagdollNoCancel") == true, "true downslam ragdolls with no cancel")
		local dealt = before - targetHum.Health
		assert(math.abs(dealt - Config.Block.BlackFlashHeavyPercent * targetHum.MaxHealth) < 1e-3, "heavy Black Flash deals a flat 24%")
		Ragdoll.Recover(target)
	end)
	attacker:Destroy()
	target:Destroy()
	if not ok then
		error(err, 0)
	end
end

local passed, failure = pcall(function()
	StateHandler.SelfTest()
	HitboxService.SelfTest()
	Ragdoll.SelfTest()
	MalevolentShrine.SelfTest()
	selfTest()
end)
if passed then
	print("[CombatServer] self-tests passed")
else
	warn("[CombatServer] SELF-TEST FAILED: " .. tostring(failure))
end
MalevolentShrine.Init(Effects)
StateHandler.Start()
