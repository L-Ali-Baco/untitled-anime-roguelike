--[[
    CombatConfig.luau
    All combat-related tuning values.
    Includes combo data, hitstop, screen shake, and targeting.
]]

return {
	-- Combo system
	Combo = {
		MaxHits = 3, -- Number of hits in combo chain
		ResetTime = 0.5, -- Seconds of no attack before combo resets
		AutoAttackInterval = 0.35, -- Time between auto attacks when holding
		MovementSpeedMultiplier = 0.5, -- Movement speed during attacks (50%)
		CanDashCancel = true, -- Whether dash can cancel attacks
	},

	-- Attack data per combo hit
	-- Duration = total attack time, HitTime = when hitbox activates
	Attacks = {
		[1] = {
			Name = "Slash1",
			Damage = 10,
			Duration = 0.3, -- Total attack duration
			HitTime = 0.1, -- When hitbox becomes active
			HitDuration = 0.2, -- How long hitbox stays active (increased for visibility)
			HitboxSize = Vector3.new(12, 6, 14), -- Much larger hitbox
			HitboxOffset = Vector3.new(0, 0, 7), -- Further forward
			Hitstop = 0.03,
			ScreenShake = 0.3,
			Knockback = 5,
			AnimationId = nil, -- Use default R15 punch for now
		},
		[2] = {
			Name = "Slash2",
			Damage = 12,
			Duration = 0.3,
			HitTime = 0.1,
			HitDuration = 0.2,
			HitboxSize = Vector3.new(12, 6, 14), -- Much larger hitbox
			HitboxOffset = Vector3.new(0, 0, 7),
			Hitstop = 0.04,
			ScreenShake = 0.4,
			Knockback = 6,
			AnimationId = nil,
		},
		[3] = {
			Name = "Finisher",
			Damage = 20,
			Duration = 0.4, -- Slightly longer for finisher
			HitTime = 0.15,
			HitDuration = 0.25, -- Longer visibility for finisher
			HitboxSize = Vector3.new(14, 8, 18), -- Even larger hitbox for finisher
			HitboxOffset = Vector3.new(0, 0, 9),
			Hitstop = 0.1, -- Big hitstop for impact
			ScreenShake = 0.8, -- Heavy shake
			Knockback = 12,
			AnimationId = nil,
		},
	},

	-- Hitstop (freeze frame effect)
	Hitstop = {
		Enabled = true,
		FreezePlayer = true, -- Freeze attacker
		FreezeEnemies = true, -- Freeze hit targets
		MinDuration = 0.02, -- Minimum hitstop
		MaxDuration = 0.12, -- Maximum hitstop (capped)
		TimeScale = 0, -- 0 = full freeze, 0.1 = slow-mo
	},

	-- Screen shake
	ScreenShake = {
		Enabled = true,
		-- Intensity is multiplied by attack's ScreenShake value
		BaseIntensity = 1.0, -- Multiplier for all shakes
		MaxOffset = 1.5, -- Max camera offset in studs
		Frequency = 25, -- Shake frequency (higher = faster)
		DecayRate = 10, -- How fast shake dies down
	},

	-- Auto-targeting (soft lock)
	Targeting = {
		Enabled = true,
		MaxRange = 40, -- Maximum targeting range in studs (synced with Scrapper range)
		ConeAngle = 360, -- Degrees - 360 means target nearest regardless of direction
		SoftLockStrength = 1.0, -- How much attacks rotate toward target (1.0 = full lock)
		UpdateInterval = 0.05, -- How often to update target (faster)
		RequireLineOfSight = false, -- Whether target needs clear LOS
		TargetTag = "Enemy", -- CollectionService tag for enemies
	},

	-- Hitbox settings
	Hitbox = {
		DebugVisualize = true, -- Show hitbox in studio (disable for release)
		DebugColor = Color3.fromRGB(0, 255, 100), -- Bright green for visibility
		DebugTransparency = 0.3, -- More visible (less transparent)
		OverlapParams = {
			FilterType = Enum.RaycastFilterType.Include,
			-- FilterDescendantsInstances set at runtime to enemies
		},
	},

	-- VFX settings
	Effects = {
		SlashTrailEnabled = true,
		SlashTrailColor = Color3.fromRGB(255, 255, 255),
		SlashTrailLifetime = 0.15,

		HitSparkEnabled = true,
		HitSparkColor = Color3.fromRGB(255, 200, 100),
		HitSparkCount = 8,

		ImpactRingEnabled = true, -- For finisher (3rd hit)
		ImpactRingColor = Color3.fromRGB(255, 220, 150),
		ImpactRingSize = 6,
	},

	-- Damage Numbers (floating damage text)
	DamageNumbers = {
		Enabled = true,
		Duration = 0.8, -- How long the number stays visible
		RiseHeight = 3, -- How far it floats upward (studs)
		RandomOffsetX = 1.5, -- Random horizontal offset to prevent stacking

		-- Font settings
		BaseFontSize = 24, -- Base text size
		MaxFontSize = 48, -- Max size for big hits
		FontFace = Font.fromEnum(Enum.Font.GothamBold),

		-- Stroke (outline) for readability
		StrokeEnabled = true,
		StrokeColor = Color3.fromRGB(0, 0, 0),
		StrokeThickness = 2,

		-- Colors by damage type
		Colors = {
			Normal = Color3.fromRGB(255, 255, 255), -- White
			Critical = Color3.fromRGB(255, 215, 0), -- Gold
			Finisher = Color3.fromRGB(255, 140, 0), -- Orange
			Bleed = Color3.fromRGB(180, 0, 0), -- Dark red
			Fire = Color3.fromRGB(255, 100, 50), -- Orange-red
			Poison = Color3.fromRGB(50, 200, 50), -- Green
			Heal = Color3.fromRGB(100, 255, 100), -- Bright green (for future)
			Dodge = Color3.fromRGB(100, 200, 255), -- Cyan/light blue for dodges
		},

		-- Size multipliers by damage type
		SizeMultipliers = {
			Normal = 1.0,
			Critical = 1.4,
			Finisher = 1.3,
			Bleed = 0.8,
			Fire = 0.9,
			Poison = 0.8,
			Heal = 1.0,
			Dodge = 1.2, -- Slightly larger for visibility
		},
	},

	-- Server validation
	Server = {
		MaxAttackRange = 40, -- Max range for valid hit (anti-cheat, increased)
		MinAttackInterval = 0.05, -- Min time between attacks (rate limit, lowered for flamethrower)
		DamageMultiplier = 1.0, -- Global damage scaling
	},
}
