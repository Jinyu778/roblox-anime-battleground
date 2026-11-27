--!strict
-- Move definitions built from Config, and the one rule that turns a click into a move. The client uses it to
-- predict (animation, hitbox), the server to decide, so the two can't disagree.
local Config = require(script.Parent.Config)

local Moves = {}

export type Move = {
	Name: string,
	Damage: number?, -- HP
	Percent: number?, -- share of the target's MaxHealth
	Startup: number,
	Active: number,
	Endlag: number,
	Stun: number,
	Hitbox: { Size: Vector3, Offset: Vector3 },
	IsM1: boolean?,
	Index: number?, -- M1 combo position
	GuardBreak: boolean?,
	Knockback: number?, -- studs/s away from the attacker
	Launch: number?, -- studs/s upward; puts the target in Launched
	SlamVelocity: number?, -- studs/s downward
	RagdollTime: number?,
	UsesBuff: boolean?, -- Critical / Black Flash apply (M1s always do)
	WallTrigger: boolean?,
	Shockwave: boolean?,
	DashCancel: boolean?, -- a front dash may cancel it (uppercut dash tech)
}

local COMBO_LENGTH = #Config.M1.Damage
Moves.COMBO_LENGTH = COMBO_LENGTH

local m1s: { Move } = {}
for i, damage in Config.M1.Damage do
	local finisher = i == COMBO_LENGTH
	m1s[i] = {
		Name = "M1_" .. i,
		Damage = damage,
		Startup = Config.M1.Startup,
		Active = Config.M1.Active,
		Endlag = if finisher then Config.M1.FinisherEndlag else Config.M1.Endlag,
		Stun = if finisher then Config.M1.FinisherStun else Config.M1.HitStun,
		Hitbox = Config.M1.Hitbox,
		IsM1 = true,
		Index = i,
		GuardBreak = finisher,
		Knockback = if finisher then Config.M1.FinisherKnockback else nil,
		WallTrigger = finisher,
	}
end

function Moves.M1(index: number): Move
	return m1s[index]
end

Moves.Uppercut = {
	Name = "Uppercut",
	Percent = Config.Uppercut.DamagePercent,
	Startup = Config.Uppercut.Startup,
	Active = Config.Uppercut.Active,
	Endlag = Config.Uppercut.Endlag,
	Stun = Config.Uppercut.LaunchedStun,
	Hitbox = Config.M1.Hitbox,
	GuardBreak = true,
	Launch = Config.Uppercut.LaunchVelocity,
	WallTrigger = true,
} :: Move

Moves.MiniUppercut = {
	Name = "MiniUppercut",
	Percent = Config.Uppercut.Mini.DamagePercent,
	Startup = Config.Uppercut.Mini.Startup,
	Active = Config.Uppercut.Mini.Active,
	Endlag = Config.Uppercut.Mini.Endlag,
	Stun = Config.Uppercut.Mini.LaunchedStun,
	Hitbox = Config.M1.Hitbox,
	GuardBreak = true,
	Launch = Config.Uppercut.Mini.LaunchVelocity,
	UsesBuff = true,
	WallTrigger = true,
	DashCancel = true,
} :: Move

Moves.Downslam = {
	Name = "Downslam",
	Percent = Config.Downslam.DamagePercent,
	Startup = Config.Downslam.Startup,
	Active = Config.Downslam.Active,
	Endlag = Config.Downslam.Endlag,
	Stun = 0,
	Hitbox = Config.Downslam.Hitbox,
	SlamVelocity = Config.Downslam.SlamVelocity,
	RagdollTime = Config.Ragdoll.Duration,
	UsesBuff = true,
	WallTrigger = true,
	Shockwave = true,
} :: Move

function Moves.Total(move: Move): number
	return move.Startup + move.Active + move.Endlag
end

export type Context = {
	index: number, -- the next combo position (1-4)
	airborne: boolean,
	jumpHeld: boolean,
	sinceJump: number, -- seconds since this character last left the ground by jumping
	comboActive: boolean, -- an M1 string is in progress
	recentJab: boolean, -- a dash jab landed within its stun
	uppercutReady: boolean,
	downslamReady: boolean,
}

-- Jump then click quickly: uppercut (mini when extending a combo or a jab). 4th hit: downslam in the air,
-- uppercut on the ground with jump held. Anything else is the next M1.
function Moves.Choose(c: Context): Move
	if c.airborne and c.sinceJump <= Config.Uppercut.InputWindow and c.uppercutReady then
		return if c.comboActive or c.recentJab then Moves.MiniUppercut else Moves.Uppercut
	end
	if c.index == COMBO_LENGTH then
		if c.airborne and c.downslamReady then
			return Moves.Downslam
		elseif not c.airborne and c.jumpHeld and c.uppercutReady then
			return Moves.Uppercut
		end
	end
	return m1s[c.index]
end

do
	local function ctx(overrides: { [string]: any }): Context
		local c: { [string]: any } = {
			index = 1,
			airborne = false,
			jumpHeld = false,
			sinceJump = math.huge,
			comboActive = false,
			recentJab = false,
			uppercutReady = true,
			downslamReady = true,
		}
		for k, v in overrides do
			c[k] = v
		end
		return c :: any
	end
	assert(Moves.Choose(ctx({})).Name == "M1_1", "a plain click is the next M1")
	assert(Moves.Choose(ctx({ airborne = true, sinceJump = 0.1 })).Name == "Uppercut", "jump + quick click uppercuts")
	assert(Moves.Choose(ctx({ airborne = true, sinceJump = 0.1, comboActive = true })).Name == "MiniUppercut", "mid-combo it's the mini")
	assert(Moves.Choose(ctx({ airborne = true, sinceJump = 0.1, recentJab = true })).Name == "MiniUppercut", "after a jab it's the mini")
	assert(Moves.Choose(ctx({ index = 4, airborne = true, sinceJump = 0.5 })).Name == "Downslam", "airborne 4th hit downslams")
	assert(Moves.Choose(ctx({ index = 4, jumpHeld = true })).Name == "Uppercut", "4th hit with jump held uppercuts")
	assert(Moves.Choose(ctx({ index = 4 })).Name == "M1_4", "grounded 4th hit is the finisher")
	assert(Moves.Choose(ctx({ index = 3, airborne = true, sinceJump = 0.5 })).Name == "M1_3", "airborne 3rd hit is an M1")
	assert(Moves.Choose(ctx({ index = 4, airborne = true, sinceJump = 0.5, downslamReady = false })).Name == "M1_4", "downslam on cooldown falls back")
end

return Moves
