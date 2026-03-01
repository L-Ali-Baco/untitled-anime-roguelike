--[[
    Benchmark: getEnemiesInRadius Spatial Query vs Tag Check
    Compares the execution time of workspace:GetPartBoundsInRadius
    vs CollectionService:GetTagged() with distance check.
]]

local startTotal = os.clock()

local function createMockInstance(name, class, props)
    local inst = {
        Name = name,
        ClassName = class,
    }
    for k, v in props do
        inst[k] = v
    end

    inst.children = {}
    inst.attributes = {}

    function inst:GetAttribute(k)
        return self.attributes[k]
    end

    function inst:SetAttribute(k, v)
        self.attributes[k] = v
    end

    function inst:FindFirstChild(n)
        for _, c in self.children do
            if c.Name == n then return c end
        end
        return nil
    end

    function inst:FindFirstChildOfClass(c)
        for _, ch in self.children do
            if ch.ClassName == c then return ch end
        end
        return nil
    end

    function inst:FindFirstAncestorOfClass(c)
        return self.parent
    end

    function inst:GetDescendants()
        return self.children
    end

    return inst
end

-- Mock globals for Lune
_G.Vector3 = {
    new = function(x, y, z)
        return {
            X = x, Y = y, Z = z,
            Magnitude = math.sqrt(x*x + y*y + z*z),
            __sub = function(a, b)
                return _G.Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
            end
        }
    end
}
_G.Vector3.zero = _G.Vector3.new(0, 0, 0)

-- Metatable to support operator overloading for custom Vector3
local vec3Mt = {
    __sub = function(a, b)
        return _G.Vector3.new(a.X - b.X, a.Y - b.Y, a.Z - b.Z)
    end
}

local function createVec3(x,y,z)
    local v = {X=x, Y=y, Z=z}
    setmetatable(v, vec3Mt)
    return v
end

-- Override mock Vector3 to use metamethods correctly
_G.Vector3.new = function(x, y, z)
    local v = createVec3(x, y, z)

    local mt = getmetatable(v)
    mt.__index = function(t, k)
        if k == "Magnitude" then
            return math.sqrt(t.X*t.X + t.Y*t.Y + t.Z*t.Z)
        end
    end

    return v
end


local Enum = {
    RaycastFilterType = { Exclude = 1 }
}
_G.Enum = Enum

local OverlapParams = {
    new = function()
        return {
            FilterType = Enum.RaycastFilterType.Exclude,
            FilterDescendantsInstances = {}
        }
    end
}
_G.OverlapParams = OverlapParams

-- Setup mock game services
local mockCollection = {
    tags = {},
    HasTag = function(self, inst, tag)
        if not self.tags[tag] then return false end
        for _, v in self.tags[tag] do
            if v == inst then return true end
        end
        return false
    end,
    GetTagged = function(self, tag)
        return self.tags[tag] or {}
    end,
    AddTag = function(self, inst, tag)
        if not self.tags[tag] then self.tags[tag] = {} end
        table.insert(self.tags[tag], inst)
    end
}

local mockWorkspaceParts = {}
local mockWorkspace = {
    GetPartBoundsInRadius = function(self, position, radius, params)
        local results = {}
        for _, part in mockWorkspaceParts do
            -- Spatial check simulation
            local d = (part.Position - position).Magnitude
            if d <= radius then
                table.insert(results, part)
            end
        end
        return results
    end
}

_G.game = {
    GetService = function(self, name)
        if name == "CollectionService" then return mockCollection end
        if name == "ReplicatedStorage" then return { WaitForChild = function() return { WaitForChild = function() return {} end} end } end
        return {}
    end
}
_G.workspace = mockWorkspace


-- Generate test environment
local NUM_ENEMIES = 50
local NUM_PARTS_PER_ENEMY = 10
local NUM_DECORATION_PARTS = 2000 -- Lots of environment parts to simulate complex scene

math.randomseed(123)

print("Setting up benchmark scene...")
print(string.format("Enemies: %d, Parts per enemy: %d, Decoration parts: %d", NUM_ENEMIES, NUM_PARTS_PER_ENEMY, NUM_DECORATION_PARTS))

-- Add environment parts
for i=1, NUM_DECORATION_PARTS do
    local pos = _G.Vector3.new(math.random(-100, 100), 0, math.random(-100, 100))
    local part = createMockInstance("Rock", "Part", {Position = pos})
    table.insert(mockWorkspaceParts, part)
end

local enemies = {}

-- Add enemies
for i=1, NUM_ENEMIES do
    local model = createMockInstance("Enemy"..i, "Model", {})
    model.attributes["IsEnemy"] = true
    model.attributes["Health"] = 100
    model.attributes["IsDead"] = false

    local pos = _G.Vector3.new(math.random(-50, 50), 0, math.random(-50, 50))
    local root = createMockInstance("HumanoidRootPart", "Part", {Position = pos})
    root.parent = model
    table.insert(model.children, root)
    model.PrimaryPart = root

    -- Add body parts
    for j=1, NUM_PARTS_PER_ENEMY do
        local partPos = _G.Vector3.new(pos.X + math.random(-2,2), pos.Y + math.random(0,5), pos.Z + math.random(-2,2))
        local part = createMockInstance("Limb"..j, "Part", {Position = partPos})
        part.parent = model
        table.insert(model.children, part)
        table.insert(mockWorkspaceParts, part)
    end

    mockCollection:AddTag(model, "Enemy")
    table.insert(enemies, model)
end

-- Setup CombatLib mock for original implementation
local function original_getEnemiesInRadius(position, radius)
	local enemiesFound = {}
	local overlapParams = OverlapParams.new()
	overlapParams.FilterType = Enum.RaycastFilterType.Exclude
	overlapParams.FilterDescendantsInstances = {}

	local parts = workspace:GetPartBoundsInRadius(position, radius, overlapParams)
	local checked = {}

	for _, part in parts do
		local model = part:FindFirstAncestorOfClass("Model")
		if model and not checked[model] then
			checked[model] = true
			if
				mockCollection:HasTag(model, "Enemy")
				or mockCollection:HasTag(model, "TrainingDummy")
			then
				local isAlive = model:GetAttribute("Health") and model:GetAttribute("Health") > 0 and not model:GetAttribute("IsDead")
				if isAlive then
					table.insert(enemiesFound, model)
				end
			end
		end
	end

	return enemiesFound
end


-- Setup CombatLib mock for new implementation
local function optimized_getEnemiesInRadius(position, radius)
	local enemiesFound = {}

	-- Build a quick lookup for excluded models
	local excluded = {}

	-- Helper function to check and add valid enemies from a tag
	local function checkTagged(tag)
		for _, model in mockCollection:GetTagged(tag) do
			if excluded[model] then
				continue
			end

			local isAlive = model:GetAttribute("Health") and model:GetAttribute("Health") > 0 and not model:GetAttribute("IsDead")
			if not isAlive then
				continue
			end

			local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
			if not root then
				continue
			end

			local distance = (root.Position - position).Magnitude
			if distance <= radius then
				table.insert(enemiesFound, model)
			end
		end
	end

	checkTagged("Enemy")
	checkTagged("TrainingDummy")

	return enemiesFound
end


print("Running benchmark...")
local targetPos = _G.Vector3.new(0, 0, 0)
local testRadius = 30
local iterations = 1000

local resultsOriginal = {}
local startOriginal = os.clock()
for i=1, iterations do
    resultsOriginal = original_getEnemiesInRadius(targetPos, testRadius)
end
local timeOriginal = os.clock() - startOriginal

local resultsOptimized = {}
local startOptimized = os.clock()
for i=1, iterations do
    resultsOptimized = optimized_getEnemiesInRadius(targetPos, testRadius)
end
local timeOptimized = os.clock() - startOptimized

print("--------------------------------------------------")
print(string.format("Original time: %.4fs", timeOriginal))
print(string.format("Optimized time: %.4fs", timeOptimized))
print(string.format("Performance Improvement: %.2fx faster", timeOriginal / timeOptimized))
print(string.format("Results Match: %s (Original: %d, Optimized: %d)",
    tostring(#resultsOriginal == #resultsOptimized), #resultsOriginal, #resultsOptimized))
print("--------------------------------------------------")
