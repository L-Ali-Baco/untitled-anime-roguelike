--[[
    CharacterTypes.luau
    Type definitions for characters.
]]

local CharacterState = require(script.Parent.Parent.Enums.CharacterState)

export type CharacterStats = {
	health: number,
	maxHealth: number,
	stamina: number,
	maxStamina: number,
	walkSpeed: number,
	damage: number,
	defense: number,
}

export type CharacterData = {
	id: string,
	name: string,
	archetype: "Vanguard" | "Scrapper",
	baseStats: CharacterStats,
}

export type RuntimeCharacter = {
	data: CharacterData,
	currentStats: CharacterStats,
	state: string, -- CharacterState enum value
	velocity: Vector3,
	isGrounded: boolean,
	lastGroundedTime: number,
	lastStaminaUseTime: number,
}

return {}
