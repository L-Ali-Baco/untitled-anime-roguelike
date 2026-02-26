--[[
    CombatConfig.luau
    All combat-related tuning values.
    Includes combo data, hitstop, screen shake, and targeting.
]]

return {
	-- Combo system
	Combo = {
		MaxHits = 3,
		ResetTime = 2.5, -- Seconds of inactivity before combo resets (was 0.5 — too short, cut off hit 3)
		AutoAttackInterval = 0.35,
		MovementSpeedMultiplier = 0.5, -- Movement speed during attacks (50%)
		CanDashCancel = true, -- Whether dash can cancel attacks
	},

	-- Attack data per combo hit
	-- Duration = how long this hit phase lasts before the next can start
	-- AbsoluteHitTime = timestamp (seconds from animation start) when the hitbox should fire.
	--   This is used by performAttack when a single animation spans the full combo.
	--   Hit 1 starts the animation; hits 2+3 inherit the same running track.
	-- AnimationId on [1] is the shared combo animation — [2] and [3] intentionally nil.
	Attacks = {
		[1] = {
			Name = "Swing1",
			Damage = 18, -- Solid opener for a slow, heavy character
			AnimationId = "rbxassetid://119554236821479", -- Full 3-hit combo (fixed stretch)
			Duration = 0.65,
			HitTime = 0.29,
			AbsoluteHitTime = 0.29,
			HitDuration = 0.15,
			-- Swing 1: left-to-right slash — bias hitbox slightly left
			HitboxSize = Vector3.new(10, 5, 12),
			HitboxOffset = Vector3.new(-1.5, 0, 6),
			Hitstop = 0.03,
			ScreenShake = 0.25,
			Knockback = 5,
		},
		[2] = {
			Name = "Swing2",
			Damage = 28, -- Follow-through, builds momentum
			AnimationId = nil,
			Duration = 0.65,
			HitTime = 0.35,
			AbsoluteHitTime = 1.0,
			HitDuration = 0.15,
			-- Swing 2: right-to-left follow-through — wider arc, bias right
			HitboxSize = Vector3.new(13, 6, 14),
			HitboxOffset = Vector3.new(1.5, 0, 7),
			Hitstop = 0.05,
			ScreenShake = 0.45,
			Knockback = 7,
		},
		[3] = {
			Name = "Finisher",
			Damage = 48, -- Big finisher reward (~2.7× hit 1)
			AnimationId = nil,
			Duration = 0.60,
			HitTime = 0.09,
			AbsoluteHitTime = 1.39,
			HitDuration = 0.22,
			-- Finisher: wide powerful strike — biggest hitbox, slight upward for impact feel
			HitboxSize = Vector3.new(15, 8, 18),
			HitboxOffset = Vector3.new(0, 0.5, 9),
			Hitstop = 0.12,
			ScreenShake = 0.9,
			Knockback = 14,
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
