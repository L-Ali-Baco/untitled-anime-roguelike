--[[
	Minion.luau
	Basic swarm fodder enemy. Inherits from BaseEnemy.

	Behavior: Chase → plain melee hit. No special attacks.
	The base OnAttackEnter() / state machine handles everything.
	Override only if Minion needs unique behavior in the future.
]]

local BaseEnemy = require(script.Parent.BaseEnemy)

local Minion = setmetatable({}, { __index = BaseEnemy })
Minion.__index = Minion

function Minion.new(model: Model, config: { [string]: any }, services: BaseEnemy.Services): any
	local self = BaseEnemy.new(model, config, "Minion", services)
	return setmetatable(self, Minion)
end

-- OnAttackEnter: inherited from BaseEnemy._doStandardAttack — no override needed.
-- OnChaseOverride: inherited (returns false) — base movement used.

return Minion
