--!strict
-- Every tunable combat number. "-- TUNE" marks a guess, not a value from the spec.
-- Damage numbers are HP on a 100-HP character, so they read as percentages.

local Config = {}

Config.Server = {
	RateLimit = 20, -- TUNE max remote calls per player per second; extra calls are dropped
	MaxHitDistance = 14, -- studs between root parts a hit claim may span (covers latency)
	MinStartupFraction = 0.5, -- TUNE a hit claim earlier than this fraction of the startup is rejected
	HitGrace = 0.2, -- TUNE a hit claim may arrive this long after the active window (latency)
	AirSpeed = 4, -- TUNE vertical speed (studs/s) that counts as airborne; replicates faster than position
	DebugMoves = true, -- print which move each click became, and why
}

Config.Effects = {
	FlashTime = 0.1, -- TUNE seconds a hit highlight stays
	ShakeIntensity = 0.35, -- TUNE studs of camera offset when you hit or get hit
	ShakeTime = 0.12, -- TUNE
	ShatterSize = 8, -- TUNE studs the guard-break burst grows to
	ShatterTime = 0.3, -- TUNE
	ShockwaveSize = 14, -- TUNE studs the downslam ring spreads to
	ShockwaveTime = 0.35, -- TUNE
	ShockwaveShakeRange = 40, -- TUNE players this close to a downslam feel the shake
	Colors = {
		Hit = Color3.fromRGB(255, 255, 255),
		Blocked = Color3.fromRGB(120, 170, 255),
		PerfectBlock = Color3.fromRGB(255, 230, 80),
		GuardBreak = Color3.fromRGB(255, 140, 0),
		Critical = Color3.fromRGB(255, 80, 80),
		BlackFlash = Color3.fromRGB(120, 0, 0),
		Shrine = Color3.fromRGB(170, 0, 0),
	},
}

Config.Movement = {
	WalkSpeed = 16,
	JumpHeight = 7.2,
	BlockWalkSpeed = 6,
	AttackWalkSpeed = 10, -- TUNE
}

Config.M1 = {
	ComboResetTime = 1.2, -- combo returns to hit 1 if the next click is later than this
	Damage = { 3, 3, 4, 4 }, -- 14 total
	HitStun = 0.45, -- hits 1-3
	Startup = 0.1, -- TUNE
	Active = 0.08, -- TUNE
	Endlag = 0.12, -- TUNE
	FinisherEndlag = 0.25, -- TUNE hit 4
	MicroDashSpeed = 20, -- TUNE studs/s forward step on hits 1-3
	MicroDashTime = 0.1,
	FinisherKnockback = 70, -- TUNE studs/s horizontal on a grounded 4th hit
	FinisherStun = 0.6, -- TUNE
	WhiffStun = 0.8, -- attacker stun for missing hit 4
	FinisherCooldown = 1.5, -- TUNE after a landed hit 4
	BlockLockout = 0.2, -- TUNE can't block this long after attacking
	-- No jumping while comboing, so holding Space only marks the 4th hit as an uppercut.
	-- A fresh Space tap between swings still jumps (that's the downslam input).
	JumpLock = true, -- toggle
	FreshJumpWindow = 0.2, -- TUNE seconds a fresh tap unlocks jumping
	Hitbox = { Size = Vector3.new(5, 5, 5), Offset = Vector3.new(0, 0, -2.5) },
}

Config.Block = {
	DotThreshold = 0.35, -- TUNE blocked if dot(defender look, toward attacker) > this; 0 = 180-degree arc
	MeterMax = 100,
	MeterPerHit = 15, -- TUNE block-meter damage per blocked hit
	MeterRegen = 10, -- TUNE per second
	GuardBreakStun = 1.5,
	PerfectWindow = 0.25, -- blocking this soon before an M1 lands
	CritMultiplier = 3,
	BlackFlashMultiplier = 6,
	BlackFlashMaxChain = 2,
	BuffDuration = 4,
	BlackFlashHeavyPercent = 0.24, -- Black Flash on a mini uppercut or downslam
}

Config.Dash = {
	Debug = true, -- print direction, vector and distance per dash
	-- Speed eases out (Quad Out) from Start to End over Duration, so a dash bursts then settles.
	-- Distance = Duration * (Start + 2 * End) / 3: front ~28 studs (was ~18), side/back ~17 (was ~10).
	FrontStartSpeed = 110, -- TUNE studs/s (was 88)
	FrontEndSpeed = 30, -- TUNE (was 16)
	FrontDuration = 0.5, -- TUNE (was 0.45)
	SideStartSpeed = 95, -- TUNE left, right and back (was 78)
	SideEndSpeed = 25, -- TUNE (was 12)
	SideDuration = 0.35, -- TUNE (was 0.28)
	FrontCooldown = 2, -- front dash has its own cooldown
	SideCooldown = 2, -- left, right and back share this one
	SideMinScale = 0.4, -- side/back speed multiplier at 0 health
	-- Horizontal-only force (PerAxis): gravity still acts, so you can dash off a ledge and fall naturally.
	HorizontalForce = 120000,
	FrontSteering = true, -- front dash curves while it runs
	-- Steer by the camera every frame (Front follows it, Back goes opposite, Left/Right follow its sides) and turn
	-- the body smoothly toward it. Off: the front dash follows the body, which AutoRotate turns toward held keys.
	CameraSteering = true,
	SideBackSteering = true, -- with CameraSteering, side and back dashes follow the camera too
	TurnSpeed = 18, -- TUNE how fast the body turns toward the camera mid-dash; lower = smoother
	FrontIFrames = 0.1, -- TUNE
	SideBackIFrames = 0.25, -- TUNE
	DiagonalBehavior = "Front", -- W+A / W+D; S+A / S+D is always Back
	-- Turn the character to the camera's facing when Q is pressed. Without it, Roblox's AutoRotate has already
	-- turned the body toward the held key, so "Left" (-RightVector) would point backwards.
	FaceCameraOnDash = true,
	MoverName = "DashMover", -- name of the dash Attachment, so interrupts can find and remove it
}

Config.Jab = {
	Hitbox = { Size = Vector3.new(5, 5, 5), Offset = Vector3.new(0, 0, -2.5) },
	DamagePercent = 0.04,
	CloseRange = 3, -- TUNE studs counted as "extremely close"
	ClosePercent = 0.053,
	CloseKnockback = true, -- toggle
	CloseKnockbackSpeed = 20, -- TUNE studs/s
	Stun = 1.0,
	BlockedRecovery = 0.4,
	RepeatWindow = 3,
	RepeatScale = 0.5,
	ImmunityAfterEnabled = true, -- toggle
	ImmunityAfter = 0.5,
	Startup = 0.04, -- TUNE animation timing
	Active = 0.08, -- TUNE
	Endlag = 0.15, -- TUNE
}

Config.Uppercut = {
	InputWindow = 0.15, -- jump then M1 within this
	DamagePercent = 0.05,
	LaunchVelocity = 48, -- studs/s upward
	LaunchedStun = 1.2, -- TUNE
	CooldownMiss = 2, -- TUNE
	CooldownHit = 1, -- TUNE
	Startup = 0.12, -- TUNE
	Active = 0.1, -- TUNE
	Endlag = 0.25, -- TUNE
	Mini = {
		DamagePercent = 0.03,
		LaunchVelocity = 30, -- TUNE
		LaunchedStun = 0.9, -- TUNE
		Startup = 0.1, -- TUNE
		Active = 0.08, -- TUNE
		Endlag = 0.12, -- TUNE short so a front dash can follow (uppercut dash tech)
	},
}

Config.Downslam = {
	DamagePercent = 0.06,
	SlamVelocity = 60, -- TUNE studs/s downward
	Cooldown = 3, -- TUNE
	Startup = 0.12, -- TUNE
	Active = 0.1, -- TUNE
	Endlag = 0.25, -- TUNE
	Hitbox = { Size = Vector3.new(7, 10, 7), Offset = Vector3.new(0, -2.5, -3) }, -- TUNE
	TrueDownslam = true, -- toggle: noCancel ragdoll after M1, M1, airborne M1
	UpsideDownTech = true, -- toggle
	UpsideDownWindow = 0.15,
	ShakeIntensity = 0.6, -- TUNE studs
	ShakeTime = 0.25, -- TUNE
}

Config.Stun = {
	KnockbackTime = 0.15, -- TUNE seconds a knockback velocity is held
	DamageDecayEnabled = false, -- toggle: each combo hit deals DamageDecay of the previous
	DamageDecay = 0.95,
	DecayResetTime = 1.5, -- TUNE
}

Config.Ragdoll = {
	Duration = 2,
	ImmunityAfter = 0.5,
	EvasiveIFrames = 0.4,
	EvasiveCooldown = 25, -- the evasive (dash out of a ragdoll) has its own long cooldown
	GetUpLift = 1.5, -- TUNE studs a recovering body is lifted so it stands up cleanly instead of clipping the floor
	GroundCheck = 4, -- TUNE studs below the root that count as grounded
	-- Joints that go limp, per rig, as { cone angle, twist min, twist max } in degrees (BallSocketConstraint limits).
	-- Joints not listed (the root joint) stay rigid so the body keeps following the HumanoidRootPart.
	JointLimits = {
		R6 = {
			Neck = { 40, -30, 30 }, -- TUNE
			["Left Shoulder"] = { 90, -45, 45 }, -- TUNE
			["Right Shoulder"] = { 90, -45, 45 }, -- TUNE
			["Left Hip"] = { 60, -30, 30 }, -- TUNE
			["Right Hip"] = { 60, -30, 30 }, -- TUNE
		},
		R15 = {
			Neck = { 40, -30, 30 }, -- TUNE
			Waist = { 25, -15, 15 }, -- TUNE
			LeftShoulder = { 90, -45, 45 }, -- TUNE
			RightShoulder = { 90, -45, 45 }, -- TUNE
			LeftElbow = { 70, -5, 5 }, -- TUNE
			RightElbow = { 70, -5, 5 }, -- TUNE
			LeftWrist = { 30, -10, 10 }, -- TUNE
			RightWrist = { 30, -10, 10 }, -- TUNE
			LeftHip = { 60, -30, 30 }, -- TUNE
			RightHip = { 60, -30, 30 }, -- TUNE
			LeftKnee = { 70, -5, 5 }, -- TUNE
			RightKnee = { 70, -5, 5 }, -- TUNE
			LeftAnkle = { 30, -10, 10 }, -- TUNE
			RightAnkle = { 30, -10, 10 }, -- TUNE
		},
	},
}

Config.WallCombo = {
	WallDistance = 4,
	Window = 0.2,
	DamagePercent = 0.12,
	Cooldown = 5,
	Stun = 1.0, -- TUNE
	MaxRange = 15, -- TUNE target must still be this close when the dash starts
}

Config.Hitbox = {
	Debug = false, -- draw each hitbox query as a red box
	DebugTime = 0.15, -- seconds a debug box stays
	DebugTransparency = 0.7,
	VFXFolderName = "CombatVFX", -- workspace folder for effects; hitboxes and line-of-sight ignore it
}

Config.AnimationSettings = {
	Fade = 0.05, -- TUNE seconds to fade action animations in/out; short = snappy
	PoseRise = 0.3, -- TUNE fallback poses without a hit time spend this fraction blending in
	PoseFall = 0.3, -- TUNE and this fraction blending out
	HitReactionTime = 0.25, -- TUNE
	DebugPoses = true, -- print which joints the fallback found on each character
	StopFade = 0.12, -- seconds an interrupted or finished action fades out, so limbs glide back
}

-- Procedural fallback poses, used when an animation id is missing or fails to load.
-- Degrees in torso space: X raises an arm forward (negative X leans the torso forward), Y turns, Z tilts.
-- Joints: RightArm, LeftArm, Torso. Flip a sign if a pose looks mirrored on your rig.
Config.Poses = {
	M1_1 = { RightArm = { 95, 25, 0 }, Torso = { 0, 25, 0 } }, -- TUNE right punch
	M1_2 = { LeftArm = { 95, -25, 0 }, Torso = { 0, -25, 0 } }, -- TUNE left punch
	M1_3 = { RightArm = { 85, 45, 0 }, Torso = { -5, 35, 0 } }, -- TUNE hook
	M1_4 = { RightArm = { 100, 10, 0 }, LeftArm = { 60, -10, 0 }, Torso = { -15, 35, 0 } }, -- TUNE heavy finisher
	DashFront = { Torso = { -25, 0, 0 }, RightArm = { -45, 0, 0 }, LeftArm = { -45, 0, 0 } }, -- TUNE
	DashBack = { Torso = { 15, 0, 0 }, RightArm = { 35, 0, 0 }, LeftArm = { 35, 0, 0 } }, -- TUNE
	DashLeft = { Torso = { 0, 0, 20 }, RightArm = { 0, 0, 30 }, LeftArm = { 0, 0, 30 } }, -- TUNE
	DashRight = { Torso = { 0, 0, -20 }, RightArm = { 0, 0, -30 }, LeftArm = { 0, 0, -30 } }, -- TUNE
	DashJab = { RightArm = { 95, 10, 0 }, Torso = { -15, 30, 0 } }, -- TUNE
	Uppercut = { RightArm = { 165, 15, 0 }, Torso = { 10, 30, 0 } }, -- TUNE raised arm
	MiniUppercut = { RightArm = { 130, 15, 0 }, Torso = { 5, 25, 0 } }, -- TUNE
	Downslam = { RightArm = { 60, 0, 0 }, LeftArm = { 60, 0, 0 }, Torso = { -35, 0, 0 } }, -- TUNE overhead slam
	BlockIdle = { RightArm = { 100, 35, 0 }, LeftArm = { 100, -35, 0 } }, -- TUNE crossed guard
	HitReaction = { Torso = { 20, 0, 0 }, RightArm = { 25, 0, 0 }, LeftArm = { 25, 0, 0 } }, -- TUNE
	Stunned = { Torso = { 15, 0, 8 }, RightArm = { 10, 0, 15 }, LeftArm = { 10, 0, -15 } }, -- TUNE
	MalevolentShrine = { RightArm = { 95, -25, 0 }, LeftArm = { 95, 25, 0 }, Torso = { -5, 0, 0 } }, -- TUNE hands raised to cast
	WorldSlashWindup = { RightArm = { 100, -40, 0 }, LeftArm = { 100, 40, 0 }, Torso = { -5, 0, 0 } }, -- TUNE hand signs
	WorldSlashRelease = { RightArm = { 90, 25, 0 }, Torso = { -15, 40, 0 } }, -- TUNE the swing
}

-- Malevolent Shrine: press Key; the shrine rises behind you and slashes fill an area for Duration seconds.
Config.MalevolentShrine = {
	Key = Enum.KeyCode.One,
	-- Looked up by name in ServerStorage, ReplicatedStorage and Workspace (case, spaces and underscores ignored).
	ModelName = "sukunago", -- the shrine model
	EffectName = "slash sukuna", -- the slash effect; its horizontal size becomes the attack radius
	Cooldown = 10, -- TUNE seconds, starts when you cast
	CastTime = 1.5, -- TUNE you are locked this long after pressing the key
	SoundDelay = 1.5, -- seconds after the key press before the activation sound plays and the domain starts rising
	RiseTime = 2.0, -- TUNE seconds the domain takes to rise; the slashes, damage and slash sound start when it's up
	BehindDistance = 12, -- TUNE studs behind you the shrine appears
	ModelYawOffset = 0, -- TUNE degrees; set 180 if the shrine's front faces the wrong way
	Duration = 15, -- seconds the attack lasts, counted from when the slashes begin (after the rise)
	TickInterval = 0.1, -- seconds between damage ticks
	DamagePerTick = 1, -- HP per tick: 1 every 0.1s = 10 per second, 150 over 15 seconds
	FlashEvery = 0.5, -- TUNE seconds between the red hit flashes on a target (every tick would flicker)
	-- The three Sound objects you put in the shrine (or slash) folder, by name. Empty = take that folder's Sounds
	-- in A-to-Z name order: 1st plays when you press the key, 2nd while the shrine rises, 3rd loops until it ends.
	SoundNames = {
		Cast = "Sukuna - Domain Expansion, Malevolent Shrine", -- on the key press
		Rise = "Jujutsu JJK - Sukuna Malevolent Shrine Activation", -- after SoundDelay, while the domain rises
		Loop = "malevolent shrine slashes (short)", -- loops while the slashes and damage run, stops when it ends
	},
	Radius = 0, -- studs; 0 = taken from the slash effect's size
	EffectScale = 1, -- TUNE scales the slash effect (and so the radius)
	FallbackRadius = 40, -- TUNE used when the effect is missing or has no size
	HeightLimit = 30, -- TUNE studs above/below the area center that still count
	FadeTime = 1.0, -- TUNE shrine sinks and slashes stop
	EmitInterval = 0.5, -- TUNE burst-style particle emitters fire this often
	EmitCount = 10, -- TUNE particles per burst (an "EmitCount" attribute on an emitter overrides it)
	ShakeRange = 60, -- TUNE players this close feel the camera shake when the shrine finishes rising
	ShakeIntensity = 0.5, -- TUNE
	ShakeTime = 0.4, -- TUNE
	DebugRadius = false, -- draw a ring showing the damage area
	-- An effect narrower than ScatterBelow studs is one slash, not an area: copies of it are scattered at random
	-- spots inside the radius instead (radius then = Radius, or FallbackRadius when Radius is 0).
	ScatterBelow = 8, -- TUNE studs
	ScatterInterval = 0.15, -- TUNE seconds between scattered slashes
	ScatterLifetime = 0.8, -- TUNE seconds each scattered slash stays
	-- Delete every Script, LocalScript and ModuleScript from the cloned shrine and effect. Free Toolbox models often
	-- carry scripts that load code from outside asset ids; the shrine and effect only need to be visual.
	-- Turn off only if your effect needs its own scripts to animate.
	StripScripts = true,
}

-- World Cutting Slash: hand signs while you turn with the camera, a short aim lock, then one long line slash
-- that goes through blocks.
Config.WorldSlash = {
	Key = Enum.KeyCode.Two,
	Cooldown = 1, -- TUNE seconds, from the key press (the move itself takes ~2s, so ~2s between casts)
	TrackTime = 1.1, -- seconds of hand signs and aura; you turn with the camera
	LockTime = 0.25, -- seconds the aim is locked while the slash forms
	Endlag = 0.6, -- TUNE recovery after the release
	Damage = 50, -- TUNE HP
	Stun = 1.0, -- TUNE
	Knockback = 65, -- TUNE studs/s away from you
	Length = 500, -- TUNE studs the slash flies (hitbox and visual)
	-- The slash is a # grid facing forward: VerticalLines up-down blades and HorizontalLines left-right blades,
	-- each set evenly spaced. The grid is also the hitbox's width and height.
	GridWidth = 169, -- TUNE studs across
	GridHeight = 80, -- TUNE studs tall
	GridLift = 37, -- TUNE studs the grid's center sits above the caster's root (37 puts its bottom near the feet)
	VerticalLines = 6, -- TUNE more = smaller gaps
	HorizontalLines = 4, -- TUNE more = smaller gaps
	LineThickness = 1.5, -- TUNE studs at a blade's middle; blades taper to sharp points at both ends
	BladeSegments = 16, -- pieces each blade is drawn with; more = smoother taper
	OutlineColor = Color3.fromRGB(255, 255, 255), -- TUNE the glowing edge around the black blades
	OutlineWidth = 0.5, -- TUNE studs of outline on each side
	SlashTilt = 0, -- degrees the grid leans around its flight direction; 0 = upright
	TravelTime = 1.0, -- TUNE seconds for the crescent to fly the full Length
	FadeTime = 0.3, -- TUNE
	Hyperarmor = true, -- hits during the windup still deal damage but don't interrupt it
	-- Sound object played from the caster the moment the slash fires; found by name in ServerStorage,
	-- ReplicatedStorage or Workspace (case, spaces and underscores ignored). "" = none.
	FireSoundName = "sukuna_WCS_hit_sfx",
	ImpactFrameTime = 0.08, -- seconds of black-and-white flash on release
	EffectRange = 300, -- TUNE players this close get the impact frame and camera shake
	ShakeIntensity = 0.6, -- TUNE
	ShakeTime = 0.3, -- TUNE
}

-- Sound ids ("rbxassetid://..."). Empty = silent. Use audio you own or that is public/free to use.
Config.Sounds = {
	DashWhoosh = "", -- short air burst, every dash
	DashSlide = "", -- ground skid, only when the dasher is on the ground
	Swing1 = "", -- fist whip on every swing
	PunchHit = "", -- normal hit
	HeavyHit = "", -- 4th M1, uppercut, downslam, wall combo
	BlockHit = "", -- blocked / perfect blocked
	EvasiveSound = "", -- ragdoll cancel
	ShrineRise = "", -- shrine rising
	ShrineSlash = "", -- slashes begin
	WorldSlashChant = "", -- hand signs / chant during the windup
	WorldSlashRelease = "", -- the slash tearing through
}

Config.SoundSettings = {
	PitchMin = 0.95, -- random playback speed per play, so repeats don't sound robotic
	PitchMax = 1.08,
	RollOffMin = 10, -- studs at full volume
	RollOffMax = 85, -- studs where it fades out
	EvasiveFlashTime = 0.35, -- TUNE white flash on a ragdoll cancel
}

-- Replace with your own uploaded animation ID. Animations must be published under the same account or
-- group that owns the experience or they will not play. "rbxassetid://0" uses the procedural fallback.
Config.Animations = {
	M1_1 = "rbxassetid://0", -- Replace with your own uploaded animation ID
	M1_2 = "rbxassetid://0", -- Replace with your own uploaded animation ID
	M1_3 = "rbxassetid://0", -- Replace with your own uploaded animation ID
	M1_4 = "rbxassetid://0", -- Replace with your own uploaded animation ID
	DashFront = "rbxassetid://0", -- Replace with your own uploaded animation ID
	DashBack = "rbxassetid://0", -- Replace with your own uploaded animation ID
	DashLeft = "rbxassetid://0", -- Replace with your own uploaded animation ID
	DashRight = "rbxassetid://0", -- Replace with your own uploaded animation ID
	DashJab = "rbxassetid://0", -- Replace with your own uploaded animation ID
	Uppercut = "rbxassetid://0", -- Replace with your own uploaded animation ID
	MiniUppercut = "rbxassetid://0", -- Replace with your own uploaded animation ID
	Downslam = "rbxassetid://0", -- Replace with your own uploaded animation ID
	BlockIdle = "rbxassetid://0", -- Replace with your own uploaded animation ID
	HitReaction = "rbxassetid://0", -- Replace with your own uploaded animation ID
	Stunned = "rbxassetid://0", -- Replace with your own uploaded animation ID
	MalevolentShrine = "rbxassetid://0", -- Replace with your own uploaded animation ID
	WorldSlashWindup = "rbxassetid://0", -- Replace with your own uploaded animation ID (hand signs)
	WorldSlashRelease = "rbxassetid://0", -- Replace with your own uploaded animation ID (the swing)
}

return Config
