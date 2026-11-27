--!strict
-- Spatial-query hitboxes (Workspace:GetPartBoundsInBox) shared by client prediction and server validation.
local Players = game:GetService("Players")

local Config = require(script.Parent.Config)

local HitboxService = {}

export type Box = { Size: Vector3, Offset: Vector3 }
-- One per swing or dash: a target already in it is never returned again (one hit per target).
export type HitTable = { [Model]: boolean }

function HitboxService.VFXFolder(): Instance
	local folder = workspace:FindFirstChild(Config.Hitbox.VFXFolderName)
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = Config.Hitbox.VFXFolderName
		folder.Parent = workspace
	end
	return folder :: Instance
end

local function characterOf(part: BasePart): Model?
	local model = part:FindFirstAncestorWhichIsA("Model")
	while model and not model:FindFirstChildOfClass("Humanoid") do
		model = model:FindFirstAncestorWhichIsA("Model")
	end
	return model
end

local function sameTeam(a: Model, b: Model): boolean
	local pa, pb = Players:GetPlayerFromCharacter(a), Players:GetPlayerFromCharacter(b)
	return pa ~= nil and pb ~= nil and not pa.Neutral and pa.Team == pb.Team
end
HitboxService.SameTeam = sameTeam

local function rootOf(char: Model): BasePart?
	return char:FindFirstChild("HumanoidRootPart") :: BasePart?
end
HitboxService.RootOf = rootOf

local function drawDebug(cf: CFrame, size: Vector3)
	local part = Instance.new("Part")
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = Color3.fromRGB(255, 40, 40)
	part.Transparency = Config.Hitbox.DebugTransparency
	part.Size = size
	part.CFrame = cf
	part.Parent = HitboxService.VFXFolder()
	task.delay(Config.Hitbox.DebugTime, function()
		part:Destroy()
	end)
end

-- Living enemy characters inside `box`, placed relative to the attacker's root (or `origin`).
-- With a hitTable, targets already in it are skipped and new ones are added.
function HitboxService.Query(attacker: Model, box: Box, hitTable: HitTable?, origin: CFrame?): { Model }
	local root = rootOf(attacker)
	if not origin and not root then
		return {}
	end
	local cf = (origin or (root :: BasePart).CFrame) * CFrame.new(box.Offset)
	if Config.Hitbox.Debug then
		drawDebug(cf, box.Size)
	end

	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { attacker, HitboxService.VFXFolder() }

	local seen: { [Model]: boolean } = {}
	local found: { Model } = {}
	for _, part in workspace:GetPartBoundsInBox(cf, box.Size, params) do
		local char = characterOf(part)
		if char and not seen[char] then
			seen[char] = true
			local hum = char:FindFirstChildOfClass("Humanoid")
			local alive = hum ~= nil and hum.Health > 0 and rootOf(char) ~= nil
			if alive and not sameTeam(attacker, char) and not (hitTable and hitTable[char]) then
				if hitTable then
					hitTable[char] = true
				end
				table.insert(found, char)
			end
		end
	end
	return found
end

function HitboxService.Distance(a: Model, b: Model): number
	local ra, rb = rootOf(a), rootOf(b)
	if not ra or not rb then
		return math.huge
	end
	return (ra.Position - rb.Position).Magnitude
end

-- True when nothing solid (other than the two characters and effects) is between their root parts.
function HitboxService.LineOfSight(a: Model, b: Model): boolean
	local ra, rb = rootOf(a), rootOf(b)
	if not ra or not rb then
		return false
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { a, b, HitboxService.VFXFolder() }
	return workspace:Raycast(ra.Position, rb.Position - ra.Position, params) == nil
end

-- Builds two throwaway rigs far above the map and checks query, hit-table, distance and line of sight.
function HitboxService.SelfTest()
	local function rig(name: string, position: Vector3): Model
		local model = Instance.new("Model")
		model.Name = name
		local root = Instance.new("Part")
		root.Name = "HumanoidRootPart"
		root.Anchored = true
		root.Size = Vector3.new(2, 2, 1)
		root.CFrame = CFrame.lookAt(position, position + Vector3.new(0, 0, -1))
		root.Parent = model
		Instance.new("Humanoid").Parent = model
		model.Parent = workspace
		return model
	end
	local base = Vector3.new(0, 10000, 0)
	local attacker = rig("HitboxTestAttacker", base)
	local target = rig("HitboxTestTarget", base + Vector3.new(0, 0, -3))
	local debugWas = Config.Hitbox.Debug
	Config.Hitbox.Debug = false

	local ok, err = pcall(function()
		local hits: HitTable = {}
		local first = HitboxService.Query(attacker, { Size = Vector3.new(5, 5, 5), Offset = Vector3.new(0, 0, -2.5) }, hits)
		assert(#first == 1 and first[1] == target, "box in front finds the target")
		local second = HitboxService.Query(attacker, { Size = Vector3.new(5, 5, 5), Offset = Vector3.new(0, 0, -2.5) }, hits)
		assert(#second == 0, "hit-table allows one hit per target")
		local behind = HitboxService.Query(attacker, { Size = Vector3.new(5, 5, 5), Offset = Vector3.new(0, 0, 6) })
		assert(#behind == 0, "box behind misses")
		assert(math.abs(HitboxService.Distance(attacker, target) - 3) < 1e-3, "distance")
		assert(HitboxService.LineOfSight(attacker, target), "clear line of sight")
		local wall = Instance.new("Part")
		wall.Anchored = true
		wall.Size = Vector3.new(6, 6, 0.5)
		wall.Position = base + Vector3.new(0, 0, -1.5)
		wall.Parent = workspace
		local clear = HitboxService.LineOfSight(attacker, target)
		wall:Destroy()
		assert(not clear, "a wall blocks line of sight")
	end)
	Config.Hitbox.Debug = debugWas
	attacker:Destroy()
	target:Destroy()
	if not ok then
		error(err, 0)
	end
end

return HitboxService
