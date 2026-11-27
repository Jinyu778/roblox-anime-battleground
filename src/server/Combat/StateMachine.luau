-- Per-character combat state. Every state change goes through StateMachine.Set.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Config = require(ReplicatedStorage.Combat.Config)

local StateMachine = {}
StateMachine.OnExit = {} -- [stateName] = function(char, data), runs when that state is left

local data = {} -- [character Model] = combat data

local function now()
	return workspace:GetServerTimeNow()
end
StateMachine.Now = now

-- Returns the character's data, creating it on first use (works for players and NPC dummies).
function StateMachine.Get(char: Model)
	local d = data[char]
	if d then
		return d
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 then
		return nil
	end
	d = {
		State = "Idle",
		Token = 0, -- bumped on every Set so stale timers and swings can tell they were interrupted
		Until = 0,
		Combo = 0,
		LastSwingEnd = 0,
		M1Ready = 0,
		BlockLockUntil = 0,
		BlockStart = 0,
		Guard = 0,
		GuardTime = 0,
		DashReady = 0,
		SideDashReady = 0,
		SkillReady = {},
		IFrameUntil = 0,
		StunImmuneUntil = 0,
		HitCount = 0,
		LastHitTime = 0,
		Buff = nil,
		BuffUntil = 0,
		BlackFlashChain = 0,
		WallTarget = nil,
		WallUntil = 0,
		WallReady = 0,
	}
	data[char] = d
	hum.UseJumpPower = false
	char:SetAttribute("CombatState", "Idle")
	hum.Died:Connect(function()
		StateMachine.Set(char, "Dead")
	end)
	char.AncestryChanged:Connect(function()
		if not char:IsDescendantOf(game) then
			StateMachine.Remove(char)
		end
	end)
	return d
end

-- Enters `state`; with `duration`, returns to Idle afterwards unless something else changed the state first.
-- Returns the new token, or nil if the character is dead or untracked.
function StateMachine.Set(char: Model, state: string, duration: number?)
	local d = data[char]
	if not d or d.State == "Dead" then
		return nil
	end
	local old = d.State
	d.Token += 1
	local token = d.Token
	d.State = state
	d.Until = if duration then now() + duration else 0
	char:SetAttribute("CombatState", state)

	local hum = char:FindFirstChildOfClass("Humanoid")
	local movement = Config.Movement[state]
	if hum and movement then
		hum.WalkSpeed = movement.WalkSpeed
		hum.JumpHeight = movement.JumpHeight
	end

	if old ~= state and StateMachine.OnExit[old] then
		StateMachine.OnExit[old](char, d)
	end

	if duration then
		task.delay(duration, function()
			if data[char] == d and d.Token == token then
				StateMachine.Set(char, "Idle")
			end
		end)
	end
	return token
end

function StateMachine.Valid(char: Model, token: number?)
	local d = data[char]
	return d ~= nil and d.Token == token
end

function StateMachine.Remove(char: Model)
	local d = data[char]
	if not d then
		return
	end
	data[char] = nil
	local exit = StateMachine.OnExit[d.State]
	if exit then
		exit(char, d)
	end
end

return StateMachine
