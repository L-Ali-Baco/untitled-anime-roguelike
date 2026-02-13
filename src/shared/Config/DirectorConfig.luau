--[[
    DirectorConfig.luau
    Configuration for the Director System ("The Storm").
    
    The Director scales difficulty over time, creating tension and escalation.
    Inspired by Risk of Rain 2's difficulty system.
]]

return {
	-- Update timing
	UpdateInterval = 1.0, -- How often to check for events (seconds)

	-- Difficulty scaling
	BaseDifficulty = 1.0, -- Starting difficulty multiplier
	DifficultyPerMinute = 0.1, -- +10% difficulty per minute of run time
	MaxDifficulty = 5.0, -- Cap difficulty at 5x

	-- Stat multipliers at MAX difficulty (lerped from 1.0 to these values)
	MaxHealthMultiplier = 3.0, -- Enemies have 3x HP at max difficulty
	MaxDamageMultiplier = 2.0, -- Enemies deal 2x damage at max difficulty
	MaxSpeedMultiplier = 1.3, -- Enemies move 30% faster at max difficulty

	-- Spawn rate scaling
	BaseSpawnInterval = 10.0, -- Seconds between enemy spawns at start
	MinSpawnInterval = 3.0, -- Fastest spawn rate at max difficulty
	SpawnCountBase = 1, -- Enemies per spawn at start
	SpawnCountMax = 3, -- Enemies per spawn at max difficulty

	-- Visual effects thresholds (difficulty level triggers)
	Visuals = {
		-- Sky darkening (ClockTime adjustments)
		SkyDarkeningEnabled = true,
		SkyStartDifficulty = 1.0, -- When sky starts darkening
		SkyMaxDarkDifficulty = 4.0, -- When sky is fully dark
		DayClockTime = 14.0, -- Noon-ish
		NightClockTime = 0.0, -- Midnight

		-- Fog
		FogEnabled = true,
		FogStartDifficulty = 1.5,
		FogMaxDifficulty = 4.0,
		FogColorStart = Color3.fromRGB(150, 150, 180),
		FogColorEnd = Color3.fromRGB(30, 20, 40),
		FogStartDistance = 500,
		FogEndDistanceMax = 100, -- Closer = denser fog
		FogEndDistanceMin = 300,

		-- Atmosphere
		AtmosphereEnabled = true,
		AtmosphereDensityMin = 0.2,
		AtmosphereDensityMax = 0.6,
		AtmosphereColorStart = Color3.fromRGB(200, 200, 220),
		AtmosphereColorEnd = Color3.fromRGB(80, 60, 100),

		-- Storm particles (optional, can be added later)
		StormParticlesEnabled = false,
	},

	-- Director Events
	-- These are random events that can occur based on difficulty and chance
	Events = {
		-- Elite enemy spawn (stronger single enemy)
		EliteSpawn = {
			Enabled = true,
			MinDifficulty = 1.5, -- Must reach this difficulty first
			ChancePerCheck = 0.05, -- 5% chance per update interval
			Cooldown = 30, -- Minimum seconds between elite spawns
			HealthMultiplier = 3.0, -- Elite has 3x normal HP
			DamageMultiplier = 1.5, -- Elite deals 1.5x damage
			SizeMultiplier = 1.3, -- Elite is 30% larger
			Color = Color3.fromRGB(255, 100, 255), -- Purple tint for elites
		},

		-- Horde wave (sudden burst of enemies)
		HordeWave = {
			Enabled = true,
			MinDifficulty = 2.0,
			ChancePerCheck = 0.02, -- 2% chance per check
			Cooldown = 60, -- Minimum seconds between hordes
			EnemyCount = 8, -- Base enemies in horde
			EnemyCountPerDifficulty = 2, -- Additional enemies per difficulty level
			SpawnRadius = 30, -- Spawn in circle around players
			AnnounceDuration = 3.0, -- Warning time before spawn
		},

		-- Treasure goblin (rare loot opportunity)
		TreasureGoblin = {
			Enabled = false, -- TODO: Implement treasure goblin enemy type
			MinDifficulty = 1.0,
			ChancePerCheck = 0.01, -- 1% chance
			Cooldown = 120, -- 2 minutes between goblins
			FleeTime = 15, -- Seconds before goblin escapes
		},

		-- Lightning strike (environmental hazard)
		LightningStrike = {
			Enabled = false, -- TODO: Implement lightning VFX and damage
			MinDifficulty = 3.0,
			ChancePerCheck = 0.03,
			Cooldown = 20,
			Damage = 25,
			WarningTime = 1.5,
		},
	},

	-- Difficulty tier names (for UI display)
	-- Displayed based on current difficulty level
	Tiers = {
		{ Name = "Drizzle", MinDifficulty = 1.0, Color = Color3.fromRGB(100, 200, 255) },
		{ Name = "Rainstorm", MinDifficulty = 1.5, Color = Color3.fromRGB(150, 200, 100) },
		{ Name = "Downpour", MinDifficulty = 2.0, Color = Color3.fromRGB(255, 220, 100) },
		{ Name = "Monsoon", MinDifficulty = 3.0, Color = Color3.fromRGB(255, 150, 50) },
		{ Name = "Typhoon", MinDifficulty = 4.0, Color = Color3.fromRGB(255, 80, 80) },
		{ Name = "CATACLYSM", MinDifficulty = 5.0, Color = Color3.fromRGB(200, 50, 255) },
	},

	-- Network
	Remotes = {
		DifficultyUpdate = "DirectorDifficultyUpdate", -- Broadcasts difficulty to clients
		EventTriggered = "DirectorEventTriggered", -- Broadcasts events to clients
		HordeWarning = "DirectorHordeWarning", -- Warns clients of incoming horde
	},
}
