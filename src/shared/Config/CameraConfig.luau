--[[
    CameraConfig.luau
    All camera-related configuration values.
]]

return {
	-- Base positioning
	Distance = 15, -- studs behind player
	Height = 8, -- studs above player
	FieldOfView = 70,

	-- Offset from character (right/up from center)
	Offset = Vector3.new(2, 0, 0), -- Slight right offset for over-shoulder feel

	-- Smoothing (lower = snappier, higher = smoother)
	-- Higher values = smoother camera, less jitter
	PositionSmoothing = 0.35, -- Increased for smoother follow
	RotationSmoothing = 0.15,

	-- Pitch limits (looking up/down)
	MinPitch = -60, -- degrees (looking up)
	MaxPitch = 60, -- degrees (looking down)

	-- Mobile settings
	Mobile = {
		Sensitivity = 3.0, -- High sensitivity for responsive mobile camera
		InvertY = false,
		-- Touch zone for camera rotation (right side of screen)
		TouchZone = {
			StartX = 0.5, -- 50% from left (right half of screen)
			StartY = 0, -- top
			EndX = 1, -- 100% (right edge)
			EndY = 1, -- bottom
		},
	},

	-- PC settings
	PC = {
		Sensitivity = 0.5,
		InvertY = false,
	},

	-- Gamepad settings
	Gamepad = {
		Sensitivity = 2,
		InvertY = false,
		DeadZone = 0.1,
	},

	-- Combat adjustments (from GDD - Smart-Snap)
	Combat = {
		SmartSnapEnabled = true,
		AirComboPitchUp = 15, -- degrees to pitch up during air combos
		LockOnDistance = 50, -- max distance for soft-lock targeting
		LockOnSmoothing = 0.2, -- how smoothly camera follows target
	},

	-- Screen shake settings (for HitstopController later)
	Shake = {
		DefaultIntensity = 0.5,
		DefaultDuration = 0.1,
		MaxOffset = 1, -- studs
	},
}
