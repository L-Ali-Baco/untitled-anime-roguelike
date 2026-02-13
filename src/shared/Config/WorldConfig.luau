--[[
    WorldConfig.luau
    Configuration for world objectives like Beacons and environmental hazards.
]]

return {
	Beacon = {
		ChargeRadius = 25, -- Studs player must be within to charge
		ChargeTime = 60, -- Seconds to fully charge a beacon
		LoseProgressRate = 0.2, -- Speed at which progress is lost when no player is inside (multiplier)

		-- Spawning during charge
		SpawnIntervalDuringCharge = 5.0, -- Seconds between spawns while charging
		MaxEnemiesPerBeacon = 15, -- Cap on enemies spawned specifically by one beacon

		-- Visuals
		ActiveColor = Color3.fromRGB(80, 180, 255), -- Blue
		ChargingColor = Color3.fromRGB(255, 200, 50), -- Yellow
		CompletedColor = Color3.fromRGB(100, 255, 100), -- Green

		-- Tags
		Tag = "Beacon",
	},

	Storm = {
		BaseDifficulty = 1.0,
		DifficultyScalePerMinute = 0.1, -- Increases difficulty by 10% every minute
	},
}
