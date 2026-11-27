-- Swaps limb joints (Motor6D or AnimationConstraint) for BallSocketConstraints and restores them exactly.
local Ragdoll = {}

local saved = {} -- [char] = { motors, extras, collide }

function Ragdoll.Start(char: Model)
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if saved[char] or not hum or not root then
		return
	end
	local entry = { motors = {}, extras = {}, collide = {} }
	saved[char] = entry

	for _, joint in char:GetDescendants() do
		-- newer avatars use AnimationConstraints (attachment-based) instead of Motor6Ds
		local isMotor = joint:IsA("Motor6D")
		if not (isMotor or joint:IsA("AnimationConstraint")) or not joint.Enabled then
			continue
		end
		local part0 = if isMotor then joint.Part0 else joint.Attachment0 and joint.Attachment0.Parent
		local part1 = if isMotor then joint.Part1 else joint.Attachment1 and joint.Attachment1.Parent
		-- the root joint stays so the body keeps following the HumanoidRootPart
		if part0 and part1 and part0:IsA("BasePart") and part1:IsA("BasePart") and part0 ~= root and part1 ~= root then
			-- Motor6D has no Attachment0/1 properties; reading them throws, so only AnimationConstraints reuse theirs
			local a0, a1
			if not isMotor then
				a0, a1 = joint.Attachment0, joint.Attachment1
			else
				a0 = Instance.new("Attachment")
				a0.CFrame = joint.C0
				a0.Parent = part0
				a1 = Instance.new("Attachment")
				a1.CFrame = joint.C1
				a1.Parent = part1
				table.insert(entry.extras, a0)
				table.insert(entry.extras, a1)
			end
			local socket = Instance.new("BallSocketConstraint")
			socket.Attachment0 = a0
			socket.Attachment1 = a1
			socket.LimitsEnabled = true
			socket.TwistLimitsEnabled = true
			socket.Parent = part0
			table.insert(entry.extras, socket)

			if entry.collide[part1] == nil then
				entry.collide[part1] = part1.CanCollide
				part1.CanCollide = true -- limbs would sink through the floor otherwise
			end
			joint.Enabled = false
			table.insert(entry.motors, joint)
		end
	end
	hum.PlatformStand = true
end

function Ragdoll.Stop(char: Model)
	local entry = saved[char]
	if not entry then
		return
	end
	saved[char] = nil
	for _, instance in entry.extras do
		instance:Destroy()
	end
	for part, collide in entry.collide do
		part.CanCollide = collide
	end
	for _, motor in entry.motors do
		motor.Enabled = true
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = false
	end
end

return Ragdoll
