-- Server-side hit detection.
local Players = game:GetService("Players")

local Hitbox = {}

local function characterOf(part: BasePart)
	local model = part:FindFirstAncestorWhichIsA("Model")
	while model and not model:FindFirstChildOfClass("Humanoid") do
		model = model:FindFirstAncestorWhichIsA("Model")
	end
	return model
end

local function sameTeam(a: Model, b: Model)
	local pa, pb = Players:GetPlayerFromCharacter(a), Players:GetPlayerFromCharacter(b)
	return pa ~= nil and pb ~= nil and not pa.Neutral and pa.Team == pb.Team
end

-- Every living enemy character overlapping `box` ({ Size, Offset }) relative to the attacker's root,
-- or to `origin` when given (e.g. where a dash is expected to be).
function Hitbox.Query(attacker: Model, box, origin: CFrame?): { Model }
	local root = attacker:FindFirstChild("HumanoidRootPart")
	if not root then
		return {}
	end
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { attacker }

	local found, list = {}, {}
	for _, part in workspace:GetPartBoundsInBox((origin or root.CFrame) * CFrame.new(box.Offset), box.Size, params) do
		local char = characterOf(part)
		if char and not found[char] and not sameTeam(attacker, char) then
			found[char] = true
			local hum = char:FindFirstChildOfClass("Humanoid")
			if hum and hum.Health > 0 and char:FindFirstChild("HumanoidRootPart") then
				table.insert(list, char)
			end
		end
	end
	return list
end

-- True if something solid is within `distance` studs behind the target along `direction` (flattened).
-- shortcut: only ignores the two fighters, so a third character behind the target counts as a wall; filter all characters if that matters.
function Hitbox.WallBehind(target: Model, direction: Vector3, distance: number, ignore: { Instance }): boolean
	local root = target:FindFirstChild("HumanoidRootPart")
	local flat = Vector3.new(direction.X, 0, direction.Z)
	if not root or flat.Magnitude < 1e-3 then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	return workspace:Raycast(root.Position, flat.Unit * distance, params) ~= nil
end

return Hitbox
