--[[
    ClassConfig.luau
    Defines all playable classes with their stats and attack data.
]]

return {
	-- Default class list (order matters for UI)
	ClassOrder = { "Vanguard", "Gunner" },

	-- Vanguard: Heavy melee fighter with custom character model
	Vanguard = {
		DisplayName = "Vanguard",
		Description = "Heavy armored fighter with devastating melee attacks",
		Icon = "rbxassetid://6031071053", -- Sword icon
		Color = Color3.fromRGB(255, 80, 80), -- Red

		AttackType = "Melee",
		BaseHealth = 120,
		MoveSpeedMultiplier = 1.15, -- Increased speed (was 0.95)
		
		-- Melee uses CombatConfig.Attacks (nil = use default)
		Attacks = nil,
		
		-- Range for enemy highlight (easier to configure than calculating from hitbox)
		HighlightRange = 15,
		
		-- Custom character model settings
		CustomModel = "VanguardRig", -- Model name in ReplicatedStorage
		RootPartName = "HumanoidRootPart", -- Name of the root part (instead of HumanoidRootPart)
		RunAnimationId = "rbxassetid://125097643282975", -- Custom run animation (Updated)
		IsCustomRig = true, -- Flag for special handling
		HipHeight = 3.2, -- Height above ground (Adjusted to 3.2 for perfect float)
		FacingOffset = 180, -- Rotate model 180 degrees to face forward correctly
	},

	-- Gunner: Ranged fighter with rapid-fire bullets
	Gunner = {
		DisplayName = "Gunner",
		Description = "Ranged fighter with rapid-fire auto-aim bullets",
		Icon = "rbxassetid://6031075929", -- Gun icon
		Color = Color3.fromRGB(80, 180, 255), -- Blue

		AttackType = "Ranged",
		BaseHealth = 80,
		MoveSpeedMultiplier = 1.1, -- Slightly faster
		
		-- Range for enemy highlight (matches Server/Targeting limits)
		HighlightRange = 40,

		-- Ranged attack config
		RangedAttack = {
			FireRate = 0.12, -- Time between shots (fast!)
			Damage = 8,
			Range = 40, -- Max targeting/hit range in studs (aligned with Server/Highlight)
			BulletSpeed = 300, -- Studs/sec (very fast, near-hitscan)
			Spread = 3, -- Degrees of random spread
			Knockback = 1, -- Small knockback per hit

			-- Burst fire (optional)
			BurstCount = 1, -- Shots per trigger (1 = single shot)
			BurstDelay = 0.05, -- Delay between burst shots

			-- Hitstop/feedback (lighter than melee)
			Hitstop = 0.01, -- Very brief
			ScreenShake = 0.1, -- Light shake

			-- VFX settings
			MuzzleFlashEnabled = true,
			MuzzleFlashColor = Color3.fromRGB(255, 200, 100),
			MuzzleFlashSize = 1.5,

			TracerEnabled = true,
			TracerColor = Color3.fromRGB(255, 220, 100),
			TracerWidth = 0.15,
			TracerLifetime = 0.08,

			HitSparkEnabled = true,
			HitSparkColor = Color3.fromRGB(255, 150, 50),
			HitSparkCount = 4,
		},
	},

	-- Server validation
	Server = {
		MaxRangedRange = 70, -- Anti-cheat max range
		MinRangedInterval = 0.08, -- Anti-cheat min fire rate
	},
}
