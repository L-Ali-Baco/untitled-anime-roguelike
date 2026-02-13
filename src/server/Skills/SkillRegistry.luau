--[[
    SkillRegistry.luau
    Maps skill names to implementation functions.
]]

local VanguardSkills = require(script.Parent.VanguardSkills)
local GunslingerSkills = require(script.Parent.GunslingerSkills)
local BikerKingSkills = require(script.Parent.BikerKingSkills)

return {
	-- Vanguard
	["Iron Will"] = VanguardSkills.IronWill,
	["Seismic Slam"] = VanguardSkills.SeismicSlam,
	["Blade Storm"] = VanguardSkills.BladeStorm,

	-- Gunslinger
	["Buckshot Blast"] = GunslingerSkills.BuckshotBlast,
	["Tether Mine"] = GunslingerSkills.TetherMine,
	["Overclock"] = GunslingerSkills.Overclock,

	-- Biker King
	["Inferno Ramp"] = BikerKingSkills.InfernoRamp,
	["Flame Circle"] = BikerKingSkills.FlameCircle,
	["Meteor Stomp"] = BikerKingSkills.MeteorStomp,
}
