--[[
    EnemyLib.luau
    Shared utility functions for working with humanoid-free enemy entities.
    
    Enemies use attributes instead of Humanoid for health/state:
    - IsEnemy: boolean (identifies as enemy)
    - Health: number (current health)
    - MaxHealth: number (max health)
    - WalkSpeed: number (movement speed)
    - IsDead: boolean (death state)
    
    Works on both server and client.
]]

local CharacterLib = require(script.Parent.CharacterLib)

local EnemyLib = {}

--[[
    Check if a model is an enemy entity (attribute-based, no Humanoid).
    
    @param model The Model to check
    @return boolean True if it has the IsEnemy attribute
]]
function EnemyLib:IsEnemy(model: Model): boolean
	if not model then
		return false
	end
	return model:GetAttribute("IsEnemy") == true
end

--[[
    Check if an enemy is alive (Health > 0 and not marked dead).
    Also works for player characters (falls back to Humanoid).
    
    @param model The Model to check
    @return boolean True if alive
]]
function EnemyLib:IsAlive(model: Model): boolean
	if not model or not model.Parent then
		return false
	end

	-- Attribute-based enemies
	if model:GetAttribute("IsEnemy") then
		local health = model:GetAttribute("Health") or 0
		return health > 0 and not model:GetAttribute("IsDead")
	end

	-- Fallback: Humanoid-based (players, training dummies)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return humanoid ~= nil and humanoid.Health > 0
end

--[[
    Get the current health of an entity.
    Works for both attribute-based enemies and Humanoid-based characters.
    
    @param model The Model to query
    @return number Current health (0 if not found)
]]
function EnemyLib:GetHealth(model: Model): number
	if not model then
		return 0
	end

	if model:GetAttribute("IsEnemy") then
		local health: number = (model:GetAttribute("Health") :: number?) or 0
		return health
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return humanoid and humanoid.Health or 0
end

--[[
    Get the max health of an entity.
    
    @param model The Model to query
    @return number Max health (0 if not found)
]]
function EnemyLib:GetMaxHealth(model: Model): number
	if not model then
		return 0
	end

	if model:GetAttribute("IsEnemy") then
		local maxHealth: number = (model:GetAttribute("MaxHealth") :: number?) or 0
		return maxHealth
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	return humanoid and humanoid.MaxHealth or 0
end

--[[
    Get the root part of an entity.
    Delegates to CharacterLib for consistent behavior.
    
    @param model The Model to query
    @return BasePart? The root part, or nil
]]
function EnemyLib:GetRootPart(model: Model): BasePart?
	return CharacterLib:GetRootPart(model)
end

--[[
    Apply damage to an entity. Handles both enemies (attributes) and
    Humanoid-based characters.
    
    For enemies: reduces Health attribute, sets IsDead when <= 0.
    For players/dummies: delegates to Humanoid:TakeDamage().
    
    @param model The target Model
    @param amount Damage to apply (positive number)
    @return number The actual damage dealt (after clamping)
]]
function EnemyLib:TakeDamage(model: Model, amount: number): number
	if not model or amount <= 0 then
		return 0
	end

	if model:GetAttribute("IsEnemy") then
		local health = model:GetAttribute("Health") or 0
		if health <= 0 then
			return 0 -- Already dead
		end

		local newHealth = math.max(0, health - amount)
		local actualDamage = health - newHealth

		model:SetAttribute("Health", newHealth)

		if newHealth <= 0 then
			model:SetAttribute("IsDead", true)
		end

		return actualDamage
	end

	-- Fallback: Humanoid-based
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		local healthBefore = humanoid.Health
		humanoid:TakeDamage(amount)
		return healthBefore - humanoid.Health
	end

	return 0
end

--[[
    Directly set the health of an entity.
    
    @param model The target Model
    @param value New health value
]]
function EnemyLib:SetHealth(model: Model, value: number)
	if not model then
		return
	end

	if model:GetAttribute("IsEnemy") then
		local maxHealth = model:GetAttribute("MaxHealth") or value
		value = math.clamp(value, 0, maxHealth)
		model:SetAttribute("Health", value)

		if value <= 0 then
			model:SetAttribute("IsDead", true)
		end
		return
	end

	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		humanoid.Health = value
	end
end

--[[
    Initialize all enemy attributes on a model.
    Called during enemy spawning on the server.
    
    @param model The enemy Model
    @param health Starting health
    @param maxHealth Maximum health
    @param walkSpeed Movement speed
]]
function EnemyLib:SetupAttributes(model: Model, health: number, maxHealth: number, walkSpeed: number)
	model:SetAttribute("IsEnemy", true)
	model:SetAttribute("Health", health)
	model:SetAttribute("MaxHealth", maxHealth)
	model:SetAttribute("WalkSpeed", walkSpeed)
	model:SetAttribute("IsDead", false)
end

--[[
    Get the Animator from an entity.
    Enemies use AnimationController > Animator.
    Players use Humanoid > Animator.
    
    @param model The Model to query
    @return Animator? The Animator, or nil
]]
function EnemyLib:GetAnimator(model: Model): Animator?
	if not model then
		return nil
	end

	-- Try AnimationController first (enemies)
	local animController = model:FindFirstChildOfClass("AnimationController")
	if animController then
		return animController:FindFirstChildOfClass("Animator")
	end

	-- Fallback: Humanoid (players)
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		return humanoid:FindFirstChildOfClass("Animator")
	end

	return nil
end

return EnemyLib
