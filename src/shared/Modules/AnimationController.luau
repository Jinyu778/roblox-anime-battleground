--!strict
-- Client-side animation playback. Real AnimationTracks play on your own character (the Animator replicates
-- them to everyone). Any id that is missing or fails to load uses ProceduralAnimations instead, which every
-- client runs for every character.
local Players = game:GetService("Players")
local ContentProvider = game:GetService("ContentProvider")

local Config = require(script.Parent.Config)
local StateHandler = require(script.Parent.StateHandler)

local fallbackModule = script.Parent:FindFirstChild("ProceduralAnimations")
-- delete ProceduralAnimations to drop the fallback; missing ids then play nothing
local Procedural: any = if fallbackModule then require(fallbackModule :: ModuleScript) else nil

local AnimationController = {}

-- Dashes and heavy moves override M1s; the dash punch overrides the dash it cuts short.
local PRIORITY: { [string]: Enum.AnimationPriority } = {
	DashFront = Enum.AnimationPriority.Action2,
	DashBack = Enum.AnimationPriority.Action2,
	DashLeft = Enum.AnimationPriority.Action2,
	DashRight = Enum.AnimationPriority.Action2,
	Uppercut = Enum.AnimationPriority.Action2,
	MiniUppercut = Enum.AnimationPriority.Action2,
	Downslam = Enum.AnimationPriority.Action2,
	DashJab = Enum.AnimationPriority.Action3,
}
-- Looped animation -> the state flag that keeps it playing.
local LOOPS: { [string]: string } = { BlockIdle = "Blocking", Stunned = "Stunned" }

type Entry = {
	tracks: { [string]: AnimationTrack },
	current: AnimationTrack?,
	token: number,
	connections: { RBXScriptConnection },
}

local entries: { [Model]: Entry } = {}
local tokens: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local warned: { [string]: boolean } = {}

local animationIds = Config.Animations :: { [string]: string }

function AnimationController.IsMissing(id: string?): boolean
	return id == nil or id == "" or id == "rbxassetid://0"
end

-- Playback speed that makes an animation of `length` last `duration`.
function AnimationController.SpeedFor(length: number, duration: number): number
	return if length > 0 and duration > 0 then length / duration else 1
end

assert(AnimationController.SpeedFor(1, 0.5) == 2, "a 1s animation squeezed into 0.5s plays at 2x")
assert(AnimationController.SpeedFor(0, 0.5) == 1, "unknown length plays at normal speed")
assert(AnimationController.IsMissing("rbxassetid://0") and not AnimationController.IsMissing("rbxassetid://123"), "missing ids")

local function warnOnce(name: string, why: string)
	if not warned[name] then
		warned[name] = true
		warn(string.format("[Anim] %s %s; using the procedural fallback", name, why))
	end
end

for name, id in animationIds do
	if AnimationController.IsMissing(id) then
		warnOnce(name, "has no id")
	end
end

local function isOwn(char: Model): boolean
	return char == Players.LocalPlayer.Character
end

if Procedural then
	Procedural.HasTrack = function(char: Model, name: string): boolean
		if isOwn(char) then
			local entry = entries[char]
			return entry ~= nil and entry.tracks[name] ~= nil
		end
		return not AnimationController.IsMissing(animationIds[name]) -- other players' real tracks replicate to us
	end
end

-- Loads and caches tracks for your own character. A new character after respawn gets a fresh cache.
function AnimationController.Load(char: Model): Entry
	local existing = entries[char]
	if existing then
		return existing
	end
	local entry: Entry = { tracks = {}, current = nil, token = 0, connections = {} }
	entries[char] = entry

	local hum = char:WaitForChild("Humanoid") :: Humanoid
	local animator = hum:WaitForChild("Animator") :: Animator
	for name, id in animationIds do
		if not AnimationController.IsMissing(id) then
			local animation = Instance.new("Animation")
			animation.AnimationId = id
			local track = animator:LoadAnimation(animation)
			track.Priority = PRIORITY[name] or Enum.AnimationPriority.Action
			track.Looped = LOOPS[name] ~= nil
			entry.tracks[name] = track
			-- an id that won't load (wrong id, or not owned by your account/group) drops to the fallback
			task.spawn(function()
				ContentProvider:PreloadAsync({ animation }, function(_, status)
					if status ~= Enum.AssetFetchStatus.Success and entry.tracks[name] == track then
						entry.tracks[name] = nil
						warnOnce(name, "failed to load (" .. status.Name .. ")")
					end
				end)
			end)
		end
	end

	for _, connection in StateHandler.BindInterrupts(char, function()
		AnimationController.Stop(char)
	end) do
		table.insert(entry.connections, connection)
	end
	for name, flag in LOOPS do
		table.insert(entry.connections, char:GetAttributeChangedSignal(flag):Connect(function()
			local track = entry.tracks[name]
			if track and char:GetAttribute(flag) == true then
				track:Play(Config.AnimationSettings.Fade)
			elseif track then
				track:Stop(Config.AnimationSettings.Fade)
			end
		end))
	end
	char.Destroying:Connect(function()
		for _, connection in entry.connections do
			connection:Disconnect()
		end
		entries[char] = nil
	end)
	return entry
end

-- Stops the current action animation (and procedural pose) and cancels any pending hit callback.
function AnimationController.Stop(char: Model)
	tokens[char] = (tokens[char] or 0) + 1
	local entry = entries[char]
	if entry and entry.current then
		entry.current:Stop(Config.AnimationSettings.StopFade) -- limbs glide back instead of snapping
		entry.current = nil
	end
	if Procedural then
		Procedural.Stop(char)
	end
end

-- Plays `name` stretched to `duration` seconds; a new action stops the previous one.
-- onHit fires once: at the animation's "Hit" marker, or at hitTime if the marker never comes,
-- and never after a stun, ragdoll or Stop.
function AnimationController.Play(char: Model, name: string, duration: number, hitTime: number?, onHit: (() -> ())?)
	AnimationController.Stop(char)
	local token = tokens[char]
	local fired = false
	local function hit()
		if fired or not onHit or tokens[char] ~= token or StateHandler.IsLocked(char) then
			return
		end
		fired = true
		onHit()
	end

	local own = isOwn(char)
	local track = if own then AnimationController.Load(char).tracks[name] else nil
	if track then
		local entry = entries[char]
		track:Play(Config.AnimationSettings.Fade)
		entry.current = track
		if track.Length > 0 then
			track:AdjustSpeed(AnimationController.SpeedFor(track.Length, duration))
		else
			-- first play: the asset may still be loading
			track:GetPropertyChangedSignal("Length"):Once(function()
				if track.IsPlaying then
					track:AdjustSpeed(AnimationController.SpeedFor(track.Length, duration))
				end
			end)
		end
		if onHit then
			local marker = track:GetMarkerReachedSignal("Hit"):Once(hit)
			track.Stopped:Once(function()
				marker:Disconnect()
			end)
		end
	elseif Procedural and (own or AnimationController.IsMissing(animationIds[name])) then
		if hitTime then
			Procedural.Play(char, name, hitTime, 0, math.max(duration - hitTime, 0.05))
		else
			Procedural.PlayFor(char, name, duration)
		end
	end

	if onHit then
		task.delay(hitTime or 0, hit) -- fallback timeout when the marker is missing or late
	end
end

return AnimationController
