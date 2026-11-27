-- Code-driven stand-in for animations that are missing or fail to load. Rotates the arm and torso joints
-- (Motor6D or AnimationConstraint) toward Config.Poses. Delete this ModuleScript to remove it entirely;
-- CombatClient falls back to doing nothing.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Config = require(ReplicatedStorage:WaitForChild("Combat"):WaitForChild("Config"))

local PoseFallback = {}

-- Set by CombatClient: true when this character already plays a real animation for `name`.
PoseFallback.hasTrack = function(_char: Model, _name: string): boolean
	return false
end

local JOINT_NAMES = {
	RightArm = { "RightShoulder", "Right Shoulder" }, -- R15, R6
	LeftArm = { "LeftShoulder", "Left Shoulder" },
	Torso = { "Waist", "RootJoint" },
}

-- States that hold a looping pose, and states that cancel one-shot poses.
local LOOP_POSES = { Blocking = "BlockIdle", Stunned = "Stunned" }
local CANCEL_STATES = { Stunned = true, Launched = true, Ragdolled = true, Dead = true }

local jointCache = setmetatable({}, { __mode = "k" }) -- [char] = { [joint] = Motor6D | AnimationConstraint }
local posing = {} -- [char] = { name, start, rise, hold, fall }

local poseRotations = {} -- [poseName] = { [joint] = CFrame in torso space }
for name, pose in Config.Poses do
	poseRotations[name] = {}
	for joint, deg in pose do
		poseRotations[name][joint] = CFrame.fromEulerAnglesYXZ(math.rad(deg[1]), math.rad(deg[2]), math.rad(deg[3]))
	end
end

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
function PoseFallback.play(char: Model, name: string, rise: number, hold: number, fall: number)
	if poseRotations[name] then
		posing[char] = { name = name, start = os.clock(), rise = rise, hold = hold, fall = fall }
	end
end

-- Same, spread over `duration` using the Config.PoseTiming fractions.
function PoseFallback.playFor(char: Model, name: string, duration: number)
	local rise, fall = duration * Config.PoseTiming.Rise, duration * Config.PoseTiming.Fall
	PoseFallback.play(char, name, rise, duration - rise - fall, fall)
end

function PoseFallback.stop(char: Model)
	posing[char] = nil
end

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
	for _, other in Players:GetPlayers() do
		local c = other.Character
		local loop = c and LOOP_POSES[c:GetAttribute("CombatState")]
		if loop and not posing[c] and not PoseFallback.hasTrack(c, loop) then
			applyPose(c, loop, 1)
		end
	end
end)

return PoseFallback
