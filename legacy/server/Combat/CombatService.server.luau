-- Server-authoritative combat: validates client inputs, runs moves and resolves hits.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local MarketplaceService = game:GetService("MarketplaceService")

local Config = require(ReplicatedStorage.Combat.Config)
local StateMachine = require(script.Parent.StateMachine)
local Hitbox = require(script.Parent.Hitbox)
local Ragdoll = require(script.Parent.Ragdoll)

local now = StateMachine.Now

local Input = Instance.new("RemoteEvent")
Input.Name = "Input"
Input.Parent = ReplicatedStorage.Combat
local FX = Instance.new("RemoteEvent")
FX.Name = "FX"
FX.Parent = ReplicatedStorage.Combat

local JAB = Config.Moves.DashJab
local JAB_CLOSE = table.clone(JAB)
JAB_CLOSE.Percent = Config.DashJab.ClosePercent
JAB_CLOSE.Knockback = if Config.DashJab.Knockback then Config.DashJab.CloseKnockback else nil
local TRUE_DOWNSLAM = table.clone(Config.Moves.Downslam)
TRUE_DOWNSLAM.NoCancel = true
local WALL_MOVE = {
	Name = "WallCombo",
	Percent = Config.WallCombo.DamagePercent,
	Stun = Config.WallCombo.Stun,
	FXKind = "WallCombo",
}

local function sideDashScale(healthFraction: number)
	local min = Config.Dash.SideMinScale
	return min + (1 - min) * math.clamp(healthFraction, 0, 1)
end

local function stunDecay(consecutiveHits: number)
	if not Config.Stun.DecayEnabled then
		return 1
	end
	return math.max(Config.Stun.DecayMinScale, 1 - Config.Stun.DecayPerHit * (consecutiveHits - 1))
end

-- Self-checks: fail loudly at startup if the helpers or Config drift.
assert(math.abs(sideDashScale(1) - 1) < 1e-6, "side dash should be full length at full health")
assert(math.abs(sideDashScale(0) - Config.Dash.SideMinScale) < 1e-6, "side dash should bottom out at SideMinScale")
assert(math.abs(sideDashScale(0.5) - (Config.Dash.SideMinScale + 1) / 2) < 1e-6, "side dash scale should be linear")
assert(stunDecay(1) == 1, "first hit must keep full stun")
assert(stunDecay(1000) == (if Config.Stun.DecayEnabled then Config.Stun.DecayMinScale else 1), "stun decay floor")
for _, kind in { "Front", "Back", "Side" } do
	assert(Config.Dash[kind .. "Duration"] > Config.MaxLatencyComp, kind .. "Duration must exceed MaxLatencyComp")
end
assert(Config.Dash.FrontDistance > Config.Dash.SideDistance, "front dash must travel further than side dash")
assert(#Config.M1.Hits == 4, "M1 combo is a 4-hit string")
assert(Config.Moves.Downslam.TrueAfterHits < #Config.M1.Hits, "true downslam must be reachable before the string ends")
assert(Config.M1.Hits[1].Stun > Config.M1.Hits[1].Startup + Config.M1.Hits[1].Active + Config.M1.Hits[1].Endlag,
	"M1 stun must outlast a swing or the string drops")
assert(Config.DashJab.Window < Config.Dash.FrontDuration, "jab window must fit inside the front dash")
assert(Config.Moves.MiniUppercut.Endlag <= Config.Moves.Uppercut.Endlag, "mini uppercut endlag must stay short for the dash tech")
assert(TRUE_DOWNSLAM.NoCancel and not Config.Moves.Downslam.NoCancel, "only the true downslam blocks ragdoll cancel")
assert(JAB_CLOSE.Percent > JAB.Percent and JAB.IsJab and not JAB.GuardBreak, "close jab hits harder and is never a guard breaker")

-- Holds a world-space velocity on a character's root for `duration` seconds.
-- Returns the attachment; destroying it removes the LinearVelocity too.
local function push(char: Model, velocity: Vector3, duration: number)
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	local attachment = Instance.new("Attachment")
	attachment.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = attachment
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = math.huge
	lv.VectorVelocity = velocity
	lv.Parent = attachment
	task.delay(duration, function()
		attachment:Destroy()
	end)
	return attachment
end

-- Closest living enemy within `range` studs, or nil.
local function nearestEnemy(char: Model, range: number)
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then
		return nil
	end
	local best, bestDistance = nil, range
	for _, other in Hitbox.Query(char, { Size = Vector3.one * range * 2, Offset = Vector3.zero }) do
		local distance = (other.HumanoidRootPart.Position - root.Position).Magnitude
		if distance <= bestDistance then
			best, bestDistance = other, distance
		end
	end
	return best
end

local function facing(char: Model, other: Model)
	local a, b = char:FindFirstChild("HumanoidRootPart"), other:FindFirstChild("HumanoidRootPart")
	if not a or not b then
		return false
	end
	local to = (b.Position - a.Position) * Vector3.new(1, 0, 1)
	if to.Magnitude < 1e-3 then
		return true
	end
	return a.CFrame.LookVector:Dot(to.Unit) >= math.cos(math.rad(Config.Block.Arc / 2))
end

local function maxChain(char: Model)
	local player = Players:GetPlayerFromCharacter(char)
	if player and player:GetAttribute("BlackFlashPass") then
		return Config.Block.BlackFlashMaxChainPass
	end
	return Config.Block.BlackFlashMaxChain
end

-- Perfect block: Critical, or Black Flash if already buffed and the chain allows it.
local function grantBuff(char: Model, d)
	local t = now()
	if t >= d.BuffUntil then
		d.Buff = nil
		d.BlackFlashChain = 0
	end
	d.Buff = if d.Buff and d.BlackFlashChain < maxChain(char) then "BlackFlash" else "Critical"
	d.BuffUntil = t + Config.Block.BuffDuration
end

local function ragdoll(char: Model, duration: number)
	if StateMachine.Set(char, "Ragdolled", duration) then
		Ragdoll.Start(char)
	end
end

StateMachine.OnExit.Ragdolled = function(char, d)
	Ragdoll.Stop(char)
	d.NoCancel = false
	d.GotUpAt = now()
	d.StunImmuneUntil = d.GotUpAt + Config.Ragdoll.ImmunityAfter
end

-- A jab stun that runs out without a follow-up refreshing it grants a short immunity.
StateMachine.OnExit.Stunned = function(_, d)
	if d.JabStunned then
		d.JabStunned = false
		if Config.DashJab.ImmunityAfterEnabled then
			d.StunImmuneUntil = now() + Config.DashJab.ImmunityAfter
		end
	end
end

-- The single place a hit is resolved: block, perfect block, guard, damage, stun, knockback, ragdoll, wall trigger.
-- Returns "Hit", "Blocked", or nil when nothing connected.
local function ApplyHit(attacker: Model, target: Model, move)
	local ad, td = StateMachine.Get(attacker), StateMachine.Get(target)
	local hum = target:FindFirstChildOfClass("Humanoid")
	local aRoot, tRoot = attacker:FindFirstChild("HumanoidRootPart"), target:FindFirstChild("HumanoidRootPart")
	if not (ad and td and hum and aRoot and tRoot) or td.State == "Dead" then
		return nil
	end
	local t = now()
	if t < td.IFrameUntil or target:FindFirstChildOfClass("ForceField") then
		return nil
	end

	local distance = (tRoot.Position - aRoot.Position).Magnitude
	local guardBreak = move.GuardBreak and (not move.GuardBreakRange or distance <= move.GuardBreakRange)
	local wasBlocking = td.State == "Blocking" and facing(target, attacker)

	if wasBlocking and not guardBreak then
		if (move.IsM1 or move.PerfectBlockable) and t - td.BlockStart <= Config.Block.PerfectWindow then
			grantBuff(target, td)
			FX:FireAllClients("Hit", attacker, target, "PerfectBlock")
			return "Blocked"
		end
		td.Guard = math.max(0, td.Guard - Config.Block.GuardRegen * (t - td.GuardTime)) + Config.Block.GuardPerHit
		td.GuardTime = t
		if td.Guard >= Config.Block.GuardMax then
			td.Guard = 0
			StateMachine.Set(target, "Stunned", Config.Block.GuardBreakStun)
			FX:FireAllClients("Hit", attacker, target, "GuardBreak")
		else
			FX:FireAllClients("Hit", attacker, target, "Blocked")
		end
		return "Blocked"
	end

	td.HitCount = if t - td.LastHitTime <= Config.Stun.DecayResetTime then td.HitCount + 1 else 1
	td.LastHitTime = t

	local damage = move.Damage or move.Percent * hum.MaxHealth
	if Config.Combo.DamageDecayEnabled then
		damage *= Config.Combo.DamageDecay ^ (td.HitCount - 1)
	end
	local kind = move.FXKind or (if wasBlocking then "GuardBreak" else "Hit")
	if (move.IsM1 or move.UsesBuff) and ad.Buff and t < ad.BuffUntil then
		local blackFlash = ad.Buff == "BlackFlash"
		if blackFlash and move.BlackFlashPercent then
			damage = move.BlackFlashPercent * hum.MaxHealth
		else
			damage *= if blackFlash then Config.Block.BlackFlashMultiplier else Config.Block.CritMultiplier
		end
		ad.BlackFlashChain = if blackFlash then ad.BlackFlashChain + 1 else 0
		kind = ad.Buff
		ad.Buff = nil
	end
	hum:TakeDamage(damage)

	-- upside-down tech: a downslam right as the target gets up ignores their stun immunity
	local freshTech = move.UpsideDownTech and t - td.GotUpAt <= move.UpsideDownWindow
	local immune = t < td.StunImmuneUntil and not freshTech

	if td.State ~= "Ragdolled" and not immune then
		local stun = move.Stun * stunDecay(td.HitCount)
		if move.IsJab and t - td.LastJabStunAt <= Config.DashJab.RepeatWindow then
			stun *= Config.DashJab.RepeatScale -- anti stun-lock
		end
		if wasBlocking then
			stun = math.max(stun, Config.Block.GuardBreakStun)
		end
		-- set before the state change so OnExit.Stunned sees whether the old stun was a jab's
		td.JabStunned = move.IsJab == true
		if move.IsJab then
			td.LastJabStunAt = t
		end
		local state = if move.LaunchHeight then "Launched" else "Stunned"
		-- never shorten a longer stun that is already running
		if not ((td.State == "Stunned" or td.State == "Launched") and td.Until > t + stun) then
			StateMachine.Set(target, state, stun)
		end
	end

	local away = (tRoot.Position - aRoot.Position) * Vector3.new(1, 0, 1)
	away = if away.Magnitude > 1e-3 then away.Unit else aRoot.CFrame.LookVector
	if move.WallTrigger and Hitbox.WallBehind(target, away, Config.WallCombo.Distance, { attacker, target }) then
		ad.WallTarget = target
		ad.WallUntil = t + Config.WallCombo.Window
	end
	-- LaunchHeight: a short upward kick sized so gravity tops out at that height
	local up = if move.LaunchHeight then math.sqrt(2 * workspace.Gravity * move.LaunchHeight) else move.Launch or 0
	if move.Knockback or up ~= 0 then
		local hold = if move.LaunchHeight then Config.Stun.LaunchHold else Config.Stun.KnockbackTime
		push(target, away * (move.Knockback or 0) + Vector3.new(0, up, 0), hold)
	end
	if move.Ragdoll and hum.Health > 0 and not immune then
		local duration = move.RagdollDuration or Config.Ragdoll.Duration
		if move.LaunchHeight then
			-- launched: the ragdoll lasts the flight (up and back down) plus RagdollDuration on the ground
			duration += 2 * math.sqrt(2 * move.LaunchHeight / workspace.Gravity)
		end
		ragdoll(target, duration)
		td.NoCancel = move.NoCancel == true
	end
	if move.Shockwave then
		FX:FireAllClients("Shockwave", target)
	end

	FX:FireAllClients("Hit", attacker, target, kind)
	return "Hit"
end

-- Startup, then the active window (one hit per target). Returns landed, token; token is nil if interrupted.
local function runMove(char: Model, move)
	local token = StateMachine.Set(char, "Attacking")
	if not token then
		return false, nil
	end
	-- everyone gets it: uploaded animations play on the owner only, code-driven poses run on every client
	FX:FireAllClients("Swing", char, move.Name)

	-- the client's "Hit" marker may open the hitbox early, never before MarkerEarliest of Startup; no marker = full Startup
	local d = StateMachine.Get(char)
	local swingStart = now()
	repeat
		RunService.Heartbeat:Wait()
		local elapsed = now() - swingStart
		local marker = d.MarkerToken == token and elapsed >= move.Startup * Config.M1.MarkerEarliest
	until elapsed >= move.Startup or marker or not StateMachine.Valid(char, token)
	if not StateMachine.Valid(char, token) then
		return false, nil
	end

	local hitSet, landed = {}, false
	local stop = now() + move.Active
	repeat
		for _, target in Hitbox.Query(char, move.Hitbox) do
			if not hitSet[target] then
				hitSet[target] = true
				-- a failing hit must not kill this thread, or the attacker stays stuck in Attacking forever
				local ok, result = pcall(ApplyHit, char, target, move)
				if not ok then
					warn("[Combat] ApplyHit failed:", result)
				end
				landed = (ok and result ~= nil) or landed
			end
		end
		RunService.Heartbeat:Wait()
	until now() >= stop or not StateMachine.Valid(char, token)

	if not StateMachine.Valid(char, token) then
		return landed, nil
	end
	return landed, token
end

local function finishMove(char: Model, d, move, token: number)
	if move.DashCancel then
		d.DashCancelToken = token -- a front dash may cut this endlag short (uppercut dash tech)
	end
	task.wait(move.Endlag)
	if StateMachine.Valid(char, token) then
		StateMachine.Set(char, "Idle")
		d.LastSwingEnd = now()
		d.BlockLockUntil = d.LastSwingEnd + Config.M1.BlockLockout
	end
end

local function grounded(char: Model)
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }
	return workspace:Raycast(root.Position, Vector3.new(0, -Config.Dash.GroundCheck, 0), params) ~= nil
end

local AIR_STATES = { [Enum.HumanoidStateType.Jumping] = true, [Enum.HumanoidStateType.Freefall] = true }

-- Airborne by the replicated humanoid state, or by having no floor under the root.
local function airborne(char: Model)
	local hum = char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil and (AIR_STATES[hum:GetState()] == true or not grounded(char))
end

-- Records when the server sees the character start a jump (the uppercut input window starts there).
local function trackJumps(char: Model, d)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if d.JumpConn or not hum then
		return
	end
	d.JumpConn = hum.StateChanged:Connect(function(_, new)
		if new == Enum.HumanoidStateType.Jumping then
			d.JumpAt = now()
		end
	end)
end

-- fromCombo: the 4th hit with jump held (always the full uppercut). Otherwise a jab follow-up gets the mini.
local function onUppercut(char: Model, d, t: number, fromCombo: boolean)
	local mini = not fromCombo and t - d.LastJabAt <= Config.Moves.DashJab.Stun
	local move = if mini then Config.Moves.MiniUppercut else Config.Moves.Uppercut
	local landed, token = runMove(char, move)
	d.UppercutReady = now() + (if landed then move.CooldownHit else move.CooldownMiss)
	if not mini then
		d.Combo = 0
		d.M1Ready = now() + move.M1Lockout
	end
	if token then
		finishMove(char, d, move, token)
	end
end

local function onDownslam(char: Model, d)
	local base = Config.Moves.Downslam
	local move = if base.TrueDownslam and d.Combo >= base.TrueAfterHits then TRUE_DOWNSLAM else base
	d.Combo = 0
	d.DownslamReady = now() + move.Cooldown
	d.M1Ready = now() + move.M1Lockout
	local _, token = runMove(char, move)
	if token then
		finishMove(char, d, move, token)
	end
end

local function onM1(char: Model, d, jumpHeld)
	local t = now()
	-- an M1 may cancel a side dash; front/back dashes have their own jab
	local sideDash = d.State == "Dashing" and (d.DashDirection == "Left" or d.DashDirection == "Right")
	if not (d.State == "Idle" or sideDash) or t < d.M1Ready then
		return
	end
	-- delayed M1s keep the combo as long as the gap stays under ComboResetTime
	if t - d.LastSwingEnd > Config.M1.ComboResetTime then
		d.Combo = 0
	end

	-- context moves, validated from server-side state; jumpHeld is only which input the player chose
	local inAir = airborne(char)
	local nextIndex = d.Combo % #Config.M1.Hits + 1
	if inAir then
		if d.Combo == 0 and t - d.JumpAt <= Config.Moves.Uppercut.InputWindow then
			-- jump then click right away, from neutral: uppercut opener
			if t >= d.UppercutReady then
				return onUppercut(char, d, t, false)
			end
		elseif t >= d.DownslamReady then
			-- in the air after that window, or a fresh jump mid-combo: downslam
			return onDownslam(char, d)
		end
	elseif jumpHeld == true and nextIndex == #Config.M1.Hits and t >= d.UppercutReady then
		return onUppercut(char, d, t, true) -- holding jump turns the 4th hit into an uppercut
	end

	d.Combo = nextIndex
	local index = d.Combo
	local move = Config.M1.Hits[index]

	local landed, token = runMove(char, move)
	if not token then
		return
	end
	if index == #Config.M1.Hits then
		d.Combo = 0
		if not landed then
			StateMachine.Set(char, "Stunned", Config.M1.WhiffStun)
			return
		end
		d.M1Ready = now() + Config.M1.FinisherCooldown
	end
	finishMove(char, d, move, token)
end

local function onSkill(char: Model, d, name)
	local move = type(name) == "string" and Config.Skills[name]
	local t = now()
	if not move or d.State ~= "Idle" or t < (d.SkillReady[name] or 0) then
		return
	end
	d.SkillReady[name] = t + move.Cooldown
	local _, token = runMove(char, move)
	if token then
		finishMove(char, d, move, token)
	end
end

local function onBlock(char: Model, d, holding)
	if holding == true then
		if d.State == "Idle" and now() >= d.BlockLockUntil then
			d.BlockStart = now()
			StateMachine.Set(char, "Blocking")
		end
	elseif d.State == "Blocking" then
		StateMachine.Set(char, "Idle")
	end
end

local DASH_DIRECTIONS = { Front = true, Back = true, Left = true, Right = true }

local function onDash(char: Model, d, direction, clientTime, clientYaw)
	if type(direction) ~= "string" or not DASH_DIRECTIONS[direction] then
		return
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if not hum or not root then
		return
	end

	local t = now()
	-- latency compensation: trust the client clock by at most MaxLatencyComp (NaN rejected by the self-compare)
	local lag = if type(clientTime) == "number" and clientTime == clientTime
		then math.clamp(t - clientTime, 0, Config.MaxLatencyComp)
		else 0
	local start = t - lag
	local isSide = direction == "Left" or direction == "Right"
	local readyKey = if isSide then "SideDashReady" else "DashReady"
	if start < d[readyKey] then
		return
	end

	local wallTarget = d.WallTarget
	local wallCombo = direction == "Front" and wallTarget ~= nil and start <= d.WallUntil and t >= d.WallReady
	local dashCancel = direction == "Front" and d.DashCancelToken == d.Token -- uppercut dash tech
	if d.State == "Ragdolled" then
		-- ragdoll cancel: side or back only, on the ground, and never out of a true downslam
		if direction == "Front" or d.NoCancel or not grounded(char) then
			return
		end
	elseif not (d.State == "Idle" or (d.State == "Attacking" and (wallCombo or dashCancel))) then
		return -- Stunned and Launched cover "no dash while stunned or airborne-launched"
	end

	-- Facing = the yaw the client saw when Q was pressed. The replicated root rotation lags a camera turn,
	-- which made side dashes go the old way. Any yaw is fair: the player could turn the camera there anyway.
	local yawOk = type(clientYaw) == "number" and clientYaw == clientYaw and math.abs(clientYaw) <= 2 * math.pi
	local cf = if yawOk then CFrame.fromEulerAnglesYXZ(0, clientYaw, 0) else root.CFrame
	local dirVector = ({
		Front = cf.LookVector,
		Back = -cf.LookVector,
		Left = -cf.RightVector,
		Right = cf.RightVector,
	})[direction] * Vector3.new(1, 0, 1)
	if dirVector.Magnitude < 1e-3 then
		return
	end
	dirVector = dirVector.Unit

	local token = StateMachine.Set(char, "Dashing")
	if not token then
		return
	end
	d.DashDirection = direction
	d[readyKey] = start + (if isSide then Config.Dash.SideCooldown else Config.Dash.ForwardCooldown)
	d.IFrameUntil = start + Config.Dash.IFrames

	-- distance is decided here, never by the client, so a spoofed dash can't travel further
	local kind = if isSide then "Side" else direction
	local distance = Config.Dash[kind .. "Distance"] * Config.TileSize
	if isSide then
		distance *= sideDashScale(hum.Health / hum.MaxHealth)
	end
	local travel = Config.Dash[kind .. "Duration"] - lag
	local orbitTarget = if isSide and Config.Dash.OrbitRange > 0 then nearestEnemy(char, Config.Dash.OrbitRange) else nil
	if Config.Dash.Debug then
		print(string.format("[Dash] %s dir=%s vector=%s distance=%.2f studs travel=%.3fs lag=%.3fs orbit=%s",
			char.Name, direction, tostring(dirVector), distance, travel, lag, if orbitTarget then orbitTarget.Name else "none"))
	end

	local player = Players:GetPlayerFromCharacter(char)
	if player then
		-- the owner simulates its own character, so it applies the velocity; speed, time and target are decided here
		FX:FireClient(player, "DashGo", dirVector, distance / travel, travel, orbitTarget, direction)
		FX:FireClient(player, "Cooldown", readyKey, d[readyKey])
	end
	FX:FireAllClients("Dash", char, direction)

	if wallCombo then
		d.WallTarget = nil
		local tRoot = wallTarget:FindFirstChild("HumanoidRootPart")
		if tRoot and (tRoot.Position - root.Position).Magnitude <= Config.WallCombo.MaxRange then
			if ApplyHit(char, wallTarget, WALL_MOVE) == "Hit" then
				d.WallReady = t + Config.WallCombo.Cooldown
			end
		end
	end

	local hitSet = { [wallTarget or char] = true }
	local stop = t + travel
	local startPos, speed = root.Position, distance / travel
	while StateMachine.Valid(char, token) and now() < stop do
		if direction == "Front" and now() - start <= Config.DashJab.Window then
			-- the owner moves its own character, so the server's copy lags behind the dash;
			-- aim the jab where the dash should be by now along its starting direction
			local along = dirVector * (speed * math.min(now() - t, travel))
			local origin = CFrame.lookAt(startPos + along, startPos + along + dirVector)
			for _, target in Hitbox.Query(char, Config.DashJab.Hitbox, origin) do
				local tRoot = target:FindFirstChild("HumanoidRootPart")
				if not hitSet[target] and tRoot then
					hitSet[target] = true
					local close = (tRoot.Position - root.Position).Magnitude <= Config.DashJab.CloseRange
					local ok, result = pcall(ApplyHit, char, target, if close then JAB_CLOSE else JAB)
					if not ok then
						warn("[Combat] ApplyHit failed:", result)
					elseif result then
						-- the jab ends the dash: short recovery on hit, a punishable one when blocked
						d.Combo = 0 -- follow-up M1s start at hit 1
						if result == "Hit" then
							d.LastJabAt = now()
						end
						local recovery = if result == "Hit" then Config.DashJab.HitRecovery else Config.DashJab.BlockedRecovery
						StateMachine.Set(char, "Attacking", recovery)
						FX:FireAllClients("Swing", char, JAB.Name)
						break
					end
				end
			end
		end
		RunService.Heartbeat:Wait()
	end

	if StateMachine.Valid(char, token) then
		StateMachine.Set(char, "Idle")
	end
end

-- Anti-spam: fixed one-second window per player.
local budget = {} -- [Player] = { count, windowStart }

local function allow(player: Player)
	local t = os.clock()
	local b = budget[player]
	if not b or t - b[2] >= 1 then
		budget[player] = { 1, t }
		return true
	end
	b[1] += 1
	return b[1] <= Config.RemoteRateLimit
end

Input.OnServerEvent:Connect(function(player, action, a, b, c)
	if not allow(player) then
		return
	end
	local char = player.Character
	local d = char and StateMachine.Get(char)
	if not d or d.State == "Dead" then
		return
	end
	trackJumps(char, d)
	if action == "M1" then
		onM1(char, d, a)
	elseif action == "Block" then
		onBlock(char, d, a)
	elseif action == "Dash" then
		onDash(char, d, a, b, c)
	elseif action == "Skill" then
		onSkill(char, d, a)
	elseif action == "Marker" and d.State == "Attacking" then
		d.MarkerToken = d.Token
	end
end)

local function onCharacter(char: Model)
	char:WaitForChild("Humanoid")
	local d = StateMachine.Get(char)
	if d then
		trackJumps(char, d) -- before the first jump, so the first uppercut input counts
	end
end

local function onPlayer(player: Player)
	player.CharacterAdded:Connect(onCharacter)
	if player.Character then
		task.spawn(onCharacter, player.Character)
	end
	if Config.Block.GamepassId == 0 then
		return
	end
	local ok, owns = pcall(MarketplaceService.UserOwnsGamePassAsync, MarketplaceService, player.UserId, Config.Block.GamepassId)
	player:SetAttribute("BlackFlashPass", ok and owns)
end

Players.PlayerAdded:Connect(onPlayer)
for _, player in Players:GetPlayers() do
	task.spawn(onPlayer, player)
end
Players.PlayerRemoving:Connect(function(player)
	budget[player] = nil
end)
