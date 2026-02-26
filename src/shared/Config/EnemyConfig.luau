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
					WindupAnimId = "rbxassetid://95055599600378",
					MidairAnimId = "rbxassetid://126352869640651",
					LandAnimId = "rbxassetid://119288108301982",
					WindupDuration = 0.23, -- Short, fast anticipation
					WindupAnimSpeed = 1.0, -- Normal speed for this clip
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
					Cooldown = 12, -- 12 seconds cooldown between leaps
					Chance = 0.6, -- 60% chance to jump when in range (prevents immediate predictability)
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
            MossFrog - Mobile leaping melee enemy
            Design: Mid-tier nimble enemy, closes gaps with a quick frog-leap.
                    Has a fast lunge for in-range attacks and a shorter-range
                    LeapStrike for closing distance. More frequent than Brute's leap.
            Behavior: Chase, lunge when close, leap when mid-range
        ]]
		MossFrog = {
			Health = 50,
			WalkSpeed = 16, -- Nimble: faster than Brute, slightly slower than Minion

			Damage = 10,

			AggroRange = 65,
			AttackRange = 12, -- Trigger attack state from a comfortable swiping distance
			AttackCooldown = 3.0,
			AttackWindup = 0.4, -- Fallback (used if Attacks table is ignored)
			AttackDuration = 0.8,

			WalkAnimationId = "rbxassetid://81740985919020",
			WalkAnimationSpeed = 1.2, -- Slightly faster playback for a hopping feel

			FacingOffset = -90, -- Model forward is 90° clockwise from root CFrame forward

			-- Multi-attack system (no leap — BogCharge is the only gap-closer)
			Attacks = {
				{
					Name = "Lunge",
					AnimationId = "rbxassetid://122908788073537",
					Windup = 0.3, -- Damage applies mid-swing
					Duration = 0.58, -- Animation ends at 0.58s
					Damage = 10,
					ForwardDist = 6,
					HitRadius = 10,
					VFXType = "Kick",
					Weight = 2,
				},
				{
					Name = "Slap",
					AnimationId = "rbxassetid://88606163017226",
					Windup = 0.2,
					Duration = 0.47, -- 0.33s anim at 0.7x speed
					Damage = 8,
					ForwardDist = 2, -- Impact point close to body
					HitRadius = 14, -- Wide enough to match the visual slash arc
					VFXType = "Swing",
					Weight = 2,
					SpeedCurve = { { 0, 0.7 }, { 1, 0.7 } }, -- Constant 0.7x to feel less snappy
				},
				{
					Name = "Slam",
					AnimationId = "rbxassetid://71094192458776",
					Windup = 0.55, -- Impact lands near end of build-up
					Duration = 0.83, -- Full animation length
					Damage = 18,
					ForwardDist = 8, -- Further forward so impact lands where the frog is reaching
					HitRadius = 12,
					VFXType = "Slam",
					Weight = 1,
				},
				{
					-- BogCharge: uses the running animation and bursts straight at the player.
					-- Long cooldown + low chance keeps it a surprise, not a spam.
					Name = "BogCharge",
					Type = "Charge",
					Windup = 0.25, -- Brief crouch/pause before launching
					Duration = 0.75, -- How long the dash lasts
					ChargeSpeed = 58, -- Studs/sec during the dash
					Damage = 14,
					HitRadius = 9,
					VFXType = "Swing",
					Weight = 1,
					MinRange = 20, -- Only triggers from mid-to-far range
					MaxRange = 65,
					Cooldown = 16, -- Long cooldown — this should feel rare
					Chance = 0.3, -- 30% chance when eligible
				},
			},

			ChaseSpeedMultiplier = 1.0,
			StopDistanceFromTarget = 3,

			HitstunDuration = 0.35,
			KnockbackResistance = 0.1, -- Slight resistance: it's a chunky frog

			XPValue = 12,
			DropChance = 0.15,

			HealthBarOffset = Vector3.new(0, 5, 0),
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
		MinSpawnDistance = 100, -- Minimum distance from players to spawn (~30 studs before aggro range)
		MaxSpawnDistance = 140, -- Maximum distance (keeps ~40-stud spawn band)
		DespawnDistance = 150, -- Distance at which enemies despawn (increased to match chase range)
		RespawnDelay = 15, -- Seconds before spawn point can spawn again (was 10)
		FOVExclusionAngle = 50, -- Skip spawn points within ±50° of any player's look direction
		ActivationDelay = 1.5, -- Seconds new enemies stand frozen before AI activates
	},

	-- Attack token system: limits simultaneous attackers per player
	-- Prevents DPS stacking from large groups being instantly lethal.
	-- Enemies denied a token will circle the player until a slot opens.
	AttackTokens = {
		Normal = 2, -- Max simultaneous attackers per player in a standard fight
		Elite = 3, -- Rooms with elite enemies allow a bit more pressure
		BossRoom = 1, -- Boss fights: only 1 add attacks at a time
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

	-- =========================================================
	-- BOIDS SEPARATION
	-- Mathematical flocking repulsion. Prevents enemies from
	-- stacking into a single mesh without using physics collisions.
	-- See EnemyService.updateSeparation() for the implementation.
	-- =========================================================
	Separation = {
		Enabled = true,

		-- Enemies within this horizontal radius push each other away.
		-- Should be roughly the diameter of the enemy hitbox.
		Radius = 3.5,

		-- How hard they push (studs/sec equivalent at full overlap).
		-- Higher = tighter ring, but can cause jitter if too large.
		Strength = 6.0,

		-- Only 1/StaggerDivisor of all enemies are processed per frame.
		-- 4 = 25% of enemies updated per frame at 20Hz.
		-- Lower this number (e.g. 2) for snappier spreading at higher CPU cost.
		StaggerDivisor = 4,
	},
}
