--[[
    SkillRegistry.luau
    Maps skill names to implementation functions.
]]

local VanguardSkills = require(script.Parent.VanguardSkills)
local BikerKingSkills = require(script.Parent.BikerKingSkills)
local ScrapperSkills = require(script.Parent.ScrapperSkills)

return {
	-- Vanguard
	["Aerial Slash"] = VanguardSkills.AerialSlash,
	["Iron Will"] = VanguardSkills.IronWill,
	["Iron Grip"] = VanguardSkills.IronGrip,
	-- (Blade Storm removed; Skill2 is now the Battle Hardened passive — no server handler needed)

	-- Biker King
	["Inferno Ramp"] = BikerKingSkills.InfernoRamp,
	["Flame Circle"] = BikerKingSkills.FlameCircle,
	["Meteor Stomp"] = BikerKingSkills.MeteorStomp,

	-- Scrapper
	["Trip-Wire Spool"] = ScrapperSkills.TripWireSpool,
}
