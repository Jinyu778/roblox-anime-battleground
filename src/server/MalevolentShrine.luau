--!strict
-- Malevolent Shrine: the shrine model rises behind the caster, the slash effect covers an area around the shrine,
-- and every enemy inside takes DamagePerTick every TickInterval seconds for Duration seconds.
-- The server decides everything; clients only animate the model and effect from attributes set here.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Config = require(Modules:WaitForChild("Config"))
local StateHandler = require(Modules:WaitForChild("StateHandler"))
local HitboxService = require(Modules:WaitForChild("HitboxService"))

local S = Config.MalevolentShrine
local now = StateHandler.Now
local FLAT = Vector3.new(1, 0, 1)

local MalevolentShrine = {}

local effects: RemoteEvent? = nil
local active: { [Model]: boolean } = {} -- casters with a shrine running

-- Number of damage ticks in one cast.
function MalevolentShrine.TickCount(duration: number, interval: number): number
	return math.floor(duration / interval + 1e-6)
end

-- Inside the cylinder: horizontal distance within radius, vertical distance within heightLimit.
function MalevolentShrine.InArea(center: Vector3, position: Vector3, radius: number, heightLimit: number): boolean
	return ((position - center) * FLAT).Magnitude <= radius and math.abs(position.Y - center.Y) <= heightLimit
end

function MalevolentShrine.Normalize(name: string): string
	return (string.lower(name):gsub("[^%w]", ""))
end

-- Assets ----------------------------------------------------------------------

local cache: { [string]: Instance } = {}
local warnedMissing: { [string]: boolean } = {}

local function debugLog(message: string)
	if Config.Server.DebugMoves then
		print("[Shrine] " .. message)
	end
end

-- "12 parts (3 visible), 4 emitters, 2 scripts" for the diagnostic lines.
local function describe(instance: Instance): string
	local parts, visible, emitters, scripts = 0, 0, 0, 0
	for _, d in instance:GetDescendants() do
		if d:IsA("BasePart") then
			parts += 1
			if d.Transparency < 1 then
				visible += 1
			end
		elseif d:IsA("ParticleEmitter") then
			emitters += 1
		elseif d:IsA("LuaSourceContainer") then
			scripts += 1
		end
	end
	if instance:IsA("BasePart") then
		parts += 1
		visible += if instance.Transparency < 1 then 1 else 0
	end
	return string.format("%d parts (%d visible), %d particle emitters, %d scripts", parts, visible, emitters, scripts)
end

-- How much there is to see: parts plus particle emitters inside (a lone part counts as 1).
local function weight(instance: Instance): number
	local n = if instance:IsA("BasePart") then 1 else 0
	for _, d in instance:GetDescendants() do
		if d:IsA("BasePart") or d:IsA("ParticleEmitter") then
			n += 1
		end
	end
	return n
end

-- Finds the model or effect by name in ServerStorage, ReplicatedStorage or Workspace. Several things can share a
-- name (an empty folder next to the real model), so it takes the match with the most to show and ignores empty ones.
local function findAsset(name: string): Instance?
	local cached = cache[name]
	if cached and cached.Parent then
		return cached
	end
	local wanted = MalevolentShrine.Normalize(name)
	local vfx = HitboxService.VFXFolder()
	local containers = { ServerStorage :: Instance, ReplicatedStorage :: Instance, workspace :: Instance }
	local best: Instance?, bestWeight = nil, 0
	local empty: { string } = {}
	for _, container in containers do
		for _, d in container:GetDescendants() do
			local usable = d:IsA("Model") or d:IsA("BasePart") or d:IsA("Folder")
			if usable and MalevolentShrine.Normalize(d.Name) == wanted and not d:IsDescendantOf(vfx) then
				local w = weight(d)
				if w > bestWeight then
					best, bestWeight = d, w
				elseif w == 0 then
					table.insert(empty, d:GetFullName())
				end
			end
		end
	end
	if best then
		cache[name] = best
		debugLog(string.format('using %s "%s" at %s: %s', best.ClassName, name, best:GetFullName(), describe(best)))
		return best
	end

	if not warnedMissing[name] then
		warnedMissing[name] = true
		local why = if #empty > 0 then "only EMPTY matches (" .. table.concat(empty, ", ") .. ")" else "no match"
		-- list what is there, so the real name can be spotted
		local seen: { string } = {}
		for _, container in containers do
			for _, child in container:GetChildren() do
				if (child:IsA("Model") or child:IsA("Folder")) and child ~= vfx and #seen < 40 then
					local entry = string.format("%s.%s[%d]", container.Name, child.Name, weight(child))
					-- one level deeper into small groups that hold something (not the map itself)
					if weight(child) > 0 and weight(child) < 500 then
						local inner: { string } = {}
						for _, grandchild in child:GetChildren() do
							if #inner < 15 then
								table.insert(inner, string.format("%s %s[%d]", grandchild.ClassName, grandchild.Name, weight(grandchild)))
							end
						end
						entry ..= " { " .. table.concat(inner, ", ") .. " }"
					end
					table.insert(seen, entry)
				end
			end
		end
		warn(string.format('[Shrine] "%s": %s. Top-level models/folders (name[parts+emitters]): %s', name, why, table.concat(seen, ", ")))
	end
	return nil
end

-- Hooks up the remote and takes the shrine and effect off the map: anything left in Workspace would sit there
-- in plain sight. In ServerStorage they stay hidden (and any scripts inside them can't run) until a cast clones them.
function MalevolentShrine.Init(remote: RemoteEvent)
	effects = remote
	for _, name in { S.ModelName, S.EffectName } do
		local asset = findAsset(name)
		if asset and asset:IsDescendantOf(workspace) then
			asset.Parent = ServerStorage
			debugLog(string.format('moved "%s" off the map into ServerStorage', asset.Name))
		end
	end
end

-- Wraps a lone part or a folder into a Model so it can be moved and measured as one.
local function asModel(instance: Instance): Model?
	if instance:IsA("Model") then
		return instance
	end
	local wrapper = Instance.new("Model")
	wrapper.Name = instance.Name
	if instance:IsA("BasePart") then
		instance.Parent = wrapper
	elseif instance:IsA("Folder") then
		for _, child in instance:GetChildren() do
			child.Parent = wrapper
		end
		instance:Destroy()
	else
		instance:Destroy()
		wrapper:Destroy()
		return nil
	end
	return wrapper
end

-- Visual only: no scripts, anchored, no collision, invisible to hitbox queries, so it can't run code, block or push anyone.
local function prepare(model: Model)
	for _, d in model:GetDescendants() do
		if S.StripScripts and d:IsA("LuaSourceContainer") then
			d:Destroy()
		elseif d:IsA("Sound") then
			d:Destroy() -- the three skill sounds are played on purpose; stray copies would auto-play
		elseif d:IsA("BasePart") then
			d.Anchored = true
			d.CanCollide = false
			d.CanQuery = false
			d.CanTouch = false
		end
	end
end

local function groundAt(position: Vector3, ignore: { Instance }): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local filter = table.clone(ignore)
	table.insert(filter, HitboxService.VFXFolder())
	params.FilterDescendantsInstances = filter
	local hit = workspace:Raycast(position + Vector3.new(0, 10, 0), Vector3.new(0, -100, 0), params)
	return if hit then hit.Position else position - Vector3.new(0, 3, 0) -- no floor found: assume standing height
end

-- Puts the model's bounding box on the ground, centered on `ground`, turned by `rotation`. Returns its size.
local function placeOnGround(model: Model, ground: Vector3, rotation: CFrame): Vector3
	if not model:FindFirstChildWhichIsA("BasePart", true) then
		return Vector3.zero
	end
	model:PivotTo(CFrame.new(ground) * rotation)
	local box, size = model:GetBoundingBox()
	local bottom = box.Position.Y - size.Y / 2
	model:PivotTo(model:GetPivot() + Vector3.new(ground.X - box.Position.X, ground.Y - bottom, ground.Z - box.Position.Z))
	return size
end

-- The slash effect packed inside the shrine (e.g. a "SlashVFX" next to the shrine model): the descendant with the
-- most particle emitters, the smallest one on a tie so the whole shrine isn't picked. nil if there are no emitters.
local function effectInside(shrineTemplate: Instance): Instance?
	local best: Instance?, bestEmitters, bestParts = nil, 0, math.huge
	for _, d in shrineTemplate:GetDescendants() do
		if d:IsA("Model") or d:IsA("Folder") or d:IsA("BasePart") then
			local emitters, parts = 0, if d:IsA("BasePart") then 1 else 0
			for _, x in d:GetDescendants() do
				if x:IsA("ParticleEmitter") then
					emitters += 1
				elseif x:IsA("BasePart") then
					parts += 1
				end
			end
			if emitters > bestEmitters or (emitters == bestEmitters and emitters > 0 and parts < bestParts) then
				best, bestEmitters, bestParts = d, emitters, parts
			end
		end
	end
	return best
end

-- Names from `root` down to `descendant`, so the same object can be found again inside a clone of root.
local function pathFrom(root: Instance, descendant: Instance): { string }?
	local path: { string } = {}
	local node: Instance? = descendant
	while node and node ~= root do
		table.insert(path, 1, node.Name)
		node = node.Parent
	end
	return if node == root then path else nil
end

-- Builds the shrine buried under the ground; clients tween it up from the attributes. Returns the model and its
-- final pose. `without` (the slash group packed in the same folder) is left out, so only the shrine rises.
local function buildShrine(template: Instance, ground: Vector3, facing: Vector3, without: Instance?): (Model?, CFrame?)
	local clone = template:Clone()
	local model = if clone then asModel(clone) else nil
	if not model then
		return nil, nil
	end
	local path = if without then pathFrom(template, without) else nil
	if path then
		local node: Instance? = model
		for _, name in path do
			node = if node then node:FindFirstChild(name) else nil
		end
		if node and node ~= model then
			node:Destroy()
		end
	end
	prepare(model)
	for _, e in model:GetDescendants() do
		if e:IsA("ParticleEmitter") then
			e:SetAttribute("WasEnabled", e.Enabled) -- particles stay off while it rises
			e.Enabled = false
		end
	end
	local yaw = CFrame.lookAt(Vector3.zero, facing) * CFrame.Angles(0, math.rad(S.ModelYawOffset), 0)
	local size = placeOnGround(model, ground, yaw)
	local final = model:GetPivot()
	local depth = size.Y + 1
	model:PivotTo(final - Vector3.new(0, depth, 0))
	model:SetAttribute("RiseTo", final)
	model:SetAttribute("RiseTime", S.RiseTime)
	model:SetAttribute("RiseStart", now())
	model:SetAttribute("Depth", depth)
	model:SetAttribute("FadeTime", S.FadeTime)
	model.Parent = HitboxService.VFXFolder()
	return model, final
end

-- Builds the slash effect centered on the area. Returns the model and its size (the radius comes from it).
-- slashesOnly hides every part that carries no particles, e.g. a second shrine built into the slash group.
local function buildEffect(template: Instance, center: Vector3, slashesOnly: boolean?): (Model?, Vector3)
	local clone = template:Clone()
	local model = if clone then asModel(clone) else nil
	if not model then
		return nil, Vector3.zero
	end
	prepare(model)
	if slashesOnly then
		for _, part in model:GetDescendants() do
			if part:IsA("BasePart") and not part:FindFirstChildWhichIsA("ParticleEmitter", true) then
				part.Transparency = 1
				for _, look in part:GetDescendants() do
					if look:IsA("Decal") or look:IsA("Texture") then
						look.Transparency = 1
					end
				end
			end
		end
	end
	if S.EffectScale ~= 1 then
		model:ScaleTo(S.EffectScale)
	end
	local size = placeOnGround(model, center, CFrame.identity)
	model:SetAttribute("SlashEmitInterval", S.EmitInterval)
	model:SetAttribute("SlashEmitCount", S.EmitCount)
	model.Parent = HitboxService.VFXFolder()
	return model, size
end

-- How far the slashes reach from the center: the farthest particle emitter, plus the part it sits on. Falls back to
-- half the model's footprint when it has no emitters. (The whole model's size can be far bigger than the slashes.)
local function slashRadius(model: Model, center: Vector3): number
	local reach = 0
	for _, e in model:GetDescendants() do
		if e:IsA("ParticleEmitter") then
			local holder = e.Parent
			local position: Vector3?, extent = nil, 0
			if holder and holder:IsA("Attachment") then
				position = holder.WorldPosition
			elseif holder and holder:IsA("BasePart") then
				position = holder.Position
				extent = math.max(holder.Size.X, holder.Size.Z) / 2
			end
			if position then
				reach = math.max(reach, ((position - center) * FLAT).Magnitude + extent)
			end
		end
	end
	if reach < 1 and model:FindFirstChildWhichIsA("BasePart", true) then
		local _, size = model:GetBoundingBox()
		reach = math.max(size.X, size.Z) / 2
	end
	return reach
end

local function makeRing(center: Vector3, radius: number): Part
	local ring = Instance.new("Part")
	ring.Shape = Enum.PartType.Cylinder
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 40, 40)
	ring.Transparency = 0.7
	ring.Size = Vector3.new(0.3, radius * 2, radius * 2)
	ring.CFrame = CFrame.new(center + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent = HitboxService.VFXFolder()
	return ring
end

-- Damage ------------------------------------------------------------------------

-- One tick: every living enemy inside the area loses DamagePerTick. Never the caster or a teammate
-- (HitboxService.Query), blocking doesn't stop it, i-frames and force fields do. `flash` sends the red hit flash.
local function damageArea(caster: Model, center: Vector3, radius: number, flash: boolean)
	local box = { Size = Vector3.new(radius * 2, S.HeightLimit * 2, radius * 2), Offset = Vector3.zero }
	for _, target in HitboxService.Query(caster, box, nil, CFrame.new(center)) do
		local targetRoot = HitboxService.RootOf(target)
		local hum = target:FindFirstChildOfClass("Humanoid")
		local protected = StateHandler.IsInvulnerable(target) or target:FindFirstChildOfClass("ForceField") ~= nil
		if targetRoot and hum and not protected and MalevolentShrine.InArea(center, targetRoot.Position, radius, S.HeightLimit) then
			hum:TakeDamage(S.DamagePerTick)
			if effects and flash then
				effects:FireAllClients("ShrineTick", target)
			end
		end
	end
end

-- Sounds ------------------------------------------------------------------------

local sounds: { Sound }? = nil

-- The Sound objects inside the shrine and slash folders, A to Z by name (found once).
local function folderSounds(): { Sound }
	if sounds then
		return sounds
	end
	local list: { Sound } = {}
	local wanted = { MalevolentShrine.Normalize(S.ModelName), MalevolentShrine.Normalize(S.EffectName) }
	local vfx = HitboxService.VFXFolder()
	for _, container in { ServerStorage :: Instance, ReplicatedStorage :: Instance, workspace :: Instance } do
		for _, d in container:GetDescendants() do
			if table.find(wanted, MalevolentShrine.Normalize(d.Name)) and not d:IsDescendantOf(vfx) then
				for _, x in d:GetDescendants() do
					if x:IsA("Sound") and not table.find(list, x) then
						table.insert(list, x)
					end
				end
			end
		end
	end
	table.sort(list, function(a, b)
		return a.Name < b.Name
	end)
	sounds = list
	local names = {}
	for _, x in list do
		table.insert(names, string.format("%s (%s)", x.Name, x.SoundId))
	end
	debugLog("sounds found (A to Z): " .. (if #names > 0 then table.concat(names, ", ") else "none"))
	return list
end

-- The sound for `role` ("Cast", "Rise", "Loop"): the one named in SoundNames, else the nth in A-to-Z order.
local function soundFor(role: string, index: number): Sound?
	local list = folderSounds()
	local name = (S.SoundNames :: { [string]: string })[role]
	if name and name ~= "" then
		for _, x in list do
			if MalevolentShrine.Normalize(x.Name) == MalevolentShrine.Normalize(name) then
				return x
			end
		end
		return nil
	end
	return list[index]
end

local function playSound(template: Sound?, parent: Instance?, looped: boolean): Sound?
	if not template or not parent then
		return nil
	end
	local sound = template:Clone()
	sound.Looped = looped
	sound.Parent = parent
	sound:Play()
	if not looped then
		sound.Ended:Once(function()
			sound:Destroy()
		end)
		Debris:AddItem(sound, 30) -- also cleans up a sound that never loads (audio this game may not use)
	end
	return sound
end

local function cleanup(shrine: Model?, effect: Model?, ring: Part?, loop: Sound?)
	if ring then
		ring:Destroy()
	end
	if loop then
		loop:Stop()
		loop:Destroy()
	end
	if effect then
		effect:SetAttribute("SlashEmitInterval", nil) -- clients stop bursting
		for _, d in effect:GetDescendants() do
			if d:IsA("ParticleEmitter") then
				d.Enabled = false
			end
		end
		task.delay(S.FadeTime + 1, function() -- let live particles finish
			effect:Destroy()
		end)
	end
	if shrine then
		shrine:SetAttribute("SlashEmitInterval", nil)
		for _, d in shrine:GetDescendants() do
			if d:IsA("ParticleEmitter") then
				d.Enabled = false
			end
		end
		shrine:SetAttribute("SinkAt", now()) -- clients sink it
		task.delay(S.FadeTime + 0.3, function()
			shrine:Destroy()
		end)
	end
end

local function run(char: Model, hum: Humanoid, root: BasePart)
	local shrine: Model?, effect: Model?, ring: Part?, loop: Sound?
	local function casterGone(): boolean
		return hum.Health <= 0 or not char:IsDescendantOf(workspace)
	end
	local ok, err = pcall(function()
		local look = root.CFrame.LookVector * FLAT
		look = if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)
		local casterGround = groundAt(root.Position, { char })
		local behind = groundAt(casterGround - look * S.BehindDistance + Vector3.new(0, 3, 0), { char })

		-- 1. key press: the "Domain Expansion" voice
		playSound(soundFor("Cast", 1), root, false)

		local shrineTemplate = findAsset(S.ModelName)
		local effectTemplate = findAsset(S.EffectName)
		if not effectTemplate and shrineTemplate then
			-- no separate "slash sukuna": use the effect packed inside the shrine folder
			effectTemplate = effectInside(shrineTemplate)
			if effectTemplate then
				debugLog(string.format("using the effect inside the shrine: %s (%s)", effectTemplate:GetFullName(), describe(effectTemplate)))
			end
		end
		-- A slash group packed in the shrine folder has a second shrine built into it: the plain shrine rises, and
		-- from the slash group only the particles are shown, or two shrines would appear.
		local packed = effectTemplate ~= nil and shrineTemplate ~= nil and effectTemplate:IsDescendantOf(shrineTemplate)

		task.wait(S.SoundDelay)
		if casterGone() then
			return
		end

		-- 2. activation sound while the domain rises behind the caster
		local center = behind
		local rising: Model?, final: CFrame? = nil, nil
		if shrineTemplate then
			rising, final = buildShrine(shrineTemplate, behind, look, if packed then effectTemplate else nil)
		end
		shrine = rising
		if rising and final then
			debugLog(string.format("domain rising: final position %s, you are at %s", tostring(final.Position), tostring(root.Position)))
			playSound(soundFor("Rise", 2), rising:FindFirstChildWhichIsA("BasePart", true) or root, false)
			task.wait(S.RiseTime)
			if rising.Parent then
				rising:PivotTo(final) -- clients already tweened to here
				for _, e in rising:GetDescendants() do
					if e:IsA("ParticleEmitter") then
						e.Enabled = e:GetAttribute("WasEnabled") == true
					end
				end
			end
		else
			center = casterGround -- nothing to rise: center on the caster
			playSound(soundFor("Rise", 2), root, false)
			task.wait(S.RiseTime)
		end
		if casterGone() then
			return
		end

		-- 3. the slashes, the damage and the slash sound all start now
		local radius = S.Radius
		local scatter = false
		local slashSource: Model? = nil
		if effectTemplate then
			local built, size = buildEffect(effectTemplate, center, packed)
			if built and math.max(size.X, size.Z) < S.ScatterBelow then
				-- one small slash: scatter copies over the area instead of one in the middle
				scatter = true
				built:Destroy()
				debugLog("effect is small, so copies of it are scattered across the area")
			else
				effect = built
				slashSource = built
			end
		end
		if radius <= 0 and slashSource then
			radius = slashRadius(slashSource, center)
		end
		if radius <= 0 then
			radius = S.FallbackRadius
		end
		debugLog(string.format("slashes started: radius %.1f studs around %s, %d ticks", radius, tostring(center), MalevolentShrine.TickCount(S.Duration, S.TickInterval)))
		if S.DebugRadius then
			ring = makeRing(center, radius)
		end
		local soundPart = if rising then rising:FindFirstChildWhichIsA("BasePart", true) else nil
		loop = playSound(soundFor("Loop", 3), soundPart or root, true)

		local ticks = MalevolentShrine.TickCount(S.Duration, S.TickInterval)
		local flashEvery = math.max(1, math.round(S.FlashEvery / S.TickInterval))
		local started = now()
		local done = 0
		local nextScatter = started
		while true do
			local t = now()
			if scatter and effectTemplate and t >= nextScatter then
				nextScatter = t + S.ScatterInterval
				local angle = math.random() * 2 * math.pi
				local distance = radius * math.sqrt(math.random()) -- even spread over the circle
				local spot = center + Vector3.new(math.cos(angle) * distance, 5, math.sin(angle) * distance)
				local slash = buildEffect(effectTemplate, groundAt(spot, { char }))
				if slash then
					task.delay(S.ScatterLifetime, function()
						slash:Destroy()
					end)
				end
			end
			while done < ticks and t >= started + (done + 1) * S.TickInterval do
				done += 1
				damageArea(char, center, radius, done % flashEvery == 1 or flashEvery == 1)
			end
			if done >= ticks or casterGone() then
				break
			end
			task.wait(0.1)
		end
	end)
	if not ok then
		warn("[Shrine] failed: " .. tostring(err))
	end
	cleanup(shrine, effect, ring, loop)
	active[char] = nil
end

-- Starts the skill if the caster may use it. Returns whether it started.
function MalevolentShrine.Cast(char: Model): boolean
	local function reject(reason: string): boolean
		if Config.Server.DebugMoves then
			print(string.format("[Shrine] %s cast rejected: %s", char.Name, reason))
		end
		return false
	end
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = HitboxService.RootOf(char)
	local remote = effects
	if not hum or hum.Health <= 0 or not root then
		return reject("no living character")
	end
	if not remote then
		return reject("not initialised (MalevolentShrine.Init was never called)")
	end
	if active[char] then
		return reject("a shrine is already running")
	end
	if not StateHandler.CanAct(char) or StateHandler.Is(char, "Blocking") then
		return reject("can't act right now (stunned, attacking, dashing, blocking or ragdolled)")
	end
	local wait = StateHandler.Number(char, "ShrineReadyTime") - now()
	if wait > 0 then
		return reject(string.format("on cooldown for %.0f more seconds", wait))
	end

	if Config.Server.DebugMoves then
		print(string.format("[Shrine] %s cast started", char.Name))
	end
	active[char] = true
	char:SetAttribute("ShrineReadyTime", now() + S.Cooldown)
	char:SetAttribute("BlockReadyTime", now() + S.CastTime + Config.M1.BlockLockout)
	StateHandler.SetTimed(char, "Attacking", S.CastTime)
	remote:FireAllClients("Swing", char, "MalevolentShrine", S.CastTime) -- the cast pose for everyone else
	task.spawn(run, char, hum, root)
	return true
end

-- Checks the tick math, the area test and the asset-name matching.
function MalevolentShrine.SelfTest()
	assert(MalevolentShrine.TickCount(15, 1) == 15, "15 seconds at 1 tick per second is 15 ticks")
	assert(MalevolentShrine.TickCount(15, 0.5) == 30, "tick count follows the interval")
	assert(MalevolentShrine.TickCount(15, 0.1) == 150, "15 seconds at a tick every 0.1s is 150 ticks")
	assert(MalevolentShrine.TickCount(S.Duration, S.TickInterval) * S.DamagePerTick > 0, "the shrine deals damage")

	local center = Vector3.new(10, 5, 10)
	assert(MalevolentShrine.InArea(center, Vector3.new(10, 8, 10), 40, 30), "the center is inside")
	assert(MalevolentShrine.InArea(center, Vector3.new(49, 5, 10), 40, 30), "just inside the radius")
	assert(not MalevolentShrine.InArea(center, Vector3.new(51, 5, 10), 40, 30), "just outside the radius")
	assert(not MalevolentShrine.InArea(center, Vector3.new(10, 40, 10), 40, 30), "too high is outside")

	assert(MalevolentShrine.Normalize("slash sukuna") == MalevolentShrine.Normalize("Slash_Sukuna"), "names ignore case, spaces and underscores")
	assert(MalevolentShrine.Normalize("sukunago") ~= MalevolentShrine.Normalize("slash sukuna"), "different names stay different")
end

return MalevolentShrine
