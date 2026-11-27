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

local DASH_MOVE = { Name = "DashHit", Percent = Config.Dash.HitPercent, Stun = Config.Dash.HitStun }
local DASH_CLOSE_MOVE = {
	Name = "DashHitClose",
	Percent = Config.Dash.ClosePercent,
	Stun = Config.Dash.HitStun,
	Knockback = Config.Dash.CloseKnockback,
}
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

local function ragdoll(char: Model)
	if StateMachine.Set(char, "Ragdolled", Config.Ragdoll.Duration) then
		Ragdoll.Start(char)
	end
end

StateMachine.OnExit.Ragdolled = function(char, d)
	Ragdoll.Stop(char)
	d.StunImmuneUntil = now() + Config.Ragdoll.ImmunityAfter
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
		if move.IsM1 and t - td.BlockStart <= Config.Block.PerfectWindow then
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

	local damage = move.Damage or move.Percent * hum.MaxHealth
	local kind = move.FXKind or (if wasBlocking then "GuardBreak" else "Hit")
	if move.IsM1 and ad.Buff and t < ad.BuffUntil then
		local blackFlash = ad.Buff == "BlackFlash"
		damage *= if blackFlash then Config.Block.BlackFlashMultiplier else Config.Block.CritMultiplier
		ad.BlackFlashChain = if blackFlash then ad.BlackFlashChain + 1 else 0
		kind = ad.Buff
		ad.Buff = nil
	end
	hum:TakeDamage(damage)

	if td.State ~= "Ragdolled" and t >= td.StunImmuneUntil then
		td.HitCount = if t - td.LastHitTime <= Config.Stun.DecayResetTime then td.HitCount + 1 else 1
		td.LastHitTime = t
		local stun = move.Stun * stunDecay(td.HitCount)
		if wasBlocking then
			stun = math.max(stun, Config.Block.GuardBreakStun)
		end
		-- never shorten a longer stun that is already running
		if not (td.State == "Stunned" and td.Until > t + stun) then
			StateMachine.Set(target, "Stunned", stun)
		end
	end

	local away = (tRoot.Position - aRoot.Position) * Vector3.new(1, 0, 1)
	away = if away.Magnitude > 1e-3 then away.Unit else aRoot.CFrame.LookVector
	if move.WallTrigger and Hitbox.WallBehind(target, away, Config.WallCombo.Distance, { attacker, target }) then
		ad.WallTarget = target
		ad.WallUntil = t + Config.WallCombo.Window
	end
	if move.Knockback or move.Launch then
		push(target, away * (move.Knockback or 0) + Vector3.new(0, move.Launch or 0, 0), Config.Stun.KnockbackTime)
	end
	if move.Ragdoll and hum.Health > 0 then
		ragdoll(target)
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
	task.wait(move.Endlag)
	if StateMachine.Valid(char, token) then
		StateMachine.Set(char, "Idle")
		d.LastSwingEnd = now()
		d.BlockLockUntil = d.LastSwingEnd + Config.M1.BlockLockout
	end
end

local function onM1(char: Model, d)
	local t = now()
	if d.State ~= "Idle" or t < d.M1Ready then
		return
	end
	-- delayed M1s keep the combo as long as the gap stays under ComboResetTime
	if t - d.LastSwingEnd > Config.M1.ComboResetTime then
		d.Combo = 0
	end
	d.Combo = d.Combo % #Config.M1.Hits + 1
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
	if d.State == "Ragdolled" then
		-- ragdoll cancel: side or back only, and only on the ground
		if direction == "Front" or not grounded(char) then
			return
		end
	elseif not (d.State == "Idle" or (wallCombo and d.State == "Attacking")) then
		return -- Stunned covers "no dash during M1 stun"
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
	d[readyKey] = start + (if isSide then Config.Dash.SideCooldown else Config.Dash.ForwardCooldown)
	d.IFrameUntil = start + Config.Dash.IFrames

	-- distance is decided here, never by the client, so a spoofed dash can't travel further
	local kind = if isSide then "Side" else direction
	local distance = Config.Dash[kind .. "Distance"] * Config.TileSize
	if isSide then
		distance *= sideDashScale(hum.Health / hum.MaxHealth)
	end
	local travel = Config.Dash[kind .. "Duration"] - lag
	local orbitTarget = if isSide then nearestEnemy(char, Config.Dash.OrbitRange) else nil
	if Config.Dash.Debug then
		print(string.format("[Dash] %s dir=%s vector=%s distance=%.2f studs travel=%.3fs lag=%.3fs orbit=%s",
			char.Name, direction, tostring(dirVector), distance, travel, lag, if orbitTarget then orbitTarget.Name else "none"))
	end

	local player = Players:GetPlayerFromCharacter(char)
	if player then
		-- the owner simulates its own character, so it applies the velocity; speed, time and target are decided here
		FX:FireClient(player, "DashGo", dirVector, distance / travel, travel, orbitTarget)
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
	while StateMachine.Valid(char, token) and now() < stop do
		if direction == "Front" and now() - start <= Config.Dash.HitWindow then
			for _, target in Hitbox.Query(char, Config.Dash.Hitbox) do
				local tRoot = target:FindFirstChild("HumanoidRootPart")
				if not hitSet[target] and tRoot then
					hitSet[target] = true
					local close = (tRoot.Position - root.Position).Magnitude <= Config.Dash.CloseRange
					ApplyHit(char, target, if close then DASH_CLOSE_MOVE else DASH_MOVE)
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
	if action == "M1" then
		onM1(char, d)
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

local function onPlayer(player: Player)
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
