--[[
    CharacterLib.luau
    Utility functions for working with character models.
    Supports both standard Roblox rigs and custom rigs.
]]

local CharacterLib = {}

-- Common root part names in order of priority
local ROOT_PART_NAMES = { "HumanoidRootPart", "Root", "LowerTorso", "Torso", "UpperTorso" }

--[[
    Find the root part of a character model.
    Supports standard Roblox rigs (HumanoidRootPart) and custom rigs (Root, etc.)
    
    @param model The character Model to search
    @return BasePart? The root part, or nil if not found
]]
function CharacterLib:GetRootPart(model: Model): BasePart?
	if not model then
		return nil
	end

	-- Try common root part names
	for _, name in ROOT_PART_NAMES do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			return part
		end
	end

	-- Fallback: try PrimaryPart
	if model.PrimaryPart then
		return model.PrimaryPart
	end

	-- Last resort: find any anchored or main part
	return model:FindFirstChildOfClass("BasePart")
end

--[[
    Check if a model is a custom rig (has IsCustomRig attribute)
    
    @param model The character Model to check
    @return boolean True if it's a custom rig
]]
function CharacterLib:IsCustomRig(model: Model): boolean
	if not model then
		return false
	end
	return model:GetAttribute("IsCustomRig") == true
end

--[[
    Get the Humanoid from a character model
    
    @param model The character Model
    @return Humanoid? The Humanoid, or nil if not found
]]
function CharacterLib:GetHumanoid(model: Model): Humanoid?
	if not model then
		return nil
	end
	return model:FindFirstChildOfClass("Humanoid")
end

--[[
    Check if a character is alive.
    Supports attribute-based enemies (IsEnemy + Health attribute)
    and Humanoid-based characters (players).
    
    @param model The character Model
    @return boolean True if alive
]]
function CharacterLib:IsAlive(model: Model): boolean
	if not model or not model.Parent then
		return false
	end

	-- Attribute-based enemies (no Humanoid)
	if model:GetAttribute("IsEnemy") then
		local health = model:GetAttribute("Health") or 0
		return health > 0 and not model:GetAttribute("IsDead")
	end

	-- Humanoid-based (players)
	local humanoid = CharacterLib:GetHumanoid(model)
	return humanoid ~= nil and humanoid.Health > 0
end

return CharacterLib
