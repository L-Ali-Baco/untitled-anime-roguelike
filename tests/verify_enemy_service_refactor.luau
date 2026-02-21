local fs = require("@lune/fs")
local luau = require("@lune/luau")
local stdio = require("@lune/stdio")

local function mockInstance(className)
	return setmetatable({
		Name = className,
		ClassName = className,
		Parent = nil,
		_children = {},
		WaitForChild = function(self, name)
			if not self._children[name] then
				self._children[name] = mockInstance("Folder")
				self._children[name].Name = name
			end
			return self._children[name]
		end,
		FindFirstChild = function(self, name)
			return self._children[name]
		end,
		GetService = function(self, name)
			if not self._children[name] then
				self._children[name] = mockInstance("Service")
				self._children[name].Name = name
			end
			return self._children[name]
		end,
		GetDescendants = function(self) return {} end,
		GetPlayers = function(self) return {} end,
		Connect = function(self, callback) return { Disconnect = function() end } end,
	}, {
		__index = function(self, key)
			if key == "Heartbeat" or key == "PlayerRemoving" or key == "OnServerEvent" then
				return { Connect = function() end }
			end
			return rawget(self, key)
		end,
		__newindex = function(self, key, value)
			rawset(self, key, value)
		end
	})
end

local gameMock = mockInstance("DataModel")
local scriptMock = mockInstance("Script")
scriptMock.Parent = gameMock:GetService("ServerScriptService")

local function customRequire(path)
	-- simple mock for require
	return {
		Types = { Minion = {}, Brute = {}, Shooter = {} },
		AI = { MaxActiveEnemies = 10, UpdateRate = 0.1, DetectionRange = 50 },
		Aggro = { ChaseRange = 100 },
		Death = { RagdollDuration = 2, FadeOutDuration = 1 },
		Targeting = { TargetTag = "Target" },
		Dash = { Duration = 0.2, Cooldown = 1, IFrameDuration = 0.2 },
		InitServer = function() end,
		GetEvent = function() return { FireAllClients = function() end, FireClient = function() end, OnServerEvent = { Connect = function() end } } end,
		IsAlive = function() return true end,
		IsEnemy = function() return true end,
		SetupAttributes = function() end,
	}
end

local env = setmetatable({
	game = gameMock,
	script = scriptMock,
	require = customRequire,
	Instance = { new = function(className) return mockInstance(className) end },
	Enum = {
		ActuatorRelativeTo = { World = 1 },
		VelocityConstraintMode = { Plane = 1 },
		OrientationAlignmentMode = { OneAttachment = 1 },
		AnimationPriority = { Action4 = 1, Movement = 2, Action = 3 },
		RaycastFilterType = { Exclude = 1 },
		PathStatus = { Success = 1 }
	},
	Vector3 = { new = function(x,y,z) return {X=x,Y=y,Z=z, Magnitude=1} end, zero = {X=0,Y=0,Z=0} },
	Vector2 = { new = function(x,y) return {X=x,Y=y} end, zero = {X=0,Y=0} },
	CFrame = {
		new = function() return { LookVector = {X=0,Y=0,Z=1}, Position = {X=0,Y=0,Z=0}, ToEulerAnglesYXZ = function() return 0,0,0 end } end,
		lookAt = function() return { LookVector = {X=0,Y=0,Z=1} } end,
		Angles = function() return {} end
	},
	RaycastParams = { new = function() return {} end },
	Color3 = { fromRGB = function() return {} end },
	math = math,
	task = { wait = function() end, delay = function() end, spawn = function(f) f() end },
	pcall = pcall,
	print = function(...) end,
	warn = function(...) end,
	select = select,
	table = table,
	tick = os.clock,
	type = type,
}, { __index = _G })

local function loadScript(path)
	local content = fs.readFile(path)
	local bytecode = luau.compile(content)
	local fn = luau.load(bytecode, { environment = env })
	return fn()
end

print("Loading EnemyService...")
local success, result = pcall(function()
	loadScript("src/server/Services/EnemyService.luau")
end)

if success then
	print("EnemyService loaded successfully (syntax check passed).")
else
	print("Failed to load EnemyService:", result)
	process.exit(1)
end
