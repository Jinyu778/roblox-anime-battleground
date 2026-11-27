--!strict
-- Procedural stand-in for animations that are missing or fail to load: rotates the arm and torso joints
-- (Motor6D or AnimationConstraint) toward Config.Poses. Delete this ModuleScript to remove it;
-- AnimationController then simply plays nothing for missing ids.
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Config = require(script.Parent.Config)

local ProceduralAnimations = {}

-- Set by AnimationController: true when this character already shows a real animation for `name`.
ProceduralAnimations.HasTrack = function(_char: Model, _name: string): boolean
	return false
end

local JOINT_NAMES: { [string]: { string } } = {
	RightArm = { "RightShoulder", "Right Shoulder" }, -- R15, R6
	LeftArm = { "LeftShoulder", "Left Shoulder" },
	Torso = { "Waist", "RootJoint" },
}

-- State flag -> pose held for as long as the flag is on.
local LOOP_POSES: { [string]: string } = { Blocking = "BlockIdle", Stunned = "Stunned" }
local CANCEL_FLAGS = { "Stunned", "Launched", "Ragdolled" }

type Playing = { name: string, start: number, rise: number, hold: number, fall: number }

local jointCache: { [Model]: { [string]: Instance } } = setmetatable({}, { __mode = "k" }) :: any
local playing: { [Model]: Playing } = {}

local poseRotations: { [string]: { [string]: CFrame } } = {}
for name, pose in Config.Poses :: { [string]: { [string]: { number } } } do
	poseRotations[name] = {}
	for joint, deg in pose do
		poseRotations[name][joint] = CFrame.fromEulerAnglesYXZ(math.rad(deg[1]), math.rad(deg[2]), math.rad(deg[3]))
	end
end

-- The joint's frame on its parent part: C0 for a Motor6D, Attachment0 for an AnimationConstraint.
local function jointFrame(joint: Instance): CFrame
	if joint:IsA("Motor6D") then
		return joint.C0
	end
	local attachment = (joint :: any).Attachment0 :: Attachment?
	return if attachment then attachment.CFrame else CFrame.identity
end

local function joints(char: Model): { [string]: Instance }
	local cached = jointCache[char]
	if cached then
		return cached
	end
	local found: { [string]: Instance } = {}
	for _, instance in char:GetDescendants() do
		local isJoint = instance:IsA("Motor6D") or instance:IsA("AnimationConstraint")
		if isJoint and (instance :: any).Enabled then
			for joint, names in JOINT_NAMES do
				if table.find(names, instance.Name) then
					found[joint] = instance
				end
			end
		end
	end
	jointCache[char] = found
	if Config.AnimationSettings.DebugPoses then
		local list = {}
		for joint, instance in found do
			table.insert(list, joint .. "=" .. instance.ClassName)
		end
		print("[Pose]", char.Name, if #list > 0 then table.concat(list, " ") else "NO JOINTS FOUND")
	end
	return found
end

-- Blends the pose over what the Animator wrote this frame, so walk/idle still shows underneath.
local function apply(char: Model, name: string, weight: number)
	local rotations = poseRotations[name]
	if not rotations then
		return
	end
	for joint, rotation in rotations do
		local instance = joints(char)[joint]
		if instance then
			local c0 = jointFrame(instance).Rotation
			local current = (instance :: any).Transform :: CFrame
			;(instance :: any).Transform = current:Lerp(c0:Inverse() * rotation * c0, weight)
		end
	end
end

-- rise = blend in, hold = full pose, fall = blend out (seconds). Replaces the character's current pose.
function ProceduralAnimations.Play(char: Model, name: string, rise: number, hold: number, fall: number)
	if poseRotations[name] then
		playing[char] = { name = name, start = os.clock(), rise = rise, hold = math.max(hold, 0), fall = fall }
	end
end

-- Same, spread over `duration` with the PoseRise/PoseFall fractions.
function ProceduralAnimations.PlayFor(char: Model, name: string, duration: number)
	local rise = duration * Config.AnimationSettings.PoseRise
	local fall = duration * Config.AnimationSettings.PoseFall
	ProceduralAnimations.Play(char, name, rise, duration - rise - fall, fall)
end

function ProceduralAnimations.Stop(char: Model)
	playing[char] = nil
end

-- 0..1 blend weight at `elapsed` seconds into a pose (ease-out in, hold, linear out).
function ProceduralAnimations.Weight(p: Playing, elapsed: number): number
	if elapsed < p.rise then
		return 1 - (1 - elapsed / p.rise) ^ 2
	elseif elapsed < p.rise + p.hold then
		return 1
	end
	return math.max(0, 1 - (elapsed - p.rise - p.hold) / p.fall)
end

do
	local p = { name = "", start = 0, rise = 0.1, hold = 0.1, fall = 0.2 }
	assert(ProceduralAnimations.Weight(p, 0) == 0, "starts at rest")
	assert(ProceduralAnimations.Weight(p, 0.15) == 1, "full during hold")
	assert(math.abs(ProceduralAnimations.Weight(p, 0.3) - 0.5) < 1e-6, "halfway out")
	assert(ProceduralAnimations.Weight(p, 1) == 0, "back at rest")
end

local function cancelled(char: Model, name: string): boolean
	for _, flag in CANCEL_FLAGS do
		if char:GetAttribute(flag) == true and not (name == "HitReaction" and flag == "Stunned") then
			return true
		end
	end
	return false
end

-- Stepped runs after the Animator has written the joints, so poses layer on top.
RunService.Stepped:Connect(function()
	local t = os.clock()
	for char, p in playing do
		local elapsed = t - p.start
		if not char.Parent or elapsed >= p.rise + p.hold + p.fall or cancelled(char, p.name) then
			playing[char] = nil
		else
			apply(char, p.name, ProceduralAnimations.Weight(p, elapsed))
		end
	end
	for _, player in Players:GetPlayers() do
		local char = player.Character
		if char and not playing[char] then
			for flag, pose in LOOP_POSES do
				if char:GetAttribute(flag) == true and not ProceduralAnimations.HasTrack(char, pose) then
					apply(char, pose, 1)
				end
			end
		end
	end
end)

return ProceduralAnimations
