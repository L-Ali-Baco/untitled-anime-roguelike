--[[
    VFXPool.luau
    Centralized object pooling system for Visual Effects.

    Purpose:
    - Reuse heavy instances (Parts, Attachments, BillboardGuis) instead of Destroy()ing them.
    - Reduce Garbage Collection (GC) pressure.
    - Eliminate instantiation overhead during combat.
]]

local VFXPool = {}
VFXPool.Name = "VFXPool"

-- storage: { [templateName]: { Available: {Instance}, Template: Instance? } }
local pools = {}

-- Folder to store pooled objects (hidden from workspace)
local poolFolder = Instance.new("Folder")
poolFolder.Name = "VFXPoolStorage"
poolFolder.Parent = game:GetService("ReplicatedStorage") -- Store in RS to keep out of Workspace

--[[
    Get an object from the pool.
    @param templateName: The unique name of the pool/template.
    @param templateInstance: Optional template to clone if pool is empty (required on first use).
    @return Instance: A ready-to-use instance.
]]
function VFXPool:Get(templateName: string, templateInstance: Instance?): Instance
	local poolData = pools[templateName]

	-- Initialize pool if needed
	if not poolData then
		if not templateInstance then
			warn("[VFXPool] Warning: No template provided for new pool '" .. templateName .. "'")
			-- Return a dummy part as fallback to prevent errors
			local p = Instance.new("Part")
			p.Name = "Fallback_" .. templateName
			return p
		end

		poolData = {
			Available = {},
			Template = templateInstance:Clone() -- Store a clean copy
		}
		pools[templateName] = poolData
	end

	-- Try to get from available
	local object = table.remove(poolData.Available)
	if object then
		-- Reset basic properties
		if object:IsA("BasePart") then
			object.Anchored = true
			object.CanCollide = false
			object.CanQuery = false
			object.CanTouch = false
			object.CastShadow = false
			object.Transparency = 0
		elseif object:IsA("ParticleEmitter") then
			object.Enabled = false
		elseif object:IsA("PointLight") or object:IsA("SurfaceLight") or object:IsA("SpotLight") then
			object.Enabled = true
            object.Brightness = 1
		elseif object:IsA("BillboardGui") then
			object.Enabled = true
        elseif object:IsA("Highlight") then
            object.Enabled = true
            object.Adornee = nil
		end
		return object
	end

	-- Create new if empty
	local newObject = poolData.Template:Clone()
	newObject.Name = templateName -- Ensure name matches for debugging
	return newObject
end

--[[
    Return an object to the pool.
    @param object: The instance to return.
    @param templateName: The pool to return it to.
]]
function VFXPool:Return(object: Instance, templateName: string)
	if not object then return end

    -- Safety check: ensure object is not destroyed
    if not object.Parent and object.Parent ~= nil then
        -- Parent is nil, but check if it's locked (Destroyed)
        -- In Luau, we can't easily check 'IsDestroyed' without pcall access to properties usually
        -- But for now, just assume valid if passed here.
    end

	local poolData = pools[templateName]
	if not poolData then
		-- If pool doesn't exist, just destroy it (shouldn't happen often)
		object:Destroy()
		return
	end

	-- Reset and hide
	object.Parent = nil

    -- Clear specific properties
    if object:IsA("ParticleEmitter") then
        object:Clear()
        object.Enabled = false
    elseif object:IsA("Trail") then
        object:Clear()
        object.Enabled = false
    elseif object:IsA("BasePart") then
        object.AssemblyLinearVelocity = Vector3.zero
        object.AssemblyAngularVelocity = Vector3.zero
    elseif object:IsA("Highlight") then
        object.Adornee = nil
        object.Enabled = false
    end

    -- Cleanup children if it's a container (like a Part with Attachments)
    -- OPTIONAL: For deep cleaning, but usually we want to keep structure.
    -- We assume the consumer handles resetting children if they modified them.

	table.insert(poolData.Available, object)
end

--[[
    Pre-allocate a number of objects for a pool.
    @param templateName: The pool name.
    @param count: How many to create.
    @param template: The template instance.
]]
function VFXPool:Preallocate(templateName: string, count: number, template: Instance)
	if not pools[templateName] then
		pools[templateName] = {
			Available = {},
			Template = template:Clone()
		}
	end

	local poolData = pools[templateName]
	for i = 1, count do
		local obj = poolData.Template:Clone()
        obj.Name = templateName
        obj.Parent = nil -- Keep in limbo
		table.insert(poolData.Available, obj)
	end
end

--[[
    Cleanup/Empty a pool (e.g. on map change).
]]
function VFXPool:Clear(templateName: string)
    if pools[templateName] then
        for _, obj in pools[templateName].Available do
            obj:Destroy()
        end
        pools[templateName] = nil
    end
end

return VFXPool
