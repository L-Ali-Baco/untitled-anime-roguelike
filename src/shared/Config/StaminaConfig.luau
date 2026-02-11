--[[
    StaminaConfig.luau
    Stamina system configuration.
    Separated for easy balancing of stamina-based abilities.
]]

return {
	-- Base stamina
	Max = 100,
	RegenRate = 25, -- per second when not on cooldown
	RegenDelay = 0.5, -- seconds after stamina use before regen starts

	-- Action costs
	Costs = {
		Dash = 30,
		Jump = 0, -- jumping is free
		AirJump = 15, -- if double jump is enabled
		Sprint = 10, -- per second if sprinting is added
	},

	-- UI thresholds
	LowStaminaThreshold = 0.25, -- show warning when below 25%
	ExhaustedThreshold = 0, -- can't perform actions when at 0
}
