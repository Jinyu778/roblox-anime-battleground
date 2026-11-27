-- Sends inputs only; plays animations, sounds, flashes and camera effects. The server authorizes everything.
local ContextActionService = game:GetService("ContextActionService")
local UserInputService = game:GetService("UserInputService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Combat = ReplicatedStorage:WaitForChild("Combat")
local Config = require(Combat:WaitForChild("Config"))
local Input = Combat:WaitForChild("Input")
local FX = Combat:WaitForChild("FX")
local player = Players.LocalPlayer
local camera = workspace.CurrentCamera

-- Dash direction -------------------------------------------------------

-- Held keys at the moment Q is pressed -> "Front" | "Back" | "Left" | "Right".
local function resolveDirection(w: boolean, s: boolean, a: boolean, d: boolean): string
	local side = if a and not d then "Left" elseif d and not a then "Right" else nil
	if s and not w then
		return "Back" -- S, S+A, S+D
	elseif w and side then
		return if Config.Dash.DiagonalBehavior == "Side" then side else "Front"
	end
	return side or "Front" -- no key, W, or W+S
end

assert(resolveDirection(false, false, false, false) == "Front", "no key dashes front")
assert(resolveDirection(true, false, false, false) == "Front", "W dashes front")
assert(resolveDirection(false, true, false, false) == "Back", "S dashes back")
assert(resolveDirection(false, false, true, false) == "Left", "A dashes left")
assert(resolveDirection(false, false, false, true) == "Right", "D dashes right")
assert(resolveDirection(false, true, true, false) == "Back", "S+A dashes back")
assert(resolveDirection(true, false, false, true) == (if Config.Dash.DiagonalBehavior == "Side" then "Right" else "Front"), "W+D follows DiagonalBehavior")

-- The facing sent with a dash, as a single yaw angle (the server rebuilds the same CFrame from it).
local function yawOf(look: Vector3): number
	return math.atan2(-look.X, -look.Z)
end

for _, v in { Vector3.new(0, 0, -1), Vector3.new(1, 0, 0), Vector3.new(-0.6, 0, 0.8) } do
	assert(CFrame.fromEulerAnglesYXZ(0, yawOf(v), 0).LookVector:FuzzyEq(v, 1e-4), "yaw must round-trip")
end

-- Code-driven poses (used when an animation id is empty) ------------------

local JOINT_NAMES = {
	RightArm = { "RightShoulder", "Right Shoulder" }, -- R15, R6
	LeftArm = { "LeftShoulder", "Left Shoulder" },
	Torso = { "Waist", "RootJoint" },
}

local jointCache = setmetatable({}, { __mode = "k" }) -- [char] = { [joint] = Motor6D }
local posing = {} -- [char] = { name, start, rise, hold, fall }

local poseRotations = {} -- [poseName] = { [joint] = CFrame in torso space }
for name, pose in Config.Poses do
	poseRotations[name] = {}
	for joint, deg in pose do
		poseRotations[name][joint] = CFrame.fromEulerAnglesYXZ(math.rad(deg[1]), math.rad(deg[2]), math.rad(deg[3]))
	end
end

-- Newer avatars drive limbs with AnimationConstraints instead of Motor6Ds; both expose Transform.
local function isJoint(instance: Instance)
	return instance:IsA("Motor6D") or instance:IsA("AnimationConstraint")
end

-- The joint's frame on its parent part (C0 for a Motor6D, Attachment0 for an AnimationConstraint).
local function jointFrame(joint): CFrame
	if joint:IsA("Motor6D") then
		return joint.C0
	end
	return if joint.Attachment0 then joint.Attachment0.CFrame else CFrame.identity
end

local function joints(char: Model)
	local cached = jointCache[char]
	if cached then
		return cached
	end
	cached = {}
	for _, instance in char:GetDescendants() do
		if isJoint(instance) and instance.Enabled then
			for joint, names in JOINT_NAMES do
				if table.find(names, instance.Name) then
					cached[joint] = instance
				end
			end
		end
	end
	jointCache[char] = cached
	if Config.Client.DebugPoses then
		local found = {}
		for joint, instance in cached do
			table.insert(found, joint .. "=" .. instance.ClassName)
		end
		print("[Pose]", char.Name, if #found > 0 then table.concat(found, " ") else "NO JOINTS FOUND")
	end
	return cached
end

-- Blends the pose over whatever the Animator wrote this frame, so walk/idle still shows underneath.
local function applyPose(char: Model, name: string, weight: number)
	for joint, rotation in poseRotations[name] do
		local motor = joints(char)[joint]
		if motor then
			-- conjugate by the joint frame so the angles mean the same thing on R6 and R15
			local c0 = jointFrame(motor).Rotation
			motor.Transform = motor.Transform:Lerp(c0:Inverse() * rotation * c0, weight)
		end
	end
end

-- rise = blend in, hold = full pose, fall = blend out (seconds). Replaces the character's previous pose.
local function pose(char: Model, name: string, rise: number, hold: number, fall: number)
	if poseRotations[name] then
		posing[char] = { name = name, start = os.clock(), rise = rise, hold = hold, fall = fall }
	end
end

local function poseFor(char: Model, name: string, duration: number)
	local rise, fall = duration * Config.PoseTiming.Rise, duration * Config.PoseTiming.Fall
	pose(char, name, rise, duration - rise - fall, fall)
end

local CANCEL_STATES = { Stunned = true, Ragdolled = true, Dead = true }

-- Stepped runs after the Animator has written its joints, so poses layer on top.
RunService.Stepped:Connect(function()
	local t = os.clock()
	for char, p in posing do
		local state = char:GetAttribute("CombatState")
		local elapsed = t - p.start
		local keepHit = p.name == "HitReaction" and state == "Stunned"
		if not char.Parent or elapsed >= p.rise + p.hold + p.fall or (CANCEL_STATES[state] and not keepHit) then
			posing[char] = nil
		else
			local weight = if elapsed < p.rise
				then 1 - (1 - elapsed / p.rise) ^ 2 -- ease-out: snappy windup
				elseif elapsed < p.rise + p.hold then 1
				else 1 - (elapsed - p.rise - p.hold) / p.fall
			applyPose(char, p.name, weight)
		end
	end
	if Config.Animations.BlockIdle == "" then
		for _, other in Players:GetPlayers() do
			local c = other.Character
			if c and c:GetAttribute("CombatState") == "Blocking" then
				applyPose(c, "BlockIdle", 1)
			end
		end
	end
end)

local function moveByName(name: string)
	local index = tonumber(string.match(name, "^M1_(%d+)$"))
	return if index then Config.M1.Hits[index] else Config.Skills[name]
end

-- Animations -----------------------------------------------------------

local tracks = {} -- [name] = AnimationTrack for the current character
local current: AnimationTrack? = nil -- the playing action animation
local lastPredictedDash = -math.huge

local function loadTracks(char: Model)
	table.clear(tracks)
	current = nil
	local hum = char:WaitForChild("Humanoid")
	local animator = hum:WaitForChild("Animator")
	for name, id in Config.Animations do
		if id ~= "" then
			local animation = Instance.new("Animation")
			animation.AnimationId = id
			local track = animator:LoadAnimation(animation)
			track.Priority = Enum.AnimationPriority.Action
			track.Looped = name == "BlockIdle"
			tracks[name] = track
			if Config.Skills[name] or name:match("^M1_") then
				track:GetMarkerReachedSignal("Hit"):Connect(function()
					Input:FireServer("Marker")
				end)
			end
		end
	end
end

local function stopAction()
	if current then
		current:Stop(Config.Client.AnimFade)
		current = nil
	end
end

-- Plays an action animation stretched to last exactly `duration` seconds.
-- `move` (M1/skill data) times a code-driven pose to Startup/Active/Endlag.
local function playAction(name: string, duration: number, move: any?)
	stopAction()
	local track = tracks[name]
	if not track then
		local char = player.Character
		if char and move then
			pose(char, name, move.Startup, move.Active, move.Endlag)
		elseif char then
			poseFor(char, name, duration)
		end
		return
	end
	track:Play(Config.Client.AnimFade)
	current = track
	if track.Length > 0 then
		track:AdjustSpeed(track.Length / duration)
	else
		-- first play: the asset may still be loading
		track:GetPropertyChangedSignal("Length"):Once(function()
			if track.IsPlaying then
				track:AdjustSpeed(track.Length / duration)
			end
		end)
	end
end

-- Dash effects ---------------------------------------------------------

local LIMBS = { "Left Arm", "Right Arm", "Left Leg", "Right Leg", "LeftHand", "RightHand", "LeftFoot", "RightFoot" }

local function trail(char: Model, duration: number)
	for _, limbName in LIMBS do
		local limb = char:FindFirstChild(limbName)
		if limb then
			local a0 = Instance.new("Attachment")
			a0.Position = Vector3.new(0, 0.4, 0)
			a0.Parent = limb
			local a1 = Instance.new("Attachment")
			a1.Position = Vector3.new(0, -0.4, 0)
			a1.Parent = limb
			local t = Instance.new("Trail")
			t.Attachment0 = a0
			t.Attachment1 = a1
			t.Lifetime = Config.Client.TrailLifetime
			t.Color = ColorSequence.new(Config.Client.TrailColor)
			t.Transparency = NumberSequence.new(0.3, 1)
			t.Parent = limb
			task.delay(duration, function()
				t.Enabled = false
				task.wait(Config.Client.TrailLifetime)
				a0:Destroy()
				a1:Destroy()
				t:Destroy()
			end)
		end
	end
end

local baseFOV = camera.FieldOfView
local fovTween: Tween? = nil

-- Eases out, then drifts back; a new dash takes over from wherever the FOV currently is (no snapping).
local function fovKick()
	if fovTween then
		fovTween:Cancel()
	end
	local kick = TweenService:Create(camera, TweenInfo.new(Config.Client.DashFOVIn, Enum.EasingStyle.Sine, Enum.EasingDirection.Out), {
		FieldOfView = baseFOV + Config.Client.DashFOVBoost,
	})
	fovTween = kick
	kick.Completed:Once(function(state)
		if state ~= Enum.PlaybackState.Completed then
			return
		end
		local back = TweenService:Create(camera, TweenInfo.new(Config.Client.DashFOVOut, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), {
			FieldOfView = baseFOV,
		})
		fovTween = back
		back:Play()
	end)
	kick:Play()
end

local function dashDuration(direction: string)
	local kind = if direction == "Left" or direction == "Right" then "Side" else direction
	return Config.Dash[kind .. "Duration"]
end

-- Shockwave ring, dust puff and rocks left on the floor where a dash starts.
local function dashBurst(char: Model)
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { char }
	local floor = workspace:Raycast(root.Position, Vector3.new(0, -8, 0), params)
	if not floor then
		return -- mid-air: no ground effects
	end
	local ground = floor.Position

	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = Config.Client.RingColor
	ring.Transparency = 0.2
	ring.Size = Vector3.new(0.1, Config.Client.RingStartSize, Config.Client.RingStartSize)
	ring.CFrame = CFrame.new(ground + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent = workspace
	local endSize = Config.Client.RingEndSize
	TweenService:Create(ring, TweenInfo.new(Config.Client.RingTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.1, endSize, endSize),
		Transparency = 1,
	}):Play()
	task.delay(Config.Client.RingTime, function()
		ring:Destroy()
	end)

	local anchor = Instance.new("Attachment")
	anchor.WorldPosition = ground
	anchor.Parent = workspace.Terrain
	local dust = Instance.new("ParticleEmitter")
	dust.Texture = "rbxasset://textures/particles/smoke_main.dds" -- ships with Roblox, no upload needed
	dust.Color = ColorSequence.new(Color3.fromRGB(90, 90, 90))
	dust.Transparency = NumberSequence.new(0.4, 1)
	dust.Size = NumberSequence.new(1.5, 4)
	dust.Lifetime = NumberRange.new(0.5, 0.9)
	dust.Speed = NumberRange.new(4, 8)
	dust.SpreadAngle = Vector2.new(180, 180)
	dust.Enabled = false
	dust.Parent = anchor
	dust:Emit(Config.Client.DustCount)
	task.delay(1, function()
		anchor:Destroy()
	end)

	local rng = Random.new()
	local sizeMin, sizeMax = Config.Client.DebrisSize[1], Config.Client.DebrisSize[2]
	for _ = 1, Config.Client.DebrisCount do
		local angle = rng:NextNumber(0, 2 * math.pi)
		local radius = rng:NextNumber(1, Config.Client.DebrisSpread)
		local origin = ground + Vector3.new(math.cos(angle) * radius, 3, math.sin(angle) * radius)
		local spot = workspace:Raycast(origin, Vector3.new(0, -6, 0), params)
		if spot then
			local size = rng:NextNumber(sizeMin, sizeMax)
			local rock = Instance.new("Part")
			rock.Anchored = true
			rock.CanCollide = false
			rock.CanQuery = false
			rock.CanTouch = false
			rock.Size = Vector3.new(size, size * 0.6, size)
			rock.Color = spot.Instance.Color
			rock.Material = spot.Material
			rock.CFrame = CFrame.new(spot.Position + Vector3.new(0, size * 0.2, 0))
				* CFrame.Angles(rng:NextNumber(-0.5, 0.5), rng:NextNumber(0, 2 * math.pi), rng:NextNumber(-0.5, 0.5))
			rock.Parent = workspace
			task.delay(Config.Client.DebrisLife, function()
				local fade = TweenService:Create(rock, TweenInfo.new(0.4), { Transparency = 1 })
				fade.Completed:Once(function()
					rock:Destroy()
				end)
				fade:Play()
			end)
		end
	end
end

-- Dash movement: the owning client simulates its character, so it applies what the server authorized.
local lastDashLook = Vector3.new(0, 0, -1) -- flat camera look when Q was pressed
local dashMover = nil -- { attachment, autoRotate } while a dash is running

local function stopDash()
	local mover = dashMover
	if not mover then
		return
	end
	dashMover = nil
	RunService:UnbindFromRenderStep("CombatDash")
	mover.attachment:Destroy()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if hum then
		hum.AutoRotate = mover.autoRotate
	end
	if root then
		-- kill leftover momentum so nothing carries into walking or the next dash
		root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
	end
end

local function runDash(direction: Vector3, speed: number, duration: number, target: Model?)
	stopDash()
	local char = player.Character
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local root = char and char:FindFirstChild("HumanoidRootPart")
	if not hum or not root then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Parent = root
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = attachment
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.MaxForce = math.huge
	lv.VectorVelocity = direction * speed
	lv.Parent = attachment
	dashMover = { attachment = attachment, autoRotate = hum.AutoRotate }
	hum.AutoRotate = false

	-- side dash with a target: travel along the circle around it, facing it, at the starting radius
	local flat = Vector3.new(1, 0, 1)
	local targetRoot = target and target:FindFirstChild("HumanoidRootPart")
	local radius = if targetRoot then ((targetRoot.Position - root.Position) * flat).Magnitude else 0
	if radius < 1e-3 then
		targetRoot = nil
	end
	local spin = 1
	if targetRoot then
		local toTarget = ((targetRoot.Position - root.Position) * flat).Unit
		spin = if direction:Dot(toTarget:Cross(Vector3.yAxis)) >= 0 then 1 else -1
	end

	local stopAt = os.clock() + duration
	-- after the camera so shift lock's own rotation doesn't overwrite the dash facing
	RunService:BindToRenderStep("CombatDash", Enum.RenderPriority.Camera.Value + 1, function(dt)
		if os.clock() >= stopAt or not root.Parent then
			stopDash()
			return
		end
		local face = lastDashLook
		if targetRoot and targetRoot.Parent then
			local offset = (targetRoot.Position - root.Position) * flat
			if offset.Magnitude > 1e-3 then
				local toTarget = offset.Unit
				lv.VectorVelocity = toTarget:Cross(Vector3.yAxis) * spin * speed
					+ toTarget * (offset.Magnitude - radius) * Config.Dash.OrbitPull
				face = toTarget
			end
		end
		-- turn toward the dash facing smoothly instead of snapping (frame-rate independent)
		local alpha = 1 - math.exp(-Config.Client.DashTurnSpeed * dt)
		root.CFrame = root.CFrame:Lerp(CFrame.lookAt(root.Position, root.Position + face), alpha)
	end)
end

local function playDash(char: Model, direction: string)
	local duration = dashDuration(direction)
	dashBurst(char)
	if char == player.Character then
		playAction("Dash" .. direction, duration)
		fovKick()
	elseif Config.Animations["Dash" .. direction] == "" then
		poseFor(char, "Dash" .. direction, duration) -- uploaded dash animations replicate on their own
	end
	trail(char, duration)
end

-- Input ----------------------------------------------------------------

local readyAt = { DashReady = 0, SideDashReady = 0 }

local function bind(name: string, onState: (Enum.UserInputState) -> (), ...)
	ContextActionService:BindAction(name, function(_, state)
		onState(state)
		return Enum.ContextActionResult.Pass
	end, false, ...)
end

bind("CombatM1", function(state)
	if state == Enum.UserInputState.Begin then
		Input:FireServer("M1")
	end
end, Enum.UserInputType.MouseButton1)

bind("CombatBlock", function(state)
	if state == Enum.UserInputState.Begin then
		Input:FireServer("Block", true)
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		Input:FireServer("Block", false)
	end
end, Enum.KeyCode.F)

bind("CombatDash", function(state)
	if state ~= Enum.UserInputState.Begin then
		return
	end
	local direction = resolveDirection(
		UserInputService:IsKeyDown(Enum.KeyCode.W),
		UserInputService:IsKeyDown(Enum.KeyCode.S),
		UserInputService:IsKeyDown(Enum.KeyCode.A),
		UserInputService:IsKeyDown(Enum.KeyCode.D)
	)
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	-- the camera is the facing source in every mode (shift lock on or off)
	local look = camera.CFrame.LookVector * Vector3.new(1, 0, 1)
	if look.Magnitude > 1e-3 then
		lastDashLook = look.Unit
	end
	Input:FireServer("Dash", direction, workspace:GetServerTimeNow(), yawOf(lastDashLook))

	-- client prediction: only when the server will very likely accept it
	local state = char and char:GetAttribute("CombatState")
	local key = if direction == "Left" or direction == "Right" then "SideDashReady" else "DashReady"
	local stateOk = state == "Idle" or (state == "Ragdolled" and direction ~= "Front")
	if char and stateOk and workspace:GetServerTimeNow() >= readyAt[key] then
		lastPredictedDash = os.clock()
		playDash(char, direction)
	end
end, Enum.KeyCode.Q)

for name, skill in Config.Skills do
	bind("CombatSkill" .. name, function(state)
		if state == Enum.UserInputState.Begin then
			Input:FireServer("Skill", name)
		end
	end, skill.Key)
end

-- Character: facing, state reactions, respawn --------------------------

local function onCharacter(char: Model)
	loadTracks(char)
	local hum = char:WaitForChild("Humanoid")
	stopDash() -- a dash from the previous life must not touch this one
	if Config.Dash.FaceCamera then
		hum.AutoRotate = false -- otherwise leave it to Roblox so shift lock on/off works normally
	end

	char:GetAttributeChangedSignal("CombatState"):Connect(function()
		local state = char:GetAttribute("CombatState")
		if CANCEL_STATES[state] then
			stopAction()
			stopDash()
		end
		if tracks.BlockIdle then
			if state == "Blocking" then
				tracks.BlockIdle:Play(Config.Client.AnimFade)
			else
				tracks.BlockIdle:Stop(Config.Client.AnimFade)
			end
		end
	end)
end

if player.Character then
	task.spawn(onCharacter, player.Character)
end
player.CharacterAdded:Connect(onCharacter)

-- Keep the root on the camera yaw so the server's LookVector matches what the player sees.
RunService.RenderStepped:Connect(function()
	local char = player.Character
	local root = char and char:FindFirstChild("HumanoidRootPart")
	local state = char and char:GetAttribute("CombatState")
	if not Config.Dash.FaceCamera or not root or state == "Ragdolled" or state == "Dead" then
		return
	end
	local look = camera.CFrame.LookVector * Vector3.new(1, 0, 1)
	if look.Magnitude > 1e-3 then
		root.CFrame = CFrame.lookAt(root.Position, root.Position + look)
	end
end)

-- Hit effects ----------------------------------------------------------

local function sound(part: BasePart, kind: string)
	local id = Config.Sounds[kind]
	if not id or id == "" then
		return
	end
	local s = Instance.new("Sound")
	s.SoundId = id
	s.Parent = part
	s.Ended:Once(function()
		s:Destroy()
	end)
	s:Play()
end

local function flash(char: Model, kind: string)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = Config.FlashColors[kind] or Config.FlashColors.Hit
	highlight.OutlineTransparency = 1
	highlight.Parent = char
	task.delay(Config.Client.FlashTime, function()
		highlight:Destroy()
	end)
end

local function shake()
	local hum = player.Character and player.Character:FindFirstChildOfClass("Humanoid")
	if not hum then
		return
	end
	local stop = os.clock() + Config.Client.ShakeTime
	local connection
	connection = RunService.RenderStepped:Connect(function()
		if os.clock() >= stop then
			hum.CameraOffset = Vector3.zero
			connection:Disconnect()
			return
		end
		local i = Config.Client.ShakeIntensity
		hum.CameraOffset = Vector3.new((math.random() - 0.5) * 2 * i, (math.random() - 0.5) * 2 * i, 0)
	end)
end

-- Dash cooldown UI -----------------------------------------------------

local gui = Instance.new("ScreenGui")
gui.Name = "DashCooldowns"
gui.ResetOnSpawn = false
gui.Parent = player:WaitForChild("PlayerGui")

local label = Instance.new("TextLabel")
label.Size = UDim2.fromOffset(260, 40)
label.Position = UDim2.new(0.5, -130, 1, -110)
label.BackgroundColor3 = Color3.new(0, 0, 0)
label.BackgroundTransparency = 0.4
label.TextColor3 = Color3.new(1, 1, 1)
label.TextScaled = true
label.Font = Enum.Font.GothamBold
label.Parent = gui

local function remaining(key: string, t: number)
	local left = readyAt[key] - t
	return if left > 0 then string.format("%.1fs", left) else "Ready"
end

RunService.RenderStepped:Connect(function()
	local t = workspace:GetServerTimeNow()
	label.Text = "Dash " .. remaining("DashReady", t) .. "  |  Side " .. remaining("SideDashReady", t)
end)

-- Server events --------------------------------------------------------

FX.OnClientEvent:Connect(function(event, a, b, c, d)
	local me = player.Character
	if event == "DashGo" and typeof(a) == "Vector3" then
		runDash(a, b, c, d) -- direction, speed, duration, orbit target (or nil)
	elseif event == "Swing" and a then
		local move = moveByName(b)
		if not move then
			return
		end
		if a == me then
			playAction(b, move.Startup + move.Active + move.Endlag, move)
		elseif Config.Animations[b] == "" then
			pose(a, b, move.Startup, move.Active, move.Endlag) -- uploaded animations replicate from the owner instead
		end
	elseif event == "Dash" and a then
		-- the owner already predicted it; play only if it didn't (e.g. a wall-combo dash out of endlag)
		if a ~= me or os.clock() - lastPredictedDash > Config.Client.PredictionWindow then
			playDash(a, b)
		end
	elseif event == "Hit" and b then
		local attacker, target, kind = a, b, c
		if kind ~= "Blocked" and kind ~= "PerfectBlock" then
			if target == me and tracks.HitReaction then
				tracks.HitReaction:Play(Config.Client.AnimFade)
			elseif Config.Animations.HitReaction == "" then
				poseFor(target, "HitReaction", Config.PoseTiming.HitReactionTime)
			end
		end
		local root = target:FindFirstChild("HumanoidRootPart")
		if root then
			sound(root, kind)
		end
		flash(target, kind)
		if me and (attacker == me or target == me) then
			shake()
		end
	elseif event == "Cooldown" and readyAt[a] then
		readyAt[a] = b
	end
end)
