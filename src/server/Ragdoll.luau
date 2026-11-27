--!strict
-- Ragdoll: turns the limb joints listed in Config.Ragdoll.JointLimits (R6 or R15, picked by Humanoid.RigType)
-- into BallSocketConstraints, and restores them exactly. Works with Motor6D and AnimationConstraint joints.
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Config = require(Modules:WaitForChild("Config"))
local StateHandler = require(Modules:WaitForChild("StateHandler"))

local Ragdoll = {}

type Entry = {
	joints: { Instance },
	extras: { Instance }, -- constraints and attachments we created
	collide: { [BasePart]: boolean },
	died: RBXScriptConnection?,
}

local saved: { [Model]: Entry } = setmetatable({}, { __mode = "k" }) :: any

local function limitsFor(hum: Humanoid): { [string]: { number } }
	local limits = Config.Ragdoll.JointLimits :: { [string]: { [string]: { number } } }
	return if hum.RigType == Enum.HumanoidRigType.R6 then limits.R6 else limits.R15
end

function Ragdoll.IsRagdolled(char: Model): boolean
	return saved[char] ~= nil
end

-- Joints off, ball sockets on. Safe to call twice.
function Ragdoll.Start(char: Model)
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = char:FindFirstChild("HumanoidRootPart")
	if saved[char] or not hum or not root then
		return
	end
	local entry: Entry = { joints = {}, extras = {}, collide = {}, died = nil }
	saved[char] = entry
	local limits = limitsFor(hum)

	for _, joint in char:GetDescendants() do
		local isMotor = joint:IsA("Motor6D")
		local limit = limits[joint.Name]
		if limit and (isMotor or joint:IsA("AnimationConstraint")) and (joint :: any).Enabled then
			local j = joint :: any
			local part0: Instance? = if isMotor then j.Part0 else (j.Attachment0 and j.Attachment0.Parent)
			local part1: Instance? = if isMotor then j.Part1 else (j.Attachment1 and j.Attachment1.Parent)
			if part0 and part1 and part0:IsA("BasePart") and part1:IsA("BasePart") and part0 ~= root and part1 ~= root then
				-- Motor6D has no attachments of its own; an AnimationConstraint's can be reused
				local a0: Attachment, a1: Attachment
				if isMotor then
					a0 = Instance.new("Attachment")
					a0.CFrame = j.C0
					a0.Parent = part0
					a1 = Instance.new("Attachment")
					a1.CFrame = j.C1
					a1.Parent = part1
					table.insert(entry.extras, a0)
					table.insert(entry.extras, a1)
				else
					a0, a1 = j.Attachment0, j.Attachment1
				end
				local socket = Instance.new("BallSocketConstraint")
				socket.Attachment0 = a0
				socket.Attachment1 = a1
				socket.LimitsEnabled = true
				socket.UpperAngle = limit[1]
				socket.TwistLimitsEnabled = true
				socket.TwistLowerAngle = limit[2]
				socket.TwistUpperAngle = limit[3]
				socket.Parent = part0
				table.insert(entry.extras, socket)

				if entry.collide[part1] == nil then
					entry.collide[part1] = part1.CanCollide
					part1.CanCollide = true -- limbs would sink through the floor otherwise
				end
				j.Enabled = false
				table.insert(entry.joints, joint)
			end
		end
	end
	hum.PlatformStand = true
	entry.died = hum.Died:Once(function()
		Ragdoll.Stop(char) -- joints always come back, even if they die mid-ragdoll
	end)
end

-- Joints back on, our constraints removed, collisions restored.
function Ragdoll.Stop(char: Model)
	local entry = saved[char]
	if not entry then
		return
	end
	saved[char] = nil
	if entry.died then
		entry.died:Disconnect()
	end
	for _, instance in entry.extras do
		instance:Destroy()
	end
	for part, collide in entry.collide do
		part.CanCollide = collide
	end
	for _, joint in entry.joints do
		(joint :: any).Enabled = true
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	if hum then
		hum.PlatformStand = false
	end
	-- stand up cleanly: upright, same facing, lifted a little so the legs don't clip into the floor
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if root and hum and hum.Health > 0 then
		local _, yaw, _ = root.CFrame:ToOrientation()
		root.CFrame = CFrame.new(root.Position + Vector3.new(0, Config.Ragdoll.GetUpLift, 0)) * CFrame.Angles(0, yaw, 0)
		root.AssemblyLinearVelocity = Vector3.zero
		root.AssemblyAngularVelocity = Vector3.zero
	end
end

-- Ragdolls `char` for `duration` (interrupting whatever it was doing). Respects stun immunity unless
-- ignoreImmunity is set. noCancel denies the evasive dash out of this ragdoll. Returns whether it applied.
function Ragdoll.Apply(char: Model, duration: number, ignoreImmunity: boolean?, noCancel: boolean?): boolean
	StateHandler.Ensure(char)
	local hum = char:FindFirstChildOfClass("Humanoid")
	if not hum or hum.Health <= 0 or (not ignoreImmunity and StateHandler.IsStunImmune(char)) then
		return false
	end
	StateHandler.Interrupt(char)
	char:SetAttribute("RagdollNoCancel", noCancel == true)
	StateHandler.SetTimed(char, "Ragdolled", duration)
	Ragdoll.Start(char)
	return true
end

-- Getting up (ragdoll ran out, or evasive): joints back, 0.5s stun immunity, and the get-up time for later techs.
function Ragdoll.Recover(char: Model)
	Ragdoll.Stop(char)
	StateHandler.Clear(char, "Ragdolled")
	char:SetAttribute("RagdollNoCancel", false)
	char:SetAttribute("GotUpTime", StateHandler.Now())
	StateHandler.GrantStunImmunity(char, Config.Ragdoll.ImmunityAfter)
end

StateHandler.OnExpire.Ragdolled = Ragdoll.Recover

-- Ragdolls and restores a throwaway two-part rig.
function Ragdoll.SelfTest()
	local model = Instance.new("Model")
	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Parent = model
	local head = Instance.new("Part")
	head.Name = "Head"
	head.CanCollide = false
	head.Parent = model
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Parent = model
	local neck = Instance.new("Motor6D")
	neck.Name = "Neck"
	neck.Part0 = torso
	neck.Part1 = head
	neck.Parent = torso
	local hum = Instance.new("Humanoid")
	hum.RigType = Enum.HumanoidRigType.R6
	hum.Parent = model
	StateHandler.Init(model)

	local ok, err = pcall(function()
		assert(Ragdoll.Apply(model, 2), "ragdoll applies")
		assert(not neck.Enabled and torso:FindFirstChildOfClass("BallSocketConstraint"), "joint swapped for a ball socket")
		assert(hum.PlatformStand and head.CanCollide, "body goes limp and limbs collide")
		assert(StateHandler.Is(model, "Ragdolled") and hum.WalkSpeed == 0, "ragdoll locks the character")
		Ragdoll.Recover(model)
		assert(neck.Enabled and not torso:FindFirstChildOfClass("BallSocketConstraint"), "joint restored, socket removed")
		assert(not hum.PlatformStand and not head.CanCollide, "body and collisions restored")
		assert(StateHandler.IsStunImmune(model), "getting up grants stun immunity")
		assert(not Ragdoll.Apply(model, 2), "immunity blocks a new ragdoll")
		assert(Ragdoll.Apply(model, 2, true), "ignoreImmunity overrides it")
		Ragdoll.Stop(model)
	end)
	model:Destroy()
	if not ok then
		error(err, 0)
	end
end

return Ragdoll
