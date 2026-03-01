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
	MaxWireLength: number?,
	Radius: number?,
	Knockback: number?,
	KnockbackForce: number?,
	LungeForce: number?,
}

return {
	-- ==========================================
	-- VANGUARD (Warrior)
	-- ==========================================
	Vanguard = {
		-- M2: Low-cooldown ranged slash (great against flying enemies)
		Secondary = {
			Name = "Aerial Slash",
			Description = "Launch a crescent slash wave forward. Prioritizes elevated enemies.",
			Icon = "rbxassetid://6031097903", -- Sword icon
			Cooldown = 3, -- Low cooldown — spammable poke/anti-air
			AnimationId = "rbxassetid://101805537227722",
			HitTime = 0.38, -- Animation impact frame (L→R)
			Damage = 1.8, -- 180% base — poke tool; anti-air bonus makes it shine vs airborne
			Range = 65, -- Max distance the wave travels (studs)
			TravelSpeed = 90, -- Studs per second the wave moves forward
			HitboxSize = Vector3.new(14, 22, 12), -- Tall box — catches flying enemies; Z=12 ensures sweep overlap
			HitboxOffset = Vector3.new(-2, 4, 0), -- Elevated centre (aerial bias)
			Knockback = 22, -- Strong lateral knockback (sends them sideways)
			Hitstop = 0.06,
			ScreenShake = 0.5,
			-- Flying enemy bonus
			-- Threshold raised to 8: tall grounded enemies (Brutes) have their root at ~floor+7-9
			-- and were falsely triggering the 4× multiplier. 8 studs requires genuine airtime.
			FlyingHeightThreshold = 8, -- Studs above player Y = "flying"
			FlyingDamageMultiplier = 2.2, -- 2.2× vs airborne — rewarding, not a one-shot nuke
			VFXType = "AerialSlash", -- Key for AttackVFXConfig lookup
		},
		-- E: Pull — Iron Grip
		Skill1 = {
			Name = "Iron Grip",
			Description = "Extend iron chains and YANK all nearby enemies toward you.",
			Icon = "rbxassetid://6034509993",
			Cooldown = 12,
			AnimationId = "rbxassetid://111620876629826",
			HitTime = 0.45, -- Cast frame when chains release
			Damage = 0.6, -- 60% base — utility skill, not a nuke
			Range = 35, -- Radius (studs) around player to catch enemies
			PullForce = 70, -- Velocity applied toward player (studs/sec)
			PullUp = 8, -- Small upward pop so they arc in nicely
		},
		-- Passive: Shield regeneration
		Passive = {
			Name = "Battle Hardened",
			Description = "PASSIVE: Vanguard's iron will regenerates 2 Shield per second, up to 25% of Max Health. Shield absorbs damage before HP.",
			Icon = "rbxassetid://6031289529",
			Cooldown = 0,
			ShieldRegenRate = 2, -- Shield gained per second
			ShieldCapPercent = 0.25, -- Max shield = 25% of MaxHealth
		},
	},

	-- ==========================================
	-- SCRAPPER
	-- ==========================================
	Scrapper = {
		Dash = {
			Name = "Scavenger's Slide",
			Description = "A fast, low-profile slide that knocks back enemies on impact.",
			Icon = "rbxassetid://13580556557", -- Dash icon
			Cooldown = 3,
			Damage = 1.0,
			KnockbackForce = 40,
			LungeForce = 80,
		},
		Skill1 = {
			Name = "Trip-Wire Spool",
			Description = "TRAP: Spool a high-tension tripwire between two points. Enemies crossing trigger a shrapnel blast that snares them.",
			Icon = "rbxassetid://6031097903", -- Trap
			-- Cooldown starts when the SECOND anchor is placed (Phase 2 completion),
			-- not when the first anchor is set — so setup time is free.
			Cooldown = 10,
			Range = 80,
			MaxWireLength = 60, -- Doubled: lets players set longer ambush corridors
			MinWireLength = 4, -- Server-side guard: prevents zero-length wires
			Damage = 3.0, -- 300% base — trap skills need punch to justify setup cost
			Radius = 22, -- Wider blast catches crossing enemies at higher speeds
			Knockback = 100, -- Strong radial knockback adds knockback chaos
			SlowFactor = 0.3, -- Survivors move at 30% speed for SlowDuration seconds
			SlowDuration = 2.0, -- Snare window: enough for a follow-up combo
		},
		Passive = {
			Name = "Kinetic Scrubber",
			Description = "PASSIVE: Moving continuously builds Heat. At 100 Heat, your shots shred enemy armor.",
			Icon = "rbxassetid://13799059639", -- Generic mechanic icon
			Cooldown = 0,
		},
	},

	-- ==========================================
	-- BIKER KING (Fire Brawler)
	-- ==========================================
	BikerKing = {
		-- M2: Buff / Ramp Up
		Secondary = {
			Name = "Inferno Ramp",
			Description = "BUFF: Ramp up fire rate and ignite enemies on hit for 5 seconds.",
			Icon = "rbxassetid://6034287594", -- Placeholder: Lightning
			Cooldown = 10,
			Duration = 5,
			FireRateBuff = 1.5, -- 50% faster attacks
			BurnDamage = 0.3, -- 30% base damage per burn tick
			BurnDuration = 3, -- Burn lasts 3s
			BurnTickRate = 0.5, -- Tick every 0.5s
		},
		-- E: AOE Zone
		Skill1 = {
			Name = "Flame Circle",
			Description = "ZONE: Erupts a ring of fire around you, burning all nearby enemies.",
			Icon = "rbxassetid://6034509993", -- Placeholder: Impact
			Cooldown = 12,
			Damage = 1.5, -- 150% per tick
			Radius = 18,
			Duration = 3,
			TickRate = 0.5,
		},
		-- R: Mobility / Chain Stomp
		Skill2 = {
			Name = "Meteor Stomp",
			Description = "LEAP: Launch into the sky and slam down. Landing on enemies bounces you back up.",
			Icon = "rbxassetid://6031071053", -- Placeholder: Sword
			Cooldown = 14,
			Damage = 2.0, -- 200% per stomp
			Radius = 12,
			LaunchForce = 80,
			BounceForce = 60,
			MaxBounces = 5,
		},
	},
}
