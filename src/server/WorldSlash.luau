--!strict
-- World Cutting Slash: hand signs while the caster turns with the camera (TrackTime), a short aim lock (LockTime),
-- then one long line slash along the caster's facing that goes through blocks. The server times the move and
-- resolves every hit through CombatServer's resolveHit; clients only play the windup and slash visuals.
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerStorage = game:GetService("ServerStorage")
local Debris = game:GetService("Debris")

local Modules = ReplicatedStorage:WaitForChild("Modules")
local Config = require(Modules:WaitForChild("Config"))
local StateHandler = require(Modules:WaitForChild("StateHandler"))
local HitboxService = require(Modules:WaitForChild("HitboxService"))

local W = Config.WorldSlash
local now = StateHandler.Now
local FLAT = Vector3.new(1, 0, 1)

local WorldSlash = {}

local effects: RemoteEvent? = nil
local resolve: ((Model, Model, any) -> string)? = nil
local active: { [Model]: boolean } = {}

local fireSound: Sound? = nil

local function normalize(name: string): string
	return (string.lower(name):gsub("[^%w]", ""))
end

-- The Sound named `name` in ServerStorage, ReplicatedStorage or Workspace, or nil.
local function findSound(name: string): Sound?
	local wanted = normalize(name)
	for _, container in { ServerStorage :: Instance, ReplicatedStorage :: Instance, workspace :: Instance } do
		for _, d in container:GetDescendants() do
			if d:IsA("Sound") and normalize(d.Name) == wanted then
				return d
			end
		end
	end
	return nil
end

function WorldSlash.Init(remote: RemoteEvent, resolveHit: (Model, Model, any) -> string)
	effects = remote
	resolve = resolveHit
	if W.FireSoundName ~= "" then
		fireSound = findSound(W.FireSoundName)
		if not fireSound then
			warn(string.format('[WorldSlash] Sound "%s" not found in ServerStorage, ReplicatedStorage or Workspace', W.FireSoundName))
		elseif Config.Server.DebugMoves then
			print(string.format("[WorldSlash] fire sound: %s (%s)", fireSound:GetFullName(), fireSound.SoundId))
		end
	end
end

-- The line hitbox: a box Length long that starts at the caster, points along `look`, raised like the grid.
function WorldSlash.HitboxCFrame(origin: Vector3, look: Vector3): CFrame
	return CFrame.lookAt(origin, origin + look) * CFrame.new(0, W.GridLift, -W.Length / 2)
end

local function run(char: Model, hum: Humanoid, root: BasePart)
	local remote = effects :: RemoteEvent
	local function interrupted(): boolean
		return hum.Health <= 0 or not StateHandler.Is(char, "Attacking") or StateHandler.IsLocked(char)
	end

	task.wait(W.TrackTime)
	if interrupted() then
		return
	end
	local player = Players:GetPlayerFromCharacter(char)
	if player then
		remote:FireClient(player, "WorldSlashLock") -- the caster stops turning with the camera
	end
	task.wait(W.LockTime)
	if interrupted() then
		return
	end

	-- the caster's facing at this moment is the aim (their client kept it on the camera until the lock)
	local look = root.CFrame.LookVector * FLAT
	look = if look.Magnitude > 1e-3 then look.Unit else Vector3.new(0, 0, -1)
	if fireSound then
		local sound = fireSound:Clone() -- played on the server so everyone hears it, from the caster
		sound.Looped = false
		sound.Parent = root
		sound:Play()
		Debris:AddItem(sound, math.max(sound.TimeLength, 5) + 1)
	end
	remote:FireAllClients("WorldSlashRelease", char, root.Position, look)
	remote:FireAllClients("Swing", char, "WorldSlashRelease", W.Endlag)

	local box = { Size = Vector3.new(W.GridWidth, W.GridHeight, W.Length), Offset = Vector3.zero }
	for _, target in HitboxService.Query(char, box, nil, WorldSlash.HitboxCFrame(root.Position, look)) do
		if resolve and not StateHandler.IsInvulnerable(target) then
			resolve(char, target, {
				Name = "WorldSlash",
				Damage = W.Damage,
				Stun = W.Stun,
				GuardBreak = true, -- cuts through blocks
				Knockback = W.Knockback,
			})
		end
	end
end

-- Starts the move if the caster may use it. Returns whether it started.
function WorldSlash.Cast(char: Model): boolean
	local hum = char:FindFirstChildOfClass("Humanoid")
	local root = HitboxService.RootOf(char)
	local remote = effects
	if not hum or hum.Health <= 0 or not root or not remote then
		return false
	end
	if active[char] or not StateHandler.CanAct(char) or StateHandler.Is(char, "Blocking") then
		return false
	end
	if now() < StateHandler.Number(char, "WorldSlashReadyTime") then
		return false
	end

	active[char] = true
	local windup = W.TrackTime + W.LockTime
	local total = windup + W.Endlag
	char:SetAttribute("WorldSlashReadyTime", now() + W.Cooldown)
	char:SetAttribute("BlockReadyTime", now() + total + Config.M1.BlockLockout)
	StateHandler.SetTimed(char, "Attacking", total)
	-- rooted through the hand signs; StateHandler restores movement when Attacking ends
	hum.WalkSpeed = 0
	hum.JumpHeight = 0
	if W.Hyperarmor then
		char:SetAttribute("Hyperarmor", true)
	end
	remote:FireAllClients("WorldSlashWindup", char, windup)
	remote:FireAllClients("Swing", char, "WorldSlashWindup", windup)

	task.spawn(function()
		local ok, err = pcall(run, char, hum, root)
		if not ok then
			warn("[WorldSlash] failed: " .. tostring(err))
		end
		char:SetAttribute("Hyperarmor", nil) -- armor ends at the release (or when the move is cut short)
		active[char] = nil
	end)
	return true
end

-- Checks the hitbox geometry and the timing values.
function WorldSlash.SelfTest()
	local cf = WorldSlash.HitboxCFrame(Vector3.zero, Vector3.new(0, 0, -1))
	assert((cf.Position - Vector3.new(0, W.GridLift, -W.Length / 2)).Magnitude < 1e-4, "hitbox starts at the caster and reaches Length ahead")
	assert(cf.LookVector:Dot(Vector3.new(0, 0, -1)) > 0.999, "hitbox points where the caster looks")
	local sideways = WorldSlash.HitboxCFrame(Vector3.new(5, 0, 0), Vector3.new(1, 0, 0))
	assert((sideways.Position - Vector3.new(5 + W.Length / 2, W.GridLift, 0)).Magnitude < 1e-4, "hitbox follows any facing")
	assert(W.TrackTime > 0 and W.LockTime > 0 and W.Damage > 0, "the move has a windup and deals damage")
end

return WorldSlash
