--[[
    SkillRegistry.luau
    Maps skill names to implementation functions.
]]

local VanguardSkills = require(script.Parent.VanguardSkills)
local BikerKingSkills = require(script.Parent.BikerKingSkills)
local ScrapperSkills = require(script.Parent.ScrapperSkills)

return {
	-- Vanguard
	["Iron Will"] = VanguardSkills.IronWill,
	["Seismic Slam"] = VanguardSkills.SeismicSlam,
	["Blade Storm"] = VanguardSkills.BladeStorm,

	-- Biker King
	["Inferno Ramp"] = BikerKingSkills.InfernoRamp,
	["Flame Circle"] = BikerKingSkills.FlameCircle,
	["Meteor Stomp"] = BikerKingSkills.MeteorStomp,

	-- Scrapper
	["Trip-Wire Spool"] = ScrapperSkills.TripWireSpool,
}
