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
            BogShambler - Basic swarm fodder enemy (custom non-humanoid rig)
            Design: Slow, shambling undead. Weak individually but spawns in groups.
                    Non-humanoid rig: AnimationController + Motor6D skeleton.
            Behavior: Chase player, plain melee attack (base _doStandardAttack).

            STUDIO RIGGING GUIDE — how to make animations play on this rig:
            ─────────────────────────────────────────────────────────────────
            Roblox's Animator writes poses by updating Motor6D.Transform each frame.
            WeldConstraint / Weld instances are physics-only; the Animator cannot
            see or drive them. If your custom rig uses welds its limbs will not move.

            Step-by-step fix:
              1. In the Model hierarchy find every Weld / WeldConstraint between
                 the root (HumanoidRootPart / "Torso") and child limbs.
              2. Delete them.
              3. For each limb add a Motor6D in the PARENT part:
                    Motor6D.Part0 = parentPart
                    Motor6D.Part1 = childLimb
                    Motor6D.C0   = CFrame of the joint pivot in Part0 space
                    Motor6D.C1   = CFrame of the joint pivot in Part1 space
                    Motor6D.Name = e.g. "RightArm", "Head", etc.
              4. Set the root part as the PrimaryPart of the Model.
              5. Delete any Humanoid (BaseEnemy._setupAnimator does this at
                 runtime, but removing it in Studio keeps the viewport clean).
              6. Do NOT add an AnimationController in Studio — BaseEnemy creates
                 one at runtime with the correct Animator child.
              7. Export / save the model. The WalkAnimationId clip must be
                 authored against this Motor6D skeleton (use the Roblox Animation
                 Editor with the rig selected).

            Animation priorities used by BogShambler:
              • Walk   → Enum.AnimationPriority.Movement  (loop, auto play/stop)
              • Attack → Enum.AnimationPriority.Action    (played by _doStandardAttack)
            ─────────────────────────────────────────────────────────────────
        ]]
		BogShambler = {
			-- Spawn weighting (relative). Higher = spawns more often.
			-- Total active weight: BogShambler(60) + HexCaster(15) + MossFrog(15) + Brute(7) + Keg(3) = 100
			SpawnWeight = 60,

			-- Stats
			Health = 30,
			WalkSpeed = 10, -- Slower than Minion (14); shambling pace
			Damage = 8, -- Per headbutt hit

			-- AI behavior
			AggroRange = 70, -- Detection range (aggressive swarm behavior)
			AttackRange = 6, -- Studs to enter attack state (matches headbutt AoE radius)
			AttackCooldown = 3.0, -- Seconds between headbutts (windup + hitstop + recovery ≈ 1.6 s)
			AttackWindup = 0.3, -- Fallback only; headbutt uses HeadbuttWindup below
			AttackDuration = 1.6, -- Fallback only; headbutt manages its own timing

			-- Animation
			WalkAnimationId = "rbxassetid://73141572263954", -- Shambling walk cycle

			-- Headbutt attack
			-- BogShambler:OnAttackEnter overrides _doStandardAttack entirely.
			-- These values are read by _doHeadbuttAttack in BogShambler.luau.
			HeadbuttAnimId = "rbxassetid://86362610167476", -- Leaping headbutt clip
			HeadbuttWindup = 0.6, -- Seconds from clip start to the impact frame.
			--                       To go frame-perfect: add a KeyframeMarker named
			--                       "Impact" to the clip in the Animation Editor and
			--                       swap task.wait(windup) for GetMarkerReachedSignal.
			HeadbuttHitstop = 0.5, -- Seconds the animation freezes at impact (Speed = 0).
			HeadbuttRecovery = 0.5, -- Seconds of recovery animation after the freeze.
			HeadbuttDamage = 12, -- Flat damage dealt on impact.
			HeadbuttRadius = 6, -- AoE hit radius (studs), centered 3 studs in front of HRP.
			HeadbuttKnockback = 18, -- Impulse magnitude away from the shambler.

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
			-- Rare heavy. High XP/loot reward justifies the danger.
			SpawnWeight = 7,

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
			-- Mid-tier. Equal weight to Shooter for balanced ranged/melee mix.
			SpawnWeight = 15,

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
            HexCaster - Airborne ranged caster
            Design: Hovers HOVER_HEIGHT studs off the ground. No Humanoid — uses
                    AnimationController/Animator. Orbits the player at PreferredDistance
                    and fires a hex bolt projectile. Forces the player to use vertical
                    AoE or long-range abilities; cannot be kited on the ground.
            Behavior: Hover → orbit player at range → fire hex bolt → repeat.
                      Retreats when player closes inside FleeDistance.
            NOTE: Requires Enemies/HexCaster.luau + entry in EnemyService ENEMY_CLASS_LOADERS.
        ]]
		HexCaster = {
			-- Same weight as the Shooter it replaces.
			-- Total active weight: BogShambler(60) + HexCaster(15) + MossFrog(15) + Brute(7) + Keg(3) = 100
			SpawnWeight = 15,

			Health = 35, -- Squishier than Shooter: it keeps itself at range, so it needs less buffer
			WalkSpeed = 11, -- Slow lateral drift — it's a caster, not a runner
			Damage = 12, -- Slightly higher than Shooter: each bolt is deliberate

			AggroRange = 120, -- Spots players from very far — ranged enemies should engage early
			AttackRange = 50, -- Opens fire from long range; forces player to use gap-closers
			AttackCooldown = 2.8, -- Deliberate casting pace
			AttackWindup = 0.3, -- Bolt fires ~60% through the 0.48 s cast clip
			AttackDuration = 0.55, -- Slightly longer than 0.48 s so animation fully completes

			-- Ranged-specific
			ProjectileSpeed = 45, -- Studs per second; slightly slower than a gun bolt, more magical
			PreferredDistance = 38, -- Orbits ~38 studs away; well inside AttackRange
			FleeDistance = 20, -- Retreats if player closes to this range

			-- Animation IDs
			-- IdleAnimationId: hardcoded in HexCaster.luau (rbxassetid://105855271459399)
			CastAnimationId = "rbxassetid://128236108325891", -- standard wand cast, 0.48 s
			HeavyBeamAnimId = "rbxassetid://76748423824936", -- channel wind-up, 0.88 s

			-- Hex-Beam heavy attack
			HeavyAttackCooldown = 10, -- seconds between Hex-Beam uses
			HeavyAttackDamage = 30, -- burst damage on beam contact
			HeavyBeamLength = 60, -- studs forward from HRP
			HeavyBeamWidth = 5, -- full width/height of the linear hitbox

			ChaseSpeedMultiplier = 1.0,
			StopDistanceFromTarget = 0, -- Orbit logic in OnChaseOverride handles stopping

			HitstunDuration = 0.45, -- Easy to interrupt mid-cast
			KnockbackResistance = 0, -- Airborne — knockback sends it flying

			XPValue = 12,
			DropChance = 0.15,

			HealthBarOffset = Vector3.new(0, 9, 0), -- Higher: floats well above ground
			NameDisplayed = true,
		},

		--[[
            Keg (Rolling Bomber)
            Design: Disposable suicide runner. Forces the player to react with a dash.
            AI logic (implement in Enemies/Keg.luau):
              1. State machine: Chase → Arming → Explode (no melee attack state at all).
              2. Chase at high speed until within ArmRange studs of any player.
              3. Enter Arming: freeze movement, play a rapid flash VFX + audio for ArmDuration seconds.
              4. Explode: AoE damage within ExplosionRadius. Kill self unconditionally.
              5. If the player dashes out of ExplosionRadius during Arming, the bomb still explodes
                 (punishes reactive players who are too slow, rewards those who pre-dash).
              SpawnWeight is live. Requires Enemies/Keg.luau + entry in EnemyService ENEMY_CLASS_LOADERS.
        ]]
		Keg = {
			SpawnWeight = 3, -- Rare treat, not common fodder

			Health = 15, -- Glass cannon — one or two hits should kill it before it arms
			WalkSpeed = 28, -- Faster than the player; closing the gap is its only job
			Damage = 0, -- No melee. All damage comes from the explosion.

			AggroRange = 80,
			AttackRange = 0, -- Unused; replaced by ArmRange below
			AttackCooldown = 0, -- Unused
			AttackWindup = 0, -- Unused
			AttackDuration = 0, -- Unused

			-- Keg-specific
			ArmRange = 5, -- Studs from target before it starts the countdown
			ArmDuration = 1.2, -- Seconds of flashing before detonation (dash window)
			ExplosionRadius = 12, -- AoE blast radius on detonation
			ExplosionDamage = 40, -- High burst to punish players who ignore it
			ExplosionVFXType = "Explosion",

			ChaseSpeedMultiplier = 1.0,
			StopDistanceFromTarget = 0, -- Runs INTO the player

			HitstunDuration = 0.15, -- Can be briefly interrupted but will still explode
			KnockbackResistance = 0,

			XPValue = 8,
			DropChance = 0.05, -- Barely worth looting — the threat IS the reward

			HealthBarOffset = Vector3.new(0, 3, 0),
			NameDisplayed = false,
		},

		--[[
            Drone (Flying Harasser) — PLACEHOLDER (no AI class yet)
            Design: Aerial threat that forces vertical awareness and target prioritisation.
            AI logic (implement in Enemies/Drone.luau):
              1. Ignore ground pathfinding entirely. Move directly via CFrame translation.
              2. Maintain HoverHeight studs above the nearest ground surface below the target.
              3. Keep PreferredDistance horizontally; strafe in a slow arc around the player.
              4. Fire a fast, weak projectile at the player every FireCooldown seconds.
              5. Cannot be hit by ground-level AoE that doesn't have height reach (design note for VFX team).
              6. Low KnockbackResistance: a single upward hit should visibly stagger it.
              SpawnWeight = 0 until implementation is complete.
        ]]
		Drone = {
			SpawnWeight = 0, -- Disabled until Enemies/Drone.luau is written

			Health = 25,
			WalkSpeed = 14, -- Lateral hover speed
			Damage = 6, -- Per projectile — low individual damage, high sustained fire

			AggroRange = 95, -- Spots players from very far (elevated vantage)
			AttackRange = 35, -- Opens fire from a comfortable hovering distance
			AttackCooldown = 0, -- Unused; replaced by FireCooldown below
			AttackWindup = 0.2,
			AttackDuration = 0.3,

			-- Drone-specific
			HoverHeight = 18, -- Studs above the ground surface beneath the target
			PreferredDistance = 25, -- Horizontal distance to maintain while strafing
			FireCooldown = 1.5, -- Seconds between projectile bursts
			ProjectileSpeed = 65, -- Fast bolts to punish slow reaction
			ProjectileDamage = 6,
			StrafeSpeed = 5, -- Studs/sec of lateral arc movement

			ChaseSpeedMultiplier = 1.1,
			StopDistanceFromTarget = 20,

			HitstunDuration = 0.5, -- Easily interrupted mid-fire
			KnockbackResistance = 0,

			XPValue = 12,
			DropChance = 0.15,

			HealthBarOffset = Vector3.new(0, 4, 0),
			NameDisplayed = false,
		},

		--[[
            Shaman (Backline Buffer) — PLACEHOLDER (no AI class yet)
            Design: High-priority assassination target. It doesn't fight the player;
                    it makes every other enemy around it dangerous.
            AI logic (implement in Enemies/Shaman.luau):
              1. Does NOT target players. Instead, targets the centroid of nearby allies.
              2. Pathfinds to stay behind the ally cluster (MaxDistFromAllies from centroid).
              3. Every AuraCooldown seconds, choose one of two buffs at random:
                 a) HealAura: heals all enemies within AuraRadius for HealAmount HP.
                 b) SpeedAura: grants a 1.5x speed boost to allies within AuraRadius for AuraDuration.
              4. Never initiates combat. Attempts to flee if a player enters FleeRange.
              5. Visual cue: a persistent glow ring beneath it so players can identify it in a horde.
              SpawnWeight = 0 until implementation is complete.
        ]]
		Shaman = {
			SpawnWeight = 0, -- Disabled until Enemies/Shaman.luau is written

			Health = 45, -- Squishy for a support — should die in 2-3 focused hits
			WalkSpeed = 8, -- Slow backline mover
			Damage = 0, -- Never attacks the player directly

			AggroRange = 0, -- Shaman does not chase players
			AttackRange = 0, -- Unused
			AttackCooldown = 0, -- Unused
			AttackWindup = 0, -- Unused
			AttackDuration = 0, -- Unused

			-- Shaman-specific
			AuraRadius = 18, -- Studs; allies within this receive buffs
			AuraCooldown = 8, -- Seconds between buff casts
			HealAmount = 15, -- HP restored per heal pulse
			BuffDuration = 4, -- Seconds the speed aura lasts
			SpeedBuffMultiplier = 1.5, -- Allies move 50% faster during aura
			MaxDistFromAllies = 20, -- Tries to stay within this range of ally centroid
			FleeRange = 12, -- If a player gets this close, Shaman tries to reposition

			ChaseSpeedMultiplier = 0, -- Never chases
			StopDistanceFromTarget = 99, -- Effectively never stops to fight

			HitstunDuration = 0.6, -- Soft target — easy to interrupt mid-cast
			KnockbackResistance = 0,

			XPValue = 25, -- High reward for the effort of assassinating it
			DropChance = 0.30, -- Reliable drop to reward target prioritisation

			HealthBarOffset = Vector3.new(0, 6, 0),
			NameDisplayed = true, -- Always shown so players know to prioritise it
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
