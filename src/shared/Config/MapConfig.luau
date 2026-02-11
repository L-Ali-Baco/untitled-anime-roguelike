--[[
    MapConfig.luau
    Configuration for the Map Loading System.
]]

return {
	-- Folder in ReplicatedStorage where map models are stored
	StorageFolder = "Maps",
	
	-- Available Maps
	Maps = {
		TestArena = {
			Name = "Training Grounds",
			Description = "A basic arena for combat testing.",
			Rarity = 1, -- Common
			MinDifficulty = 0,
		},
		SkyRuins = {
			Name = "Sky Ruins",
			Description = "Floating islands consumed by the storm.",
			Rarity = 1,
			MinDifficulty = 0,
		}
	},
	
	-- Tags used to identify special parts in the map
	Tags = {
		SpawnPoint = "EnemySpawn", -- Where enemies can spawn
		PlayerSpawn = "PlayerSpawn", -- Where players start
		ChestSpawn = "ChestLocation", -- Where chests MIGHT spawn
		Teleporter = "Teleporter", -- The exit
	}
}
