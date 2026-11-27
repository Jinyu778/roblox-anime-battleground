--!strict
-- Per-character client: reads input, predicts your own swings (animation, micro-dash, hitbox) and claims hits.
-- The server decides what actually lands. Lives in StarterCharacterScripts, so every respawn starts fresh.
local ContextActionService = game:GetService("ContextActionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Config = require(Modules:WaitForChild("Config"))
local StateHandler = require(Modules:WaitForChild("StateHandler"))
local HitboxService = require(Modules:WaitForChild("HitboxService"))
local AnimationController = require(Modules:WaitForChild("AnimationController"))
local Moves = require(Modules:WaitForChild("Moves"))

local remotes = ReplicatedStorage:WaitForChild("CombatRemotes")
local Input = remotes:WaitForChild("Input") :: RemoteEvent
local Effects = remotes:WaitForChild("Effects") :: RemoteEvent

local char = script.Parent :: Model
local hum = char:WaitForChild("Humanoid") :: Humanoid
local root = char:WaitForChild("HumanoidRootPart") :: BasePart

local COMBO_LENGTH = #Config.M1.Damage
local currentDashDirection: string? = nil -- set while this client is running a dash (an M1 may come out of a side dash)

AnimationController.Load(char)

-- Removes velocities this client put on its own character (the server can't see them).
local function destroyOwnMovers()
	for _, child in root:GetChildren() do
		if child.Name == Config.Dash.MoverName then
			child:Destroy()
		end
	end
end

StateHandler.BindInterrupts(char, destroyOwnMovers)

local function mover(velocity: Vector3, duration: number)
	local attachment = Instance.new("Attachment")
	attachment.Name = Config.Dash.MoverName
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = attachment
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	lv.MaxAxesForce = Vector3.new(Config.Dash.HorizontalForce, 0, Config.Dash.HorizontalForce)
	lv.VectorVelocity = velocity
	lv.Parent = attachment
	attachment.Parent = root
	task.delay(duration, function()
		attachment:Destroy()
	end)
end

-- Sounds --------------------------------------------------------------------

local soundIds = Config.Sounds :: { [string]: string }

-- 3D sound on a part with a slightly random pitch, so repeats don't sound robotic. Empty ids stay silent.
local function play3D(name: string, part: Instance?, volume: number?)
	local id = soundIds[name]
	if not id or id == "" or not part or not part:IsA("BasePart") then
		return
	end
	local settings = Config.SoundSettings
	local sound = Instance.new("Sound")
	sound.SoundId = id
	sound.Volume = volume or 0.5
	sound.PlaybackSpeed = settings.PitchMin + math.random() * (settings.PitchMax - settings.PitchMin)
	sound.RollOffMinDistance = settings.RollOffMin
	sound.RollOffMaxDistance = settings.RollOffMax
	sound.Parent = part
	sound.Ended:Once(function()
		sound:Destroy()
	end)
	sound:Play()
end

-- Air whoosh on every dash, plus a ground skid when the dasher is standing on something.
local function dashSounds(dasher: Model)
	local dasherRoot = HitboxService.RootOf(dasher)
	play3D("DashWhoosh", dasherRoot, 0.8)
	local dasherHum = dasher:FindFirstChildOfClass("Humanoid")
	if dasherHum and dasherHum.FloorMaterial ~= Enum.Material.Air then
		play3D("DashSlide", dasherRoot, 0.5)
	end
end

-- M1 ------------------------------------------------------------------------

local AIR_STATES: { [Enum.HumanoidStateType]: boolean } = {
	[Enum.HumanoidStateType.Jumping] = true,
	[Enum.HumanoidStateType.Freefall] = true,
}

local jumpTime = -math.huge -- when this character last jumped (server clock), for the uppercut window
hum.StateChanged:Connect(function(_, new)
	if new == Enum.HumanoidStateType.Jumping then
		jumpTime = StateHandler.Now()
	end
end)

local function jumpHeld(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.Space)
		or UserInputService:IsGamepadButtonDown(Enum.UserInputType.Gamepad1, Enum.KeyCode.ButtonA)
end

-- Jump lock: while comboing, holding jump doesn't jump (it only marks the 4th hit as an uppercut).
-- A fresh press between swings still jumps, which is the downslam input.
local JUMP_KEYS: { [Enum.KeyCode]: boolean } = { [Enum.KeyCode.Space] = true, [Enum.KeyCode.ButtonA] = true }
local jumpLockUntil = 0
local jumpAllowUntil = 0

UserInputService.InputBegan:Connect(function(input, gameProcessed)
	if gameProcessed or not JUMP_KEYS[input.KeyCode] or os.clock() >= jumpLockUntil then
		return
	end
	if not StateHandler.Is(char, "Attacking") and not StateHandler.IsLocked(char) then
		jumpAllowUntil = os.clock() + Config.M1.FreshJumpWindow
		hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, true)
		hum:ChangeState(Enum.HumanoidStateType.Jumping)
	end
end)

RunService.RenderStepped:Connect(function()
	local t = os.clock()
	local allow = not Config.M1.JumpLock or t >= jumpLockUntil or t < jumpAllowUntil
	if hum:GetStateEnabled(Enum.HumanoidStateType.Jumping) ~= allow then
		hum:SetStateEnabled(Enum.HumanoidStateType.Jumping, allow)
	end
end)

-- The move this click becomes, by the same rule the server uses (Moves.Choose) and the attributes it wrote.
local function predictMove(held: boolean): Moves.Move
	local t = StateHandler.Now()
	local count = StateHandler.Number(char, "ComboCount")
	local stale = t - StateHandler.Number(char, "LastM1Time") > Config.M1.ComboResetTime
	return Moves.Choose({
		index = if stale or count >= COMBO_LENGTH then 1 else count + 1,
		airborne = AIR_STATES[hum:GetState()] == true
			or hum.FloorMaterial == Enum.Material.Air
			or math.abs(root.AssemblyLinearVelocity.Y) > Config.Server.AirSpeed,
		jumpHeld = held,
		sinceJump = t - jumpTime,
		comboActive = not stale and count > 0 and count < COMBO_LENGTH,
		recentJab = t - StateHandler.Number(char, "LastJabTime") <= Config.Jab.Stun,
		uppercutReady = t >= StateHandler.Number(char, "UppercutReadyTime"),
		downslamReady = t >= StateHandler.Number(char, "DownslamReadyTime"),
	})
end

local swingUntil = 0 -- local debounce, so spam can't start several predicted swings before the server answers

local function onM1()
	local outOfSideDash = currentDashDirection ~= nil
		and currentDashDirection ~= "Front"
		and not StateHandler.Is(char, "Attacking")
		and not StateHandler.IsLocked(char)
	if not (StateHandler.CanAct(char) or outOfSideDash) or StateHandler.Is(char, "Blocking") then
		return
	end
	if StateHandler.Now() < StateHandler.Number(char, "M1ReadyTime") or os.clock() < swingUntil then
		return
	end
	local held = jumpHeld()
	local move = predictMove(held)
	local total = Moves.Total(move)
	swingUntil = os.clock() + total
	Input:FireServer("M1", { jumpHeld = held, sinceJump = StateHandler.Now() - jumpTime })
	-- lock jumping for the rest of the string; a finisher or heavy move frees it once the swing ends
	local stringOver = move.Index == nil or move.Index == COMBO_LENGTH
	jumpLockUntil = os.clock() + (if stringOver then total else Config.M1.ComboResetTime)

	if move.Index and move.Index < COMBO_LENGTH then
		local forward = root.CFrame.LookVector * Vector3.new(1, 0, 1)
		mover(forward.Unit * Config.M1.MicroDashSpeed, Config.M1.MicroDashTime)
	end

	local hits: HitboxService.HitTable = {}
	play3D("Swing1", root)
	AnimationController.Play(char, move.Name, total, move.Startup, function()
		-- active window: query every frame and claim each new target once
		local stop = os.clock() + move.Active
		while os.clock() < stop and not StateHandler.IsLocked(char) do
			for _, target in HitboxService.Query(char, move.Hitbox, hits) do
				Input:FireServer("M1Hit", target)
			end
			RunService.Heartbeat:Wait()
		end
	end)
end

ContextActionService:BindAction("CombatM1", function(_, state)
	if state == Enum.UserInputState.Begin then
		onM1()
	end
	return Enum.ContextActionResult.Pass
end, false, Enum.UserInputType.MouseButton1)

-- Block ---------------------------------------------------------------------

ContextActionService:BindAction("CombatBlock", function(_, state)
	if state == Enum.UserInputState.Begin then
		Input:FireServer("Block", true)
	elseif state == Enum.UserInputState.End or state == Enum.UserInputState.Cancel then
		Input:FireServer("Block", false)
	end
	return Enum.ContextActionResult.Pass
end, false, Enum.KeyCode.F)

-- Dashes --------------------------------------------------------------------

-- Keys held at the moment Q is pressed -> "Front" | "Back" | "Left" | "Right".
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
assert(resolveDirection(false, true, false, false) == "Back", "S dashes back")
assert(resolveDirection(false, false, true, false) == "Left", "A dashes left")
assert(resolveDirection(false, false, false, true) == "Right", "D dashes right")
assert(resolveDirection(false, true, false, true) == "Back", "S+D dashes back")
assert(resolveDirection(true, true, false, false) == "Front", "W+S dashes front")

local function flat(v: Vector3): Vector3
	local f = v * Vector3.new(1, 0, 1)
	return if f.Magnitude > 1e-3 then f.Unit else Vector3.new(0, 0, -1)
end

-- Quad Out ease from start to end speed: a burst that settles instead of a flat slide.
local function dashSpeed(startSpeed: number, endSpeed: number, u: number): number
	local k = 1 - (1 - math.clamp(u, 0, 1)) ^ 2
	return startSpeed + (endSpeed - startSpeed) * k
end

assert(dashSpeed(88, 16, 0) == 88 and dashSpeed(88, 16, 1) == 16, "dash speed starts high and ends low")
assert(dashSpeed(88, 16, 0.5) == 34, "Quad Out: three quarters of the drop happens in the first half")

local function directionVector(direction: string): Vector3
	local cf = root.CFrame
	local look, right = flat(cf.LookVector), flat(cf.RightVector)
	return if direction == "Front" then look elseif direction == "Back" then -look elseif direction == "Left" then -right else right
end

local function onDash()
	local direction = resolveDirection(
		UserInputService:IsKeyDown(Enum.KeyCode.W),
		UserInputService:IsKeyDown(Enum.KeyCode.S),
		UserInputService:IsKeyDown(Enum.KeyCode.A),
		UserInputService:IsKeyDown(Enum.KeyCode.D)
	)
	local isSide = direction ~= "Front" -- left, right and back share a cooldown
	-- evasive: dashing out of a ragdoll, on its own cooldown (the server re-checks grounded and no-cancel)
	local evasive = StateHandler.Is(char, "Ragdolled")
	-- any dash may cut a swing's endlag short; a front dash also cashes in a wall combo or the mini uppercut tech
	local t = StateHandler.Now()
	local endlagCancel = StateHandler.Is(char, "Attacking")
		and not StateHandler.IsLocked(char)
		and (
			t >= StateHandler.Number(char, "EndlagFrom")
			or direction == "Front" and (t <= StateHandler.Number(char, "WallComboUntil") or t <= StateHandler.Number(char, "DashCancelUntil"))
		)
	if evasive then
		local evasiveDown = t < StateHandler.Number(char, "EvasiveReadyTime")
		if evasiveDown or StateHandler.Is(char, "Launched") or char:GetAttribute("RagdollNoCancel") == true then
			return
		end
	elseif not (StateHandler.CanAct(char) or endlagCancel) or StateHandler.Is(char, "Blocking") then
		return
	elseif t < StateHandler.Number(char, if isSide then "SideDashReadyTime" else "DashReadyTime") then
		return
	end
	Input:FireServer("Dash", direction)

	if Config.Dash.FaceCameraOnDash then
		local look = flat(workspace.CurrentCamera.CFrame.LookVector)
		root.CFrame = CFrame.lookAt(root.Position, root.Position + look)
	end
	local startSpeed, endSpeed, duration
	if direction == "Front" then
		startSpeed, endSpeed, duration = Config.Dash.FrontStartSpeed, Config.Dash.FrontEndSpeed, Config.Dash.FrontDuration
	else
		startSpeed, endSpeed, duration = Config.Dash.SideStartSpeed, Config.Dash.SideEndSpeed, Config.Dash.SideDuration
		local min = Config.Dash.SideMinScale
		local scale = min + (1 - min) * math.clamp(hum.Health / hum.MaxHealth, 0, 1)
		startSpeed *= scale
		endSpeed *= scale
	end
	local fixed = directionVector(direction)
	destroyOwnMovers()

	local attachment = Instance.new("Attachment")
	attachment.Name = Config.Dash.MoverName
	local lv = Instance.new("LinearVelocity")
	lv.Attachment0 = attachment
	lv.RelativeTo = Enum.ActuatorRelativeTo.World
	-- horizontal only: gravity still pulls, so a dash off a ledge falls naturally
	lv.ForceLimitMode = Enum.ForceLimitMode.PerAxis
	lv.MaxAxesForce = Vector3.new(Config.Dash.HorizontalForce, 0, Config.Dash.HorizontalForce)
	lv.VectorVelocity = fixed * startSpeed
	lv.Parent = attachment
	attachment.Parent = root
	AnimationController.Play(char, "Dash" .. direction, duration)
	dashSounds(char)
	currentDashDirection = direction

	local hits: HitboxService.HitTable = {}
	local startClock = os.clock()
	local stop = startClock + duration
	-- out of a ragdoll, the Ragdolled flag stays on until the server's recovery reaches us; don't self-cancel
	local lockGraceUntil = if evasive then os.clock() + Config.Ragdoll.EvasiveIFrames else 0
	local cameraSteer = Config.Dash.CameraSteering and (direction == "Front" or Config.Dash.SideBackSteering)
	-- AutoRotate would turn the body toward held keys and fight the camera steering
	local autoRotate = hum.AutoRotate
	if cameraSteer then
		hum.AutoRotate = false
	end
	local connection: RBXScriptConnection
	local function finish()
		connection:Disconnect()
		attachment:Destroy()
		currentDashDirection = nil
		if cameraSteer and not StateHandler.IsLocked(char) then
			hum.AutoRotate = autoRotate -- a stun keeps it off; the server restores it when the stun ends
		end
		-- drop the dash momentum so nothing carries into walking or the next dash
		root.AssemblyLinearVelocity = Vector3.new(0, root.AssemblyLinearVelocity.Y, 0)
	end
	connection = RunService.Heartbeat:Connect(function(dt: number)
		local locked = StateHandler.IsLocked(char) and os.clock() >= lockGraceUntil
		if os.clock() >= stop or not attachment.Parent or locked then
			finish()
			return
		end
		local speed = dashSpeed(startSpeed, endSpeed, (os.clock() - startClock) / duration)
		if cameraSteer then
			-- re-aim from the camera every frame, and turn the body toward it smoothly
			local look = flat(workspace.CurrentCamera.CFrame.LookVector)
			local right = look:Cross(Vector3.yAxis)
			local steer = if direction == "Front"
				then look
				elseif direction == "Back" then -look
				elseif direction == "Left" then -right
				else right
			lv.VectorVelocity = steer * speed
			local alpha = 1 - math.exp(-Config.Dash.TurnSpeed * dt)
			root.CFrame = root.CFrame:Lerp(CFrame.lookAt(root.Position, root.Position + look), alpha)
		elseif direction == "Front" and Config.Dash.FrontSteering then
			lv.VectorVelocity = flat(root.CFrame.LookVector) * speed -- curve with the character's facing
		else
			lv.VectorVelocity = fixed * speed
		end
		if direction ~= "Front" then
			return
		end
		local target = HitboxService.Query(char, Config.Jab.Hitbox, hits)[1]
		if target then
			-- stop right in front of them, jab, and let the server judge it
			finish()
			Input:FireServer("JabHit", target)
			AnimationController.Play(char, "DashJab", Config.Jab.Startup + Config.Jab.Active + Config.Jab.Endlag)
		end
	end)
end

-- Malevolent Shrine: the server validates state and cooldown; this only skips a press that can't work.
local shrine = Config.MalevolentShrine
ContextActionService:BindAction("CombatShrine", function(_, state)
	if state ~= Enum.UserInputState.Begin then
		return Enum.ContextActionResult.Pass
	end
	local wait = StateHandler.Number(char, "ShrineReadyTime") - StateHandler.Now()
	local blocked = if wait > 0
		then string.format("on cooldown for %.0f more seconds", wait)
		elseif StateHandler.Is(char, "Blocking") then "blocking"
		elseif not StateHandler.CanAct(char) then "can't act right now"
		else nil
	if Config.Server.DebugMoves then
		print("[Shrine] key pressed: " .. (blocked or "sending to the server"))
	end
	if not blocked then
		Input:FireServer("Skill", "MalevolentShrine")
		AnimationController.Play(char, "MalevolentShrine", shrine.CastTime)
	end
	return Enum.ContextActionResult.Pass
end, false, shrine.Key)

ContextActionService:BindAction("CombatDash", function(_, state)
	if state == Enum.UserInputState.Begin then
		onDash()
	end
	return Enum.ContextActionResult.Pass
end, false, Enum.KeyCode.Q)

-- Dash cooldown readout, from the attributes the server writes.
local gui = Instance.new("ScreenGui")
gui.Name = "DashCooldowns"
gui.Parent = (Players.LocalPlayer :: Player):WaitForChild("PlayerGui")
local label = Instance.new("TextLabel")
label.Size = UDim2.fromOffset(420, 36)
label.Position = UDim2.new(0.5, -210, 1, -100)
label.BackgroundColor3 = Color3.new(0, 0, 0)
label.BackgroundTransparency = 0.4
label.TextColor3 = Color3.new(1, 1, 1)
label.TextScaled = true
label.Font = Enum.Font.GothamBold
label.Parent = gui
char.Destroying:Connect(function()
	gui:Destroy()
end)

local function remaining(name: string): string
	local left = StateHandler.Number(char, name) - StateHandler.Now()
	return if left > 0 then string.format("%.1fs", left) else "Ready"
end
RunService.RenderStepped:Connect(function()
	label.Text = "Front " .. remaining("DashReadyTime")
		.. "  |  Side/Back " .. remaining("SideDashReadyTime")
		.. "  |  Evasive " .. remaining("EvasiveReadyTime")
end)

-- Effects -------------------------------------------------------------------

local function flash(target: Model, kind: string)
	local colors = Config.Effects.Colors :: { [string]: Color3 }
	local highlight = Instance.new("Highlight")
	highlight.FillColor = colors[kind] or colors.Hit
	highlight.OutlineTransparency = 1
	highlight.Parent = target
	task.delay(Config.Effects.FlashTime, function()
		highlight:Destroy()
	end)
end

local function shatter(target: Model)
	local targetRoot = HitboxService.RootOf(target)
	if not targetRoot then
		return
	end
	local burst = Instance.new("Part")
	burst.Shape = Enum.PartType.Ball
	burst.Anchored = true
	burst.CanCollide = false
	burst.CanQuery = false
	burst.CanTouch = false
	burst.CastShadow = false
	burst.Material = Enum.Material.Neon
	burst.Color = Config.Effects.Colors.GuardBreak
	burst.Transparency = 0.3
	burst.Size = Vector3.one * 2
	burst.CFrame = targetRoot.CFrame
	burst.Parent = HitboxService.VFXFolder()
	TweenService:Create(burst, TweenInfo.new(Config.Effects.ShatterTime), {
		Size = Vector3.one * Config.Effects.ShatterSize,
		Transparency = 1,
	}):Play()
	task.delay(Config.Effects.ShatterTime, function()
		burst:Destroy()
	end)
end

-- Flat neon ring that spreads over the ground under a slammed target.
local function shockwave(target: Model)
	local targetRoot = HitboxService.RootOf(target)
	if not targetRoot then
		return
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { target, HitboxService.VFXFolder() }
	local floor = workspace:Raycast(targetRoot.Position, Vector3.new(0, -10, 0), params)
	local ground = if floor then floor.Position else targetRoot.Position
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.new(1, 1, 1)
	ring.Transparency = 0.2
	ring.Size = Vector3.new(0.2, 2, 2)
	ring.CFrame = CFrame.new(ground + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent = HitboxService.VFXFolder()
	local size = Config.Effects.ShockwaveSize
	TweenService:Create(ring, TweenInfo.new(Config.Effects.ShockwaveTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.2, size, size),
		Transparency = 1,
	}):Play()
	task.delay(Config.Effects.ShockwaveTime, function()
		ring:Destroy()
	end)
end

local function shake(intensity: number?, duration: number?)
	local stop = os.clock() + (duration or Config.Effects.ShakeTime)
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		if os.clock() >= stop or not hum.Parent then
			hum.CameraOffset = Vector3.zero
			connection:Disconnect()
			return
		end
		local i = intensity or Config.Effects.ShakeIntensity
		hum.CameraOffset = Vector3.new((math.random() - 0.5) * 2 * i, (math.random() - 0.5) * 2 * i, 0)
	end)
end

-- Shrine visuals ------------------------------------------------------------
-- The server parents the shrine and slash effect into the VFX folder with attributes; every client animates them.

local function riseShrine(model: Model)
	local final = model:GetAttribute("RiseTo") :: CFrame
	local riseTime = model:GetAttribute("RiseTime") :: number
	local startedAt = model:GetAttribute("RiseStart") :: number
	local from = model:GetPivot() -- buried
	play3D("ShrineRise", model:FindFirstChildWhichIsA("BasePart", true), 1)
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		if not model.Parent then
			connection:Disconnect()
			return
		end
		local alpha = math.clamp((StateHandler.Now() - startedAt) / riseTime, 0, 1)
		model:PivotTo(from:Lerp(final, 1 - (1 - alpha) ^ 2)) -- ease out
		if alpha >= 1 then
			connection:Disconnect()
			if (root.Position - final.Position).Magnitude <= shrine.ShakeRange then
				shake(shrine.ShakeIntensity, shrine.ShakeTime)
			end
		end
	end)
end

local function sinkShrine(model: Model)
	local fade = model:GetAttribute("FadeTime") :: number
	local depth = model:GetAttribute("Depth") :: number
	local from = model:GetPivot()
	local startClock = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		if not model.Parent then
			connection:Disconnect()
			return
		end
		local alpha = math.clamp((os.clock() - startClock) / fade, 0, 1)
		model:PivotTo(from - Vector3.new(0, depth * alpha, 0))
		if alpha >= 1 then
			connection:Disconnect()
		end
	end)
end

-- Burst-style emitters (Rate 0) don't fire on their own, and Emit isn't replicated, so each client bursts them.
local function emitSlashes(model: Model)
	play3D("ShrineSlash", model:FindFirstChildWhichIsA("BasePart", true), 1)
	task.spawn(function()
		while model.Parent do
			local interval = model:GetAttribute("SlashEmitInterval")
			if type(interval) ~= "number" then
				break -- the server cleared it: the attack is over
			end
			local count = model:GetAttribute("SlashEmitCount") :: number
			for _, d in model:GetDescendants() do
				if d:IsA("ParticleEmitter") and d.Rate == 0 then
					local own = d:GetAttribute("EmitCount")
					d:Emit(if type(own) == "number" then own else count)
				end
			end
			task.wait(interval)
		end
	end)
end

local function onVFXChild(child: Instance)
	if not child:IsA("Model") then
		return
	end
	if child:GetAttribute("RiseTo") ~= nil then
		riseShrine(child)
		child:GetAttributeChangedSignal("SinkAt"):Connect(function()
			sinkShrine(child)
		end)
	end
	if child:GetAttribute("SlashEmitInterval") ~= nil then
		emitSlashes(child)
	else
		-- a domain that rises first switches its slashes on afterwards
		local connection: RBXScriptConnection
		connection = child:GetAttributeChangedSignal("SlashEmitInterval"):Connect(function()
			if child:GetAttribute("SlashEmitInterval") ~= nil then
				connection:Disconnect()
				emitSlashes(child)
			end
		end)
	end
end

local vfxFolder = HitboxService.VFXFolder()
vfxFolder.ChildAdded:Connect(onVFXChild)
for _, child in vfxFolder:GetChildren() do
	task.spawn(onVFXChild, child)
end

-- Heavy hits get the deep impact sound.
local HEAVY_MOVES: { [string]: boolean } = { M1_4 = true, Uppercut = true, MiniUppercut = true, Downslam = true, WallCombo = true }

Effects.OnClientEvent:Connect(function(event: string, a: any, b: any, c: any, d: any)
	if event == "Swing" or event == "Dash" then
		-- your own swings and dashes are already predicted; others' show their real animation or the fallback
		if typeof(a) == "Instance" and a ~= char then
			local other = a :: Model
			AnimationController.Play(other, if event == "Dash" then "Dash" .. b else b, c)
			if event == "Dash" then
				dashSounds(other)
			else
				play3D("Swing1", HitboxService.RootOf(other))
			end
		end
	elseif event == "ShrineTick" then
		local victim = a :: Model?
		if victim and victim.Parent then
			flash(victim, "Shrine") -- a small flash per damage tick, no shake or hit reaction
		end
	elseif event == "Evasive" then
		-- white flash and chime so everyone sees the evasive is spent
		local evader = a :: Model?
		if not evader or not evader.Parent then
			return
		end
		play3D("EvasiveSound", HitboxService.RootOf(evader), 1)
		local highlight = Instance.new("Highlight")
		highlight.FillColor = Color3.new(1, 1, 1)
		highlight.FillTransparency = 0.2
		highlight.OutlineTransparency = 0
		highlight.Parent = evader
		local fadeTime = Config.SoundSettings.EvasiveFlashTime
		TweenService:Create(highlight, TweenInfo.new(fadeTime), { FillTransparency = 1, OutlineTransparency = 1 }):Play()
		task.delay(fadeTime, function()
			highlight:Destroy()
		end)
	elseif event == "Shockwave" then
		local target = a :: Model?
		if not target or not target.Parent then
			return
		end
		shockwave(target)
		if HitboxService.Distance(char, target) <= Config.Effects.ShockwaveShakeRange then
			shake(Config.Downslam.ShakeIntensity, Config.Downslam.ShakeTime)
		end
	elseif event == "Hit" then
		local attacker, target, kind = a :: Model?, b :: Model?, c :: string
		if not target or not target.Parent then
			return
		end
		flash(target, kind)
		local blocked = kind == "Blocked" or kind == "PerfectBlock"
		local moveName = if type(d) == "string" then d else ""
		play3D(if blocked then "BlockHit" elseif HEAVY_MOVES[moveName] then "HeavyHit" else "PunchHit", HitboxService.RootOf(target))
		if kind == "GuardBreak" then
			shatter(target)
		end
		if kind ~= "Blocked" and kind ~= "PerfectBlock" then
			AnimationController.Play(target, "HitReaction", Config.AnimationSettings.HitReactionTime)
		end
		if attacker == char or target == char then
			shake()
		end
	end
end)
