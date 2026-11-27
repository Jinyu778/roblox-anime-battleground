--!strict
-- Character combat state as attributes on the character model. The server writes them; clients read the
-- same attributes. Timed flags store an end time from workspace:GetServerTimeNow() and are cleared by one
-- Heartbeat loop (Step), so a second stun extends the first instead of an old timer cutting it short.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)

local StateHandler = {}

-- Timed flag -> the attribute holding when it ends.
StateHandler.TIMED = {
	Stunned = "StunEndTime",
	IFrames = "IFramesEndTime",
	Attacking = "AttackingEndTime",
	Dashing = "DashingEndTime",
	Launched = "LaunchedEndTime",
	Ragdolled = "RagdolledEndTime",
} :: { [string]: string }

local FLAGS = { "Stunned", "Blocking", "Attacking", "Dashing", "Airborne", "Launched", "Ragdolled", "IFrames" }
-- Any of these freezes the character: no moving, jumping, turning, attacking, blocking or dashing.
local LOCKING = { "Stunned", "Ragdolled", "Launched" }

local tracked: { [Model]: boolean } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end
StateHandler.Now = now

function StateHandler.Is(char: Model, flag: string): boolean
	return char:GetAttribute(flag) == true
end

-- A numeric attribute (timestamps, ComboCount), 0 when unset.
function StateHandler.Number(char: Model, name: string): number
	local value = char:GetAttribute(name)
	return if type(value) == "number" then value else 0
end

function StateHandler.IsLocked(char: Model): boolean
	for _, flag in LOCKING do
		if StateHandler.Is(char, flag) then
			return true
		end
	end
	return false
end

-- Free to start a new action: alive, not locked, not mid-attack or mid-dash.
function StateHandler.CanAct(char: Model): boolean
	local hum = char:FindFirstChildOfClass("Humanoid")
	return hum ~= nil
		and hum.Health > 0
		and not StateHandler.IsLocked(char)
		and not StateHandler.Is(char, "Attacking")
		and not StateHandler.Is(char, "Dashing")
end

function StateHandler.IsInvulnerable(char: Model): boolean
	return StateHandler.Is(char, "IFrames")
end

function StateHandler.IsStunImmune(char: Model): boolean
	return now() < StateHandler.Number(char, "StunImmuneUntil")
end

-- Applies WalkSpeed, JumpHeight and AutoRotate for the current flags. Called after every write, so
-- whatever ends a stun (or block, or attack) restores movement in one place.
function StateHandler.Refresh(char: Model)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return
	end
	local locked = StateHandler.IsLocked(char)
	local blocking = StateHandler.Is(char, "Blocking")
	local attacking = StateHandler.Is(char, "Attacking")
	hum.WalkSpeed = if locked
		then 0
		elseif blocking then Config.Movement.BlockWalkSpeed
		elseif attacking then Config.Movement.AttackWalkSpeed
		else Config.Movement.WalkSpeed
	hum.JumpHeight = if locked or blocking or attacking then 0 else Config.Movement.JumpHeight
	hum.AutoRotate = not locked -- a stunned player can't spin to face a curving dash
end

-- Removes server-made dash movers. The owning client removes its own (see BindInterrupts).
local function destroyMovers(char: Model)
	local root = char:FindFirstChild("HumanoidRootPart")
	if root then
		for _, child in root:GetChildren() do
			if child.Name == Config.Dash.MoverName then
				child:Destroy()
			end
		end
	end
end

function StateHandler.SetFlag(char: Model, flag: string, value: boolean)
	char:SetAttribute(flag, value)
	StateHandler.Refresh(char)
end

-- Turns a timed flag on until at least now + duration; never shortens a longer one already running.
function StateHandler.SetTimed(char: Model, flag: string, duration: number)
	local endName = StateHandler.TIMED[flag]
	assert(endName, flag .. " is not a timed flag")
	char:SetAttribute(endName, math.max(StateHandler.Number(char, endName), now() + duration))
	StateHandler.SetFlag(char, flag, true)
end

function StateHandler.Clear(char: Model, flag: string)
	local endName = StateHandler.TIMED[flag]
	if endName then
		char:SetAttribute(endName, 0)
	end
	StateHandler.SetFlag(char, flag, false)
end

function StateHandler.GrantStunImmunity(char: Model, duration: number)
	char:SetAttribute("StunImmuneUntil", math.max(StateHandler.Number(char, "StunImmuneUntil"), now() + duration))
end

-- Cancels the current attack, dash and block (used by stuns, ragdolls and launches).
function StateHandler.Interrupt(char: Model)
	char:SetAttribute("Attacking", false)
	char:SetAttribute("AttackingEndTime", 0)
	char:SetAttribute("Dashing", false)
	char:SetAttribute("DashingEndTime", 0)
	char:SetAttribute("Blocking", false)
	destroyMovers(char)
end

-- Stuns and interrupts. Returns false (and does nothing) while the character is stun-immune,
-- unless ignoreImmunity is set (e.g. the upside-down downslam tech).
function StateHandler.Stun(char: Model, duration: number, ignoreImmunity: boolean?): boolean
	if not ignoreImmunity and StateHandler.IsStunImmune(char) then
		return false
	end
	StateHandler.Interrupt(char)
	StateHandler.SetTimed(char, "Stunned", duration)
	return true
end

-- Called when a timed flag runs out on its own (not when something else clears it).
StateHandler.OnExpire = {} :: { [string]: (Model) -> () }

-- Clears every timed flag whose end time has passed. The server runs this every Heartbeat.
function StateHandler.Step(t: number)
	for char in tracked do
		for flag, endName in StateHandler.TIMED do
			if char:GetAttribute(flag) == true and t >= StateHandler.Number(char, endName) then
				StateHandler.Clear(char, flag)
				local hook = StateHandler.OnExpire[flag]
				if hook then
					hook(char)
				end
			end
		end
	end
end

-- Server: gives a character its attributes and starts tracking it. Safe to call again.
function StateHandler.Init(char: Model)
	if tracked[char] then
		return
	end
	tracked[char] = true
	for _, flag in FLAGS do
		char:SetAttribute(flag, false)
	end
	for _, endName in StateHandler.TIMED do
		char:SetAttribute(endName, 0)
	end
	char:SetAttribute("ComboCount", 0)
	char:SetAttribute("LastM1Time", 0)
	char:SetAttribute("StunImmuneUntil", 0)

	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.UseJumpPower = false
		hum.Died:Connect(function()
			for _, flag in FLAGS do
				char:SetAttribute(flag, false)
			end
			destroyMovers(char)
		end)
	end
	char.Destroying:Connect(function()
		tracked[char] = nil
	end)
	char.AncestryChanged:Connect(function()
		if not char:IsDescendantOf(game) then
			tracked[char] = nil
		end
	end)
	StateHandler.Refresh(char)
end

-- Server: like Init, but only for characters that don't have state yet (NPC dummies hit for the first time).
function StateHandler.Ensure(char: Model)
	if char:GetAttribute("Stunned") == nil or not tracked[char] then
		StateHandler.Init(char)
	end
end

-- Client: calls onInterrupt whenever the character becomes stunned, ragdolled or launched, so the owner
-- can stop its animations and destroy its own dash mover (the server can't see client-made instances).
function StateHandler.BindInterrupts(char: Model, onInterrupt: () -> ()): { RBXScriptConnection }
	local connections = {}
	for _, flag in LOCKING do
		table.insert(connections, char:GetAttributeChangedSignal(flag):Connect(function()
			if char:GetAttribute(flag) == true then
				onInterrupt()
			end
		end))
	end
	return connections
end

local started = false

-- Server: starts the Heartbeat loop and gives every player character its state.
function StateHandler.Start()
	assert(RunService:IsServer(), "StateHandler.Start runs on the server")
	if started then
		return
	end
	started = true
	RunService.Heartbeat:Connect(function()
		StateHandler.Step(now())
	end)
	local function onCharacter(char: Model)
		char:WaitForChild("Humanoid")
		StateHandler.Init(char)
	end
	local function onPlayer(player: Player)
		player.CharacterAdded:Connect(onCharacter)
		if player.Character then
			task.spawn(onCharacter, player.Character)
		end
	end
	Players.PlayerAdded:Connect(onPlayer)
	for _, player in Players:GetPlayers() do
		task.spawn(onPlayer, player)
	end
end

-- Checks the stun rules on a throwaway rig. Errors loudly if any rule is broken.
function StateHandler.SelfTest()
	local model = Instance.new("Model")
	local hum = Instance.new("Humanoid")
	hum.Parent = model
	StateHandler.Init(model)
	local t0 = now()

	assert(StateHandler.Stun(model, 1), "stun applies")
	assert(hum.WalkSpeed == 0 and hum.JumpHeight == 0 and not hum.AutoRotate, "stun freezes movement")
	StateHandler.Stun(model, 0.2)
	StateHandler.Step(t0 + 0.5)
	assert(StateHandler.Is(model, "Stunned"), "a shorter second stun must not cut the first short")
	StateHandler.Stun(model, 3)
	StateHandler.Step(t0 + 2)
	assert(StateHandler.Is(model, "Stunned"), "a longer second stun extends the first")
	StateHandler.Step(t0 + 3.5)
	assert(not StateHandler.Is(model, "Stunned"), "stun clears once its end time passes")
	assert(hum.WalkSpeed == Config.Movement.WalkSpeed and hum.AutoRotate, "movement restores after stun")

	StateHandler.SetFlag(model, "Attacking", true)
	StateHandler.Stun(model, 1)
	assert(not StateHandler.Is(model, "Attacking"), "stun interrupts an attack")
	StateHandler.Clear(model, "Stunned")

	StateHandler.GrantStunImmunity(model, 5)
	assert(not StateHandler.Stun(model, 1), "immunity blocks a stun")
	assert(StateHandler.Stun(model, 1, true), "ignoreImmunity overrides it")

	tracked[model] = nil
	model:Destroy()
end

return StateHandler
