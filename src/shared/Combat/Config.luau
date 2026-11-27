-- Every tunable combat number lives here. "-- TUNE" marks placeholders, not values from any existing game.
local Config = {}

Config.TileSize = 4 -- TUNE studs per dash "tile"
Config.RemoteRateLimit = 20 -- TUNE max combat inputs per player per second; extra inputs are dropped
Config.MaxLatencyComp = 0.15 -- max seconds a dash can be back-dated using the client's timestamp

-- Applied by StateMachine whenever a character enters a state.
Config.Movement = {
	Idle = { WalkSpeed = 16, JumpHeight = 7.2 },
	Attacking = { WalkSpeed = 8, JumpHeight = 0 }, -- TUNE
	Blocking = { WalkSpeed = 4, JumpHeight = 0 }, -- TUNE "greatly reduced"
	Dashing = { WalkSpeed = 16, JumpHeight = 0 },
	Stunned = { WalkSpeed = 2, JumpHeight = 0 }, -- TUNE
	Ragdolled = { WalkSpeed = 0, JumpHeight = 0 },
	Dead = { WalkSpeed = 0, JumpHeight = 0 },
}

Config.M1 = {
	ComboResetTime = 1.0, -- TUNE combo drops if the next click comes this long after the last swing ended
	WhiffStun = 0.8, -- TUNE attacker stun for missing the 4th hit
	FinisherCooldown = 1.5, -- TUNE M1 cooldown after the 4th hit connects
	BlockLockout = 0.2, -- TUNE can't block this long after a swing
	MarkerEarliest = 0.5, -- TUNE a client "Hit" marker can start the hitbox early, but not before this fraction of Startup
	Hitbox = { Size = Vector3.new(5, 5, 5), Offset = Vector3.new(0, 0, -3) }, -- TUNE box in front of the attacker
	-- Startup = windup, Active = hitbox window, Stun = target stun, Endlag = recovery. All seconds.
	Hits = {
		{ Damage = 3, Startup = 0.15, Active = 0.1, Stun = 0.35, Endlag = 0.1 }, -- TUNE timings
		{ Damage = 3, Startup = 0.15, Active = 0.1, Stun = 0.35, Endlag = 0.1 }, -- TUNE timings
		{ Damage = 4, Startup = 0.15, Active = 0.1, Stun = 0.35, Endlag = 0.1 }, -- TUNE timings
		{
			Damage = 4,
			Startup = 0.15, -- TUNE
			Active = 0.1, -- TUNE
			Stun = 0.35, -- TUNE
			Endlag = 0.3, -- TUNE
			Knockback = 60, -- TUNE studs/s horizontal
			Launch = 15, -- TUNE studs/s upward
			Ragdoll = true, -- finisher ragdoll toggle
			WallTrigger = true, -- can start a wall combo
		},
	},
}

Config.Block = {
	Arc = 180, -- degrees in front of the blocker that are covered
	PerfectWindow = 0.25, -- TUNE starting block this soon before an M1 lands is a perfect block
	GuardMax = 100, -- guard breaks at this value
	GuardPerHit = 20, -- TUNE guard gained per blocked hit
	GuardRegen = 10, -- TUNE guard drained per second
	GuardBreakStun = 1.5, -- TUNE blocker stun on guard break (meter or guard-breaker move)
	CritMultiplier = 3, -- next M1 after a perfect block
	BlackFlashMultiplier = 6, -- next M1 after a perfect block while already buffed
	BuffDuration = 4, -- seconds the buff waits for an M1
	BlackFlashMaxChain = 2, -- consecutive Black Flashes allowed
	BlackFlashMaxChainPass = 3, -- TUNE chain with the gamepass
	GamepassId = 0, -- TUNE your gamepass id; 0 disables the check
}

Config.Dash = {
	Debug = true, -- print direction, vector and distance for every authorized dash
	-- Dash directions always come from the camera. FaceCamera = true also forces shift-lock-style facing
	-- all the time; false leaves facing to Roblox (normal walking, or shift lock when the player toggles it).
	FaceCamera = false,
	OrbitRange = 20, -- TUNE side dashes curve around the nearest enemy within this many studs
	OrbitPull = 8, -- TUNE how hard an orbiting side dash holds its starting radius
	DiagonalBehavior = "Front", -- W+A / W+D: "Front" or "Side". S+A / S+D is always Back
	FrontDistance = 6, -- TUNE tiles (24 studs); was 4.5
	BackDistance = 6, -- TUNE tiles; was 4.5
	SideDistance = 4.5, -- TUNE tiles (18 studs), left and right; was 3
	-- speed = distance / duration: front ~69 studs/s (was 82), side ~60 (was 67)
	FrontDuration = 0.35, -- TUNE seconds
	BackDuration = 0.35, -- TUNE
	SideDuration = 0.3, -- TUNE
	ForwardCooldown = 5, -- shared by front and back
	SideCooldown = 2,
	SideMinScale = 0.4, -- side dash distance multiplier at 0 health
	IFrames = 0.1, -- TUNE
	HitWindow = 0.15, -- TUNE forward dash only hits this soon after starting
	HitPercent = 0.04, -- of target MaxHealth
	CloseRange = 3, -- TUNE studs counted as "very close"
	ClosePercent = 0.053, -- of target MaxHealth
	CloseKnockback = 40, -- TUNE studs/s
	HitStun = 0.4, -- TUNE
	Hitbox = { Size = Vector3.new(4, 5, 4), Offset = Vector3.new(0, 0, -2) }, -- TUNE
	GroundCheck = 4, -- TUNE studs below the root that count as grounded (ragdoll cancel)
}

Config.Stun = {
	KnockbackTime = 0.2, -- TUNE seconds a knockback velocity is held
	DecayEnabled = true, -- shrink stun on consecutive hits to stop infinites
	DecayPerHit = 0.08, -- TUNE stun lost per consecutive hit
	DecayMinScale = 0.5, -- TUNE stun never shrinks below this fraction
	DecayResetTime = 1.5, -- TUNE no hits for this long resets the count
}

Config.Ragdoll = {
	Duration = 2,
	ImmunityAfter = 0.5, -- stun immunity after getting up
}

Config.WallCombo = {
	Distance = 4, -- studs behind the target that count as a wall
	Window = 0.2, -- forward dash must start this soon after the trigger hit
	DamagePercent = 0.12, -- of target MaxHealth
	Cooldown = 5,
	Stun = 1.0, -- TUNE
	MaxRange = 15, -- TUNE target must still be this close when the dash starts
}

-- Guard breakers and wall-combo starters. Key = keyboard binding.
Config.Skills = {
	Shove = {
		Key = Enum.KeyCode.One,
		Cooldown = 6, -- TUNE
		Startup = 0.2, -- TUNE
		Active = 0.1, -- TUNE
		Endlag = 0.3, -- TUNE
		Damage = 2, -- TUNE
		Stun = 0.6, -- TUNE
		Knockback = 50, -- TUNE
		GuardBreak = true,
	},
	Uppercut = {
		Key = Enum.KeyCode.Two,
		Cooldown = 8, -- TUNE
		Startup = 0.25, -- TUNE
		Active = 0.1, -- TUNE
		Endlag = 0.35, -- TUNE
		Damage = 5, -- TUNE
		Stun = 0.8, -- TUNE
		Knockback = 10, -- TUNE
		Launch = 45, -- TUNE
		GuardBreak = true,
		WallTrigger = true,
	},
	NormalPunch = {
		Key = Enum.KeyCode.Three,
		Cooldown = 7, -- TUNE
		Startup = 0.3, -- TUNE
		Active = 0.1, -- TUNE
		Endlag = 0.3, -- TUNE
		Damage = 6, -- TUNE
		Stun = 0.7, -- TUNE
		Knockback = 40, -- TUNE
		GuardBreak = true,
		GuardBreakRange = 4, -- TUNE only breaks guard within this many studs
	},
	Downslam = {
		Key = Enum.KeyCode.Four,
		Cooldown = 10, -- TUNE
		Startup = 0.3, -- TUNE
		Active = 0.1, -- TUNE
		Endlag = 0.4, -- TUNE
		Damage = 6, -- TUNE
		Stun = 0.9, -- TUNE
		Launch = -30, -- TUNE downward
		Ragdoll = true,
		WallTrigger = true,
	},
}

Config.Client = {
	ShakeIntensity = 0.4, -- TUNE studs of camera offset
	ShakeTime = 0.15, -- TUNE
	FlashTime = 0.1, -- TUNE seconds a hit highlight stays
	AnimFade = 0.05, -- TUNE seconds to fade action animations in and out; short = snappy
	DashFOVBoost = 8, -- TUNE degrees added to the camera FOV during a dash
	DashFOVIn = 0.08, -- TUNE seconds to ease the FOV out
	DashFOVOut = 0.4, -- TUNE seconds to drift it back; longer = smoother
	DashTurnSpeed = 18, -- TUNE how fast the body turns to the dash facing; lower = smoother, higher = snappier
	DebugPoses = true, -- print which joints the code-driven poses found on each character
	TrailLifetime = 0.15, -- TUNE seconds a dash trail segment lingers
	TrailColor = Color3.fromRGB(230, 230, 255), -- TUNE
	PredictionWindow = 0.3, -- TUNE ignore the server's echo of a dash this client already predicted
	RingColor = Color3.fromRGB(255, 255, 255), -- TUNE dash ring at the feet
	RingStartSize = 3, -- TUNE studs
	RingEndSize = 9, -- TUNE studs
	RingTime = 0.25, -- TUNE seconds to expand and fade
	DustCount = 12, -- TUNE smoke particles per dash
	DebrisCount = 7, -- TUNE rocks left on the floor per dash
	DebrisSize = { 0.4, 1.0 }, -- TUNE min/max rock size in studs
	DebrisSpread = 3, -- TUNE studs around the feet
	DebrisLife = 3, -- TUNE seconds before rocks sink away
}

-- Replace with your own uploaded animation IDs ("rbxassetid://123..."). Empty strings are skipped.
-- Add a keyframe marker named "Hit" to M1 and skill animations to time the hitbox.
Config.Animations = {
	M1_1 = "",
	M1_2 = "",
	M1_3 = "",
	M1_4 = "",
	Shove = "",
	Uppercut = "",
	NormalPunch = "",
	Downslam = "",
	DashFront = "",
	DashBack = "",
	DashLeft = "",
	DashRight = "",
	BlockIdle = "", -- optional, looped while blocking
	HitReaction = "", -- optional
}

-- Code-driven animation, used for any entry above whose id is empty. Works without uploading anything.
-- Degrees in torso space: X raises an arm forward (negative X leans the torso forward), Y turns, Z tilts sideways.
-- Joints: RightArm, LeftArm, Torso (R15 and R6). Flip a sign here if a pose looks mirrored on your rig.
Config.Poses = {
	M1_1 = { RightArm = { 95, 25, 0 }, Torso = { 0, 25, 0 } }, -- TUNE right jab
	M1_2 = { LeftArm = { 95, -25, 0 }, Torso = { 0, -25, 0 } }, -- TUNE left jab
	M1_3 = { RightArm = { 85, 45, 0 }, Torso = { -5, 35, 0 } }, -- TUNE hook
	M1_4 = { RightArm = { 150, 10, 0 }, Torso = { -10, 30, 0 } }, -- TUNE rising finisher
	Shove = { RightArm = { 90, 10, 0 }, LeftArm = { 90, -10, 0 }, Torso = { -10, 0, 0 } }, -- TUNE
	Uppercut = { RightArm = { 165, 15, 0 }, Torso = { 10, 30, 0 } }, -- TUNE
	NormalPunch = { RightArm = { 95, 15, 0 }, Torso = { -10, 40, 0 } }, -- TUNE
	Downslam = { RightArm = { 170, 0, 0 }, LeftArm = { 170, 0, 0 }, Torso = { -30, 0, 0 } }, -- TUNE
	DashFront = { Torso = { -25, 0, 0 }, RightArm = { -45, 0, 0 }, LeftArm = { -45, 0, 0 } }, -- TUNE
	DashBack = { Torso = { 15, 0, 0 }, RightArm = { 35, 0, 0 }, LeftArm = { 35, 0, 0 } }, -- TUNE
	DashLeft = { Torso = { 0, 0, 20 }, RightArm = { 0, 0, 30 }, LeftArm = { 0, 0, 30 } }, -- TUNE
	DashRight = { Torso = { 0, 0, -20 }, RightArm = { 0, 0, -30 }, LeftArm = { 0, 0, -30 } }, -- TUNE
	BlockIdle = { RightArm = { 100, 35, 0 }, LeftArm = { 100, -35, 0 } }, -- TUNE crossed guard
	HitReaction = { Torso = { 20, 0, 0 }, RightArm = { 25, 0, 0 }, LeftArm = { 25, 0, 0 } }, -- TUNE
}
Config.PoseTiming = {
	Rise = 0.3, -- TUNE fraction of a dash/hit pose spent blending in (M1s use Startup instead)
	Fall = 0.3, -- TUNE fraction spent blending out (M1s use Endlag instead)
	HitReactionTime = 0.25, -- TUNE seconds
}

Config.Sounds = {
	Hit = "",
	Blocked = "",
	PerfectBlock = "",
	GuardBreak = "",
	Critical = "",
	BlackFlash = "",
	WallCombo = "",
}

Config.FlashColors = {
	Hit = Color3.fromRGB(255, 255, 255),
	Blocked = Color3.fromRGB(120, 170, 255),
	PerfectBlock = Color3.fromRGB(255, 230, 80),
	GuardBreak = Color3.fromRGB(255, 140, 0),
	Critical = Color3.fromRGB(255, 80, 80),
	BlackFlash = Color3.fromRGB(120, 0, 0),
	WallCombo = Color3.fromRGB(180, 80, 255),
}

-- Fill shared fields so every move can go straight into ApplyHit.
for i, hit in Config.M1.Hits do
	hit.Name = "M1_" .. i
	hit.IsM1 = true
	hit.Hitbox = Config.M1.Hitbox
end
for name, skill in Config.Skills do
	skill.Name = name
	skill.Hitbox = skill.Hitbox or Config.M1.Hitbox
end

return Config
