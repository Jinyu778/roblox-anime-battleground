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
	Launched = { WalkSpeed = 0, JumpHeight = 0 }, -- airborne after an uppercut; can't act until it ends
	Ragdolled = { WalkSpeed = 0, JumpHeight = 0 },
	Dead = { WalkSpeed = 0, JumpHeight = 0 },
}

Config.M1 = {
	ComboResetTime = 1.0, -- TUNE combo drops if the next click comes this long after the last swing ended
	WhiffStun = 0.5, -- TUNE attacker stun for missing the 4th hit (was 0.8)
	JumpLockTime = 1.0, -- TUNE jumping is locked this long after each M1 click; holding jump only marks the 4th as an uppercut
	FreshJumpWindow = 0.2, -- TUNE a fresh jump press between swings unlocks jumping this long (the downslam timing)
	FinisherCooldown = 1.5, -- TUNE M1 cooldown after the 4th hit connects
	BlockLockout = 0.2, -- TUNE can't block this long after a swing
	MarkerEarliest = 0.5, -- TUNE a client "Hit" marker can start the hitbox early, but not before this fraction of Startup
	Hitbox = { Size = Vector3.new(5, 5, 5), Offset = Vector3.new(0, 0, -3) }, -- TUNE box in front of the attacker
	-- Startup = windup, Active = hitbox window, Stun = target stun, Endlag = recovery. All seconds.
	Hits = {
		-- ~0.25s per swing (was 0.35); Stun stays above that so the string stays connected
		{ Damage = 3, Startup = 0.1, Active = 0.08, Stun = 0.35, Endlag = 0.07 }, -- TUNE timings
		{ Damage = 3, Startup = 0.1, Active = 0.08, Stun = 0.35, Endlag = 0.07 }, -- TUNE timings
		{ Damage = 4, Startup = 0.1, Active = 0.08, Stun = 0.35, Endlag = 0.07 }, -- TUNE timings
		{
			Damage = 4,
			Startup = 0.12, -- TUNE
			Active = 0.08, -- TUNE
			Stun = 0.35, -- TUNE
			Endlag = 0.2, -- TUNE (was 0.3)
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
	-- Every frame of a dash re-reads the camera: Front follows it, Back goes opposite, Left/Right follow its sides.
	-- Keeping a target in view while side dashing curves you around them.
	CameraSteer = true,
	OrbitRange = 0, -- TUNE >0: side dashes auto-curve around the nearest enemy within this many studs (ignores the camera)
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
	GroundCheck = 4, -- TUNE studs below the root that count as grounded (ragdoll cancel, airborne check)
}

-- Front dash hit. The move data (damage, stun, animation timing) is Config.Moves.DashJab.
Config.DashJab = {
	Window = 0.15, -- TUNE jab hitbox is live this long after a FRONT dash starts; back/side dashes never jab
	Hitbox = { Size = Vector3.new(4, 5, 5), Offset = Vector3.new(0, 0, -2.5) }, -- TUNE ~5 studs forward
	CloseRange = 3, -- TUNE studs counted as "extremely close"
	ClosePercent = 0.053, -- of target MaxHealth at close range
	Knockback = false, -- jabKnockback: off keeps follow-ups connected
	CloseKnockback = 25, -- TUNE studs/s, only when Knockback is on
	HitRecovery = 0.15, -- TUNE attacker can act this soon after a landed jab
	BlockedRecovery = 0.4, -- TUNE attacker recovery after a blocked jab
	RepeatWindow = 3, -- TUNE a target jab-stunned this recently...
	RepeatScale = 0.5, -- TUNE ...gets this fraction of the stun (anti stun-lock)
	ImmunityAfterEnabled = true, -- toggle: stun immunity when a jab stun runs out untouched
	ImmunityAfter = 0.5, -- TUNE
}

Config.Stun = {
	KnockbackTime = 0.2, -- TUNE seconds a knockback velocity is held
	LaunchHold = 0.05, -- TUNE seconds a launch velocity is held before gravity takes over
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

Config.Combo = {
	DamageDecayEnabled = false, -- toggle: each consecutive hit on a target does DamageDecay of the previous
	DamageDecay = 0.95, -- TUNE
}

-- Context moves (no key of their own). Percent = share of the target's MaxHealth.
-- Startup/Active/Endlag also set how long the animation or fallback pose lasts.
Config.Moves = {
	DashJab = {
		Percent = 0.04,
		Stun = 1.0, -- jabStunDuration
		Startup = 0.04, -- TUNE animation timing only; the dash is the hitbox window
		Active = 0.08, -- TUNE
		Endlag = 0.15, -- TUNE
		IsJab = true,
		PerfectBlockable = true, -- not a guard breaker; perfect block works on it
		Hitbox = Config.DashJab.Hitbox,
	},
	-- Input: hold jump while clicking the 4th M1 (grounded), or jump then click within InputWindow as an opener.
	-- The target flies up, lands, and stays ragdolled RagdollDuration after landing.
	Uppercut = {
		InputWindow = 0.15, -- TUNE uppercutInputWindow
		Ragdoll = true,
		RagdollDuration = 1.5, -- TUNE seconds on the ground after landing
		M1Lockout = 0.8, -- TUNE your M1 is locked this long after an uppercut
		Percent = 0.05, -- TUNE
		Startup = 0.12, -- TUNE
		Active = 0.1, -- TUNE
		Endlag = 0.25, -- TUNE
		Stun = 1.2, -- TUNE target airborne stun (Launched state)
		LaunchHeight = 8, -- TUNE studs
		Knockback = 5, -- TUNE studs/s
		GuardBreak = true,
		WallTrigger = true,
		CooldownHit = 1, -- TUNE
		CooldownMiss = 2, -- TUNE
	},
	-- The opener input right after a landed jab becomes this combo extender (no ragdoll, no lockout).
	MiniUppercut = {
		Percent = 0.03, -- TUNE
		Startup = 0.1, -- TUNE
		Active = 0.08, -- TUNE
		Endlag = 0.12, -- TUNE short, and dash-cancelable, for the uppercut dash tech
		Stun = 0.9, -- TUNE
		LaunchHeight = 4, -- TUNE studs
		GuardBreak = true,
		WallTrigger = true,
		DashCancel = true, -- a front dash may cancel its endlag
		UsesBuff = true, -- Critical/Black Flash apply
		BlackFlashPercent = 0.24, -- TUNE
		CooldownHit = 1, -- TUNE
		CooldownMiss = 2, -- TUNE
	},
	-- Input: jump, then click while in the air (after the uppercut window, or any air click mid-combo).
	Downslam = {
		Percent = 0.06, -- TUNE
		Startup = 0.12, -- TUNE
		Active = 0.1, -- TUNE
		Endlag = 0.25, -- TUNE
		Stun = 0.5, -- TUNE only matters if the ragdoll is blocked
		Launch = -60, -- TUNE studs/s downward
		Ragdoll = true,
		RagdollDuration = 1.5, -- TUNE
		M1Lockout = 0.8, -- TUNE your M1 is locked this long after a downslam
		-- bigger than the M1 box and reaching further down, since you swing from the air
		Hitbox = { Size = Vector3.new(7, 10, 7), Offset = Vector3.new(0, -2.5, -3) }, -- TUNE (M1 box is 5x5x5)
		WallTrigger = true,
		Shockwave = true,
		UsesBuff = true,
		BlackFlashPercent = 0.24, -- TUNE
		Cooldown = 3, -- TUNE
		TrueDownslam = true, -- toggle: a downslam after TrueAfterHits combo hits can't be ragdoll-cancelled
		TrueAfterHits = 2, -- TUNE e.g. M1, M1, jump, slam
		UpsideDownTech = true, -- toggle: ignores stun immunity right after the target gets up
		UpsideDownWindow = 0.15, -- TUNE
	},
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
	ShockwaveShakeRange = 40, -- TUNE studs: players this close to a downslam feel the camera shake
}

-- "rbxassetid://123..." ids owned by you or your group. Empty or failing ids use the code-driven fallback
-- (PoseFallback). Add a keyframe marker named "Hit" to attack animations to time the hitbox.
Config.Animations = {
	M1_1 = "", -- Replace with your own uploaded animation ID
	M1_2 = "", -- Replace with your own uploaded animation ID
	M1_3 = "", -- Replace with your own uploaded animation ID
	M1_4 = "", -- Replace with your own uploaded animation ID
	DashFront = "", -- Replace with your own uploaded animation ID
	DashBack = "", -- Replace with your own uploaded animation ID
	DashLeft = "", -- Replace with your own uploaded animation ID
	DashRight = "", -- Replace with your own uploaded animation ID
	DashJab = "", -- Replace with your own uploaded animation ID
	Uppercut = "", -- Replace with your own uploaded animation ID
	MiniUppercut = "", -- Replace with your own uploaded animation ID
	Downslam = "", -- Replace with your own uploaded animation ID
	BlockIdle = "", -- Replace with your own uploaded animation ID (looped while blocking)
	HitReaction = "", -- Replace with your own uploaded animation ID
	Stunned = "", -- Replace with your own uploaded animation ID (looped while stunned)
	Shove = "", -- Replace with your own uploaded animation ID
	NormalPunch = "", -- Replace with your own uploaded animation ID
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
	Uppercut = { RightArm = { 165, 15, 0 }, Torso = { 10, 30, 0 } }, -- TUNE raised arm
	MiniUppercut = { RightArm = { 130, 15, 0 }, Torso = { 5, 25, 0 } }, -- TUNE
	DashJab = { RightArm = { 95, 10, 0 }, Torso = { -15, 30, 0 } }, -- TUNE forward jab
	NormalPunch = { RightArm = { 95, 15, 0 }, Torso = { -10, 40, 0 } }, -- TUNE
	Downslam = { RightArm = { 60, 0, 0 }, LeftArm = { 60, 0, 0 }, Torso = { -35, 0, 0 } }, -- TUNE overhead slam, arms down
	Stunned = { Torso = { 15, 0, 8 }, RightArm = { 10, 0, 15 }, LeftArm = { 10, 0, -15 } }, -- TUNE slumped
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
for _, group in { Config.Skills, Config.Moves } do
	for name, move in group do
		move.Name = name
		move.Hitbox = move.Hitbox or Config.M1.Hitbox
	end
end

return Config
