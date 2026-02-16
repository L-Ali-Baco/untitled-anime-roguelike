--[[
    EnemyConfig.luau
    Enemy type definitions and AI behavior parameters.
    Easy to tweak for balancing without touching code.
]]

return {
	-- AI update settings (server performance)
	AI = {
		UpdateRate = 0.05, -- Snappier updates (20 Hz)
		PathfindingEnabled = true, -- Use PathfindingService (disable for simple direct chase)
		PathRecalculateInterval = 0.5, -- How often to recalculate path
		MaxActiveEnemies = 50, -- Cap for performance
	},

	-- Aggro/targeting system
	Aggro = {
		DetectionRange = 80, -- Studs to detect player (increased for more aggressive enemies)
		ChaseRange = 120, -- Studs before giving up chase
		LoseAggroTime = 5, -- Seconds out of range before losing aggro
		MultiTargetEnabled = false, -- Whether enemies can switch targets
	},

	-- Enemy types
	Types = {
		--[[
            Minion - Basic fodder enemy
            Design: Swarm enemy, weak individually but spawns in groups
            Behavior: Chase player, simple melee attack
        ]]
		Minion = {
			-- Stats
			Health = 30,
			WalkSpeed = 14, -- Slower than player (18)
			Damage = 5,

			-- AI behavior
			AggroRange = 70, -- Detection range (aggressive swarm behavior)
			AttackRange = 4, -- Studs to start attacking
			AttackCooldown = 1.5, -- Seconds between attacks
			AttackWindup = 0.3, -- Seconds before damage applies
			AttackDuration = 0.6, -- Total attack animation time

			-- Movement
			ChaseSpeedMultiplier = 1.0, -- Speed multiplier when chasing
			StopDistanceFromTarget = 2.5, -- How close to get before stopping

			-- Stagger/Hitstun
			HitstunDuration = 0.3, -- Seconds stunned when hit
			KnockbackResistance = 0, -- 0 = full knockback, 1 = immune

			-- Rewards
			XPValue = 5,
			DropChance = 0.1, -- 10% chance to drop item

			-- Visual
			HealthBarOffset = Vector3.new(0, 3, 0), -- Above head
			NameDisplayed = false, -- Don't show name for fodder
		},

		--[[
            Brute - Tankier melee enemy
            Design: Slow but hits hard, more health
            Behavior: Chase player, heavy melee attack
        ]]
		Brute = {
			Health = 100,
			WalkSpeed = 6, -- Much slower (was 10)
			Damage = 15,

			AggroRange = 60, -- Detection range (heavy but aware)
			AttackRange = 24, -- Starts attacking as soon as player is near
			AttackCooldown = 2.0,
			AttackWindup = 0.57, -- Fallback windup
			AttackDuration = 1.0, -- Fallback duration

			-- Animation
			WalkAnimationId = "rbxassetid://71794393488663",
			WalkAnimationSpeed = 0.5,
			SlamAnimationId = "rbxassetid://119288108301982", -- Fallback for non-Attacks path

			-- Multi-attack system
			Attacks = {
				{
					Name = "Slam",
					AnimationId = "rbxassetid://119288108301982",
					Windup = 0.57,
					Duration = 1.0,
					Damage = 15,
					ForwardDist = 13,
					HitRadius = 22,
					VFXType = "Slam",
					Weight = 1,
				},
				{
					Name = "Swing",
					AnimationId = "rbxassetid://76517082093663",
					Windup = 0.35,
					Duration = 0.7,
					Damage = 12,
					ForwardDist = 8,
					HitRadius = 16,
					VFXType = "Swing",
					Weight = 1,
					SpeedCurve = { { 0, 0.4 }, { 0.3, 0.6 }, { 0.7, 1.0 }, { 1.0, 1.5 } },
				},
				{
					Name = "LeapSlam",
					Type = "Leap", -- Flag for special multi-phase handling
					WindupAnimId = "rbxassetid://135955258792126",
					MidairAnimId = "rbxassetid://126352869640651",
					LandAnimId = "rbxassetid://119288108301982",
					WindupDuration = 1.2, -- Slow, dramatic crouch
					WindupAnimSpeed = 0.4, -- Very slow animation at start
					LaunchDuration = 0.5, -- Rise straight up to peak
					FlightDuration = 0.6, -- Horizontal flight toward target
					FlightHeight = 40, -- Studs above ground at peak (big dramatic jump)
					LandDuration = 0.8, -- Recovery after landing
					Damage = 25, -- Big damage for landing
					HitRadius = 20, -- Landing slam AoE
					ForwardDist = 0, -- Damage centered on landing spot
					VFXType = "LeapSlam",
					Weight = 0.5, -- Less frequent than normal attacks
					MinRange = 30, -- Gap-closer: only when player is far (beyond melee)
					MaxRange = 60, -- Don't leap if too far
				},
			},

			ChaseSpeedMultiplier = 0.8,
			StopDistanceFromTarget = 8, -- Stop further away so he doesn't clip inside

			HitstunDuration = 0.1, -- Harder to stagger
			KnockbackResistance = 0.5, -- 50% knockback reduction

			XPValue = 20,
			DropChance = 0.25,

			HealthBarOffset = Vector3.new(0, 9, 0),
			NameDisplayed = true,
		},

		--[[
            Shooter - Ranged enemy
            Design: Stays at range, fires projectiles
            Behavior: Keep distance, shoot at player
        ]]
		Shooter = {
			Health = 20,
			WalkSpeed = 12,
			Damage = 8,

			AggroRange = 90, -- Longest range - ranged enemies spot you first
			AttackRange = 25, -- Fires from far away
			AttackCooldown = 2.0,
			AttackWindup = 0.4,
			AttackDuration = 0.5,

			-- Ranged-specific
			ProjectileSpeed = 50, -- Studs per second
			PreferredDistance = 20, -- Tries to stay this far from player
			FleeDistance = 8, -- If player gets this close, retreat

			ChaseSpeedMultiplier = 1.2, -- Faster when fleeing
			StopDistanceFromTarget = 18,

			HitstunDuration = 0.4, -- Easy to interrupt
			KnockbackResistance = 0,

			XPValue = 10,
			DropChance = 0.15,

			HealthBarOffset = Vector3.new(0, 3, 0),
			NameDisplayed = false,
		},
	},

	-- Spawn settings
	Spawn = {
		SpawnTag = "EnemySpawnPoint", -- CollectionService tag for spawn locations
		MinSpawnDistance = 25, -- Minimum distance from players to spawn
		MaxSpawnDistance = 70, -- Maximum distance (within aggro range)
		DespawnDistance = 150, -- Distance at which enemies despawn (increased to match chase range)
		RespawnDelay = 15, -- Seconds before spawn point can spawn again (was 10)
	},

	-- Death settings
	Death = {
		RagdollDuration = 0.5, -- Reduced: client dissolves in 0.3s, cleanup shortly after
		FadeOutDuration = 0.3, -- Match client dissolve duration
		DeathForce = 500, -- Impulse applied on death for ragdoll effect (unused now)
	},

	-- Difficulty scaling (for Director system later)
	Scaling = {
		HealthMultiplierPerMinute = 0.02, -- +2% health per minute
		DamageMultiplierPerMinute = 0.01, -- +1% damage per minute
		SpeedMultiplierPerMinute = 0.005, -- +0.5% speed per minute
		MaxMultiplier = 3.0, -- Cap at 3x stats
	},
}
