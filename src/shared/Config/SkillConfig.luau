--[[
    SkillConfig.luau
    Definitions for character skills/abilities.
]]

export type SkillDef = {
	Name: string,
	Description: string,
	Icon: string,
	Cooldown: number, -- Seconds
	Damage: number?, -- % of Base Damage (multiplier)
	Duration: number?, -- For buffs/spins
	Range: number?, -- Studs
	StaminaCost: number?,
	AnimationId: string?,
}

return {
	-- ==========================================
	-- VANGUARD (Warrior)
	-- ==========================================
	Vanguard = {
		-- M2: Defensive / Utility
		Secondary = {
			Name = "Iron Will",
			Description = "Gain a temporary Barrier for 30% Max HP. Taking damage grants a damage buff.",
			Icon = "rbxassetid://6031289529", -- Placeholder: Shield
			Cooldown = 8,
			Duration = 5,
			ShieldPercent = 0.3, -- 30% Max HP
			DamageBuff = 0.2, -- +20% Damage on hit
		},
		-- E: Crowd Control
		Skill1 = {
			Name = "Seismic Slam",
			Description = "Leap and slam the ground, knocking enemies UP.",
			Icon = "rbxassetid://6034509993", -- Placeholder: Impact
			Cooldown = 12,
			Damage = 2.5, -- 250% Damage
			Radius = 15,
			KnockupForce = 60,
		},
		-- R: Ultimate / Burst
		Skill2 = {
			Name = "Blade Storm",
			Description = "Unleash a flurry of rapid slashes in front of you.",
			Icon = "rbxassetid://6031097903", -- Placeholder: Sword
			Cooldown = 15,
			Damage = 0.8, -- Per hit (hits multiple times)
			HitCount = 6, -- Hits 6 times
			Duration = 1.5,
		},
	},

	-- ==========================================
	-- GUNSLINGER (Ranged)
	-- ==========================================
	Gunslinger = {
		-- M2: Burst Damage
		Secondary = {
			Name = "Buckshot Blast",
			Description = "SHOTGUN: Fires 5 bullets at once. Massive damage up close.",
			Icon = "rbxassetid://6031071053", -- Placeholder: Shotgun
			Cooldown = 6,
			Damage = 0.6, -- Per bullet (5x = 300% total if all hit)
			BulletCount = 5,
			Spread = 25, -- Degrees
		},
		-- E: Utility / CC
		Skill1 = {
			Name = "Tether Mine",
			Description = "TRAP: Throws a mine. After 1s, it PULLS all enemies into a group.",
			Icon = "rbxassetid://6031097903", -- Placeholder: Trap
			Cooldown = 14,
			Damage = 1.0,
			Radius = 25,
			PullForce = 50,
		},
		-- R: Ultimate
		Skill2 = {
			Name = "Overclock",
			Description = "BUFF: +50% Fire Rate and Infinite Ammo for 6 seconds.",
			Icon = "rbxassetid://6034287594", -- Placeholder: Lightning
			Cooldown = 25,
			Duration = 6,
			FireRateBuff = 1.5,
		},
	},
}
