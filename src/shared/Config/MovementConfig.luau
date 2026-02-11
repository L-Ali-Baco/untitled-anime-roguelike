--[[
    MovementConfig.luau
    All movement-related configuration values.
    Easy to tweak for balancing without touching code.
]]

return {
	-- Base movement
	WalkSpeed = 22, -- studs/sec (Base speed INCREASED significantly)
	Acceleration = 400, -- Near-instant acceleration (Removes sluggish start)
	Deceleration = 600, -- Near-instant stopping (Removes glide)
	AirControl = 0.3, -- Movement control while airborne (0-1)
	TurnSpeed = 30, -- Even faster turning

	-- Stamina system
	Stamina = {
		Max = 100,
		RegenRate = 25, -- per second
		RegenDelay = 0.5, -- seconds before regen starts after use
	},

	-- Dash (Phase 2 - values ready)
	Dash = {
		Distance = 25, -- studs (Base distance, scaled by speed now)
		Duration = 0.3, -- seconds (slightly longer for drag feel)
		StaminaCost = 40, -- Increased cost (was 15)
		IFrameDuration = 0.25, -- invincibility frames
		Cooldown = 0.2, -- minimum time between dashes
		AfterimageCount = 5, -- number of afterimages to spawn
		SpeedMultiplier = 4.0, -- Dash is 4x current walk speed
		Drag = 5, -- How fast it slows down (if using impulse)
	},

	-- Jump system
	Jump = {
		Force = 35, -- Lowered from 50 for more controlled jump
		AirJumpForce = 28, -- 80% of ground jump for better feel
		AirJumpsAllowed = 1, -- 0 = no double jump, 1 = double jump, 2 = triple, etc.
		CoyoteTime = 0.1, -- seconds you can still jump after leaving ground
		JumpBufferTime = 0.1, -- seconds to buffer jump input before landing
		-- VFX settings
		GroundDustEnabled = true,
		AirBurstEnabled = true,
		AirBurstColor = Color3.fromRGB(100, 200, 255), -- Cyan to match dash aesthetic
	},

	-- Ground detection
	Ground = {
		RaycastDistance = 3, -- studs below character to check for ground
		SlopeLimit = 45, -- max walkable slope in degrees
	},
}
