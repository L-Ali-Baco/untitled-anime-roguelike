--[[
    tests/verify_combat_service.luau
    Standalone test runner for CombatService logic.

    Run with lune:
    lune run tests/verify_combat_service
]]

local fs = require("@lune/fs")
local task = require("@lune/task")

-- ============================================================================
-- MOCK ENVIRONMENT
-- ============================================================================

local MockInstances = {}
local MockModules = {}

-- Vector3 Mock (Must be defined before usage)
local Vector3 = { new = function(x,y,z) return {X=x,Y=y,Z=z, Magnitude=math.sqrt(x*x+y*y+z*z), Unit={X=0,Y=0,Z=0}} end, zero = {X=0,Y=0,Z=0} }
Vector3.new = function(x,y,z)
	local v = {X=x,Y=y,Z=z}
	v.Magnitude = math.sqrt(x*x+y*y+z*z)
	v.Unit = v -- Simplification
	setmetatable(v, {
		__add = function(a,b) return Vector3.new(a.X+b.X, a.Y+b.Y, a.Z+b.Z) end,
		__sub = function(a,b) return Vector3.new(a.X-b.X, a.Y-b.Y, a.Z-b.Z) end,
		__mul = function(a,b)
			if type(b) == "number" then return Vector3.new(a.X*b, a.Y*b, a.Z*b) end
			return Vector3.new(a.X*b.X, a.Y*b.Y, a.Z*b.Z)
		end
	})
	return v
end
Vector3.zero = Vector3.new(0,0,0)


local function createMockInstance(className, name)
	local storage = {
		ClassName = className,
		Name = name or className,
		Parent = nil,
		_children = {},
		_attributes = {},
		_tags = {},
	}

    -- Define methods in storage (to be called with proxy as self)
	function storage:FindFirstChild(n)
        -- self is proxy. self._children via __index -> storage._children
		return storage._children[n]
	end

	function storage:FindFirstChildOfClass(c)
		for _, child in pairs(storage._children) do
			if child.ClassName == c then return child end
		end
		return nil
	end

	function storage:WaitForChild(n)
		if not storage._children[n] then
			storage._children[n] = createMockInstance("Folder", n)
            storage._children[n].Parent = self -- self is proxy
		end
		return storage._children[n]
	end

	function storage:GetAttribute(n)
		return storage._attributes[n]
	end

	function storage:SetAttribute(n, v)
		storage._attributes[n] = v
	end

	function storage:GetAttributes()
		return storage._attributes
	end

	function storage:Destroy()
		self.Parent = nil
	end

    -- Humanoid specific
	if className == "Humanoid" then
		storage.Health = 100
		storage.MaxHealth = 100
		storage.TakeDamage = function(s, amt)
            -- s is proxy
            -- we need to modify storage.Health.
            -- But s.Health = ... will go to __newindex -> update storage
			s.Health = s.Health - amt
			if s.Health < 0 then s.Health = 0 end
		end
	end

	-- Part specific
	if className == "Part" or className == "MeshPart" then
		storage.Position = Vector3.new(0,0,0)
		storage.CFrame = { LookVector = Vector3.new(0,0,-1) }
	end

    local proxy = {}
    local mt = {
        __index = function(t, k)
            local v = storage[k]
            if v ~= nil then return v end
            -- Child lookup
            if storage._children[k] then return storage._children[k] end
            return nil
        end,
        __newindex = function(t, k, v)
             if k == "Parent" then
                 local oldParent = storage.Parent
                 if oldParent then
                     -- oldParent is a proxy too. accessing ._children goes to its storage?
                     -- No, ._children is hidden in storage.
                     -- We need to access oldParent's storage?
                     -- This mock is getting tricky.
                     -- Let's assume oldParent exposes _children via __index?
                     -- My __index exposes it if it's in storage.
                     if oldParent._children then
                         oldParent._children[storage.Name] = nil
                     end
                 end
                 storage.Parent = v
                 if v then
                     if v._children then
                         v._children[storage.Name] = t -- t is proxy
                     end
                 end
             elseif k == "Name" then
                 local parent = storage.Parent
                 if parent and parent._children then
                     parent._children[storage.Name] = nil
                     parent._children[v] = t
                 end
                 storage.Name = v
             else
                 storage[k] = v
             end
        end,
        __tostring = function() return storage.Name end
    }
    setmetatable(proxy, mt)

    return proxy
end

local function Instance_new(className, parent)
	local inst = createMockInstance(className)
	if parent then
		inst.Parent = parent
	end
	return inst
end

-- Global Mocks
local game = createMockInstance("DataModel", "Game")

game.GetService = function(self, name)
	if self._children[name] then
		return self._children[name]
	end
	-- Fallback for services not explicitly mocked
	local s = createMockInstance(name, name)
	self._children[name] = s
	s.Parent = self
	return s
end

local ReplicatedStorage = createMockInstance("ReplicatedStorage", "ReplicatedStorage")
game._children["ReplicatedStorage"] = ReplicatedStorage
ReplicatedStorage.Parent = game

local CollectionService = {
	HasTag = function(self, obj, tag)
		return obj._tags and obj._tags[tag] == true
	end,
	AddTag = function(self, obj, tag)
		obj._tags[tag] = true
	end
}
game._children["CollectionService"] = CollectionService -- Ensure CollectionService is in game children for GetService

local Players = createMockInstance("Players", "Players")
game._children["Players"] = Players
Players.PlayerRemoving = {
	Connect = function(self, cb) return { Disconnect = function() end } end
}

local RunService = createMockInstance("RunService", "RunService")
RunService.IsServer = function() return true end
RunService.Heartbeat = {
    Connect = function(self, cb) return { Disconnect = function() end } end
}
game._children["RunService"] = RunService


-- Setup Folder Structure for require paths
local Shared = createMockInstance("Folder", "Shared")
ReplicatedStorage._children["Shared"] = Shared

local RemotesFolder = createMockInstance("Folder", "Remotes")
Shared._children["Remotes"] = RemotesFolder

local ConfigFolder = createMockInstance("Folder", "Config")
Shared._children["Config"] = ConfigFolder

local CombatConfigModule = createMockInstance("ModuleScript", "CombatConfig")
ConfigFolder._children["CombatConfig"] = CombatConfigModule

local ClassConfigModule = createMockInstance("ModuleScript", "ClassConfig")
ConfigFolder._children["ClassConfig"] = ClassConfigModule

local LibFolder = createMockInstance("Folder", "Lib")
Shared._children["Lib"] = LibFolder

local StatLibModule = createMockInstance("ModuleScript", "StatLib")
LibFolder._children["StatLib"] = StatLibModule

local EnemyLibModule = createMockInstance("ModuleScript", "EnemyLib")
LibFolder._children["EnemyLib"] = EnemyLibModule

-- Helper to set mock module data
local function registerMockModule(instance, data)
	MockModules[instance] = data
end

-- Initial Mock Data
local MockCombatConfig = {
	Server = { MinAttackInterval = 0.1, DamageMultiplier = 1, MaxAttackRange = 50 },
	Combo = { AutoAttackInterval = 0.5, ResetTime = 1 },
	Targeting = { TargetTag = "Enemy" },
	Attacks = {
		[1] = { Damage = 10, Knockback = 5, Hitstop = 0.1, ScreenShake = 0.1 },
	}
}
registerMockModule(CombatConfigModule, MockCombatConfig)

local MockStatLib = {
	Stats = {}, -- Test overrides
	GetStat = function(self, player, name, base)
		if self.Stats[name] ~= nil then return self.Stats[name] end
		return base
	end
}
registerMockModule(StatLibModule, MockStatLib)

local MockEnemyLib = {
    IsAlive = function(self, target)
        local h = target:FindFirstChild("Humanoid")
        return h and h.Health > 0
    end,
    TakeDamage = function(self, target, amount)
        local h = target:FindFirstChild("Humanoid")
        if h then h:TakeDamage(amount) end
    end,
    GetHealth = function(self, target)
        local h = target:FindFirstChild("Humanoid")
        return h and h.Health or 0
    end
}
registerMockModule(EnemyLibModule, MockEnemyLib)

local MockRemotes = {
	GetEvent = function() return { FireAllClients = function() end, OnServerEvent = { Connect = function() end } } end,
	InitServer = function() end
}
registerMockModule(RemotesFolder, MockRemotes) -- Remotes is required as a folder in source code? "require(Shared:WaitForChild('Remotes'))" -> It might be a ModuleScript named Remotes.
-- The source says: `local Remotes = require(Shared:WaitForChild("Remotes"))`.
-- Usually Remotes is a module. Let's make it a module.
RemotesFolder.ClassName = "ModuleScript"

local MockClassConfig = {
	Warrior = { RangedAttack = { FireRate = 1 } },
	Gunner = { RangedAttack = { FireRate = 0.1, Damage = 5 } },
}
registerMockModule(ClassConfigModule, MockClassConfig)

-- Mock ProcService (required via script.Parent.ProcService)
local ProcServiceModule = createMockInstance("ModuleScript", "ProcService")
local MockProcService = {
	ProcessHit = function() end,
	ProcessKill = function() end,
}
registerMockModule(ProcServiceModule, MockProcService)

-- Mock ClassService
local ClassServiceModule = createMockInstance("ModuleScript", "ClassService")
local MockClassService = {
	GetPlayerClass = function() return "Warrior" end
}
registerMockModule(ClassServiceModule, MockClassService)

-- Mock ItemService
local ItemServiceModule = createMockInstance("ModuleScript", "ItemService")
local MockItemService = {
    GetPlayerInventory = function() return {} end
}
registerMockModule(ItemServiceModule, MockItemService)


-- GLOBALS
local _G = {
	game = game,
	Instance = { new = Instance_new },
	Vector3 = Vector3,
	task = { delay = function(t, f) f() end, wait = function() end },
	tick = os.clock,
	math = math,
	print = function(...) end, -- silence prints
	warn = function(...) print("WARN:", ...) end,
	typeof = typeof,
	type = type,
    ipairs = ipairs,
    pairs = pairs,
    tostring = tostring,
    table = table,
    OverlapParams = { new = function() return { FilterDescendantsInstances = {} } end }
}

-- Global require interceptor
local function mockRequire(module)
	if MockModules[module] then
		return MockModules[module]
	end
	error("Module not mocked: " .. tostring(module.Name))
end

-- ============================================================================
-- TEST RUNNER (Mini TestEZ)
-- ============================================================================

local currentDescribe = ""
local passCount = 0
local failCount = 0

local function describe(name, callback)
	currentDescribe = name
	print("Running Suite: " .. name)
	callback()
end

local function it(name, callback)
	local success, err = pcall(callback)
	if success then
		passCount = passCount + 1
		print("  [PASS] " .. name)
	else
		failCount = failCount + 1
		print("  [FAIL] " .. name)
		print("    Error: " .. tostring(err))
	end
end

local function expect(value)
	return {
		to = {
			equal = function(expected)
				if value ~= expected then
					error("Expected " .. tostring(expected) .. " but got " .. tostring(value))
				end
			end
		}
	}
end

local function beforeEach(callback)
	-- In this simple runner, we rely on the test structure to call this manually or
	-- we need to track 'it' blocks.
	-- For simplicity, we define it globally but user must call it or we structure tests to call it.
	-- Since the spec calls `beforeEach`, we need to implement it to run BEFORE every `it`.
	-- This is hard in a simple synchronous function.
	-- We will hack it: save the callback and call it inside `it`.
	_G._beforeEachCallback = callback
end

-- Wrap `it` to call beforeEach
local originalIt = it
it = function(name, callback)
	originalIt(name, function()
		if _G._beforeEachCallback then _G._beforeEachCallback() end
		callback()
	end)
end

-- ============================================================================
-- LOAD & RUN
-- ============================================================================

local function loadScript(path, env)
	local content = fs.readFile(path)
	-- Remove 'return CombatService' if we want to capture it differently?
	-- No, loadstring returns the chunk as a function. Executing it returns the module.

	-- We need to construct the environment
	local newEnv = setmetatable({}, { __index = _G })
	for k,v in pairs(env or {}) do newEnv[k] = v end

	newEnv.require = mockRequire
	newEnv.game = game
	newEnv.script = createMockInstance("Script") -- Dummy script

	-- Special handling for script.Parent lookups
	if path:find("CombatService.luau") then
		newEnv.script.Parent = createMockInstance("Folder", "Services")
		-- Add ProcService to Services so `script.Parent.ProcService` works
		newEnv.script.Parent._children["ProcService"] = ProcServiceModule
		newEnv.script.Parent._children["ClassService"] = ClassServiceModule
        newEnv.script.Parent._children["ItemService"] = ItemServiceModule
	end

	if path:find("CombatService.spec.luau") then
		newEnv.describe = describe
		newEnv.it = it
		newEnv.expect = expect
		newEnv.beforeEach = beforeEach
		newEnv.script.Parent = createMockInstance("Folder", "Services")
		-- The spec requires CombatService from script.Parent.CombatService
		-- We need to put the loaded CombatService module there.
		-- BUT, we haven't loaded it yet.
	end

	-- Luau loadstring
	local chunk, err = (loadstring or load)(content, path)
	if not chunk then error(err) end
	setfenv(chunk, newEnv)
	return chunk
end

-- 1. Load CombatService
print("Loading CombatService...")
local combatServiceChunk = loadScript("src/server/Services/CombatService.luau")
local CombatService = combatServiceChunk()

-- Register it for the spec to find
local CombatServiceModule = createMockInstance("ModuleScript", "CombatService")
registerMockModule(CombatServiceModule, CombatService)

-- 2. Load Spec
print("Loading CombatService.spec...")
-- We need to make sure the spec can find CombatService via `script.Parent.CombatService`
-- In `loadScript` for spec, we set script.Parent.
-- We need to add CombatServiceModule to that parent.

local specEnv = {}
local specChunk = loadScript("src/server/Services/CombatService.spec.luau", specEnv)

-- Inject the mocked module into the spec's script.Parent
local specServicesFolder = getfenv(specChunk).script.Parent
specServicesFolder._children["CombatService"] = CombatServiceModule

-- 3. Run Spec
print("Running Tests...")
local specRunner = specChunk() -- Returns the function() ... end
specRunner()

print("==================================================")
print("Results: " .. passCount .. " Passed, " .. failCount .. " Failed")
if failCount > 0 then
	error("Tests failed!")
end
