-- benchmark_remotes.luau
-- A focused benchmark to measure the impact of caching RemoteEvent retrieval.

--[[
    MOCKING SECTION
    We need to mock the Roblox environment to run this in a standalone Luau environment.
]]

local _game_children = {}
local game = {
	GetService = function(_, serviceName)
		if not _game_children[serviceName] then
			_game_children[serviceName] = {
				Name = serviceName,
				_children = {},
				FindFirstChild = function(self, name)
					return self._children[name]
				end,
				WaitForChild = function(self, name)
					return self._children[name]
				end,
			}
		end
		return _game_children[serviceName]
	end,
}

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local RunService = {
	IsServer = function()
		return true
	end,
}

local Instance = {
	new = function(className)
		local inst = {
			ClassName = className,
			Name = className,
			_children = {},
			Parent = nil,
		}
		function inst:FindFirstChild(name)
			return self._children[name]
		end
		-- Mock Parent setter
		setmetatable(inst, {
			__newindex = function(t, k, v)
				if k == "Parent" then
					if v then
						v._children[t.Name] = t
					end
					rawset(t, k, v)
				else
					rawset(t, k, v)
				end
			end,
		})
		return inst
	end,
}

-- Custom require-like function to load Remotes.luau with our mock environment
local function loadRemotes()
	local file = io.open("src/shared/Remotes.luau", "r")
	if not file then
		error("Could not find src/shared/Remotes.luau")
	end
	local content = file:read("*all")
	file:close()

	-- Strip the 'return Remotes' and wrap in a function
	local functionSource = "local game, RunService, ReplicatedStorage, Instance = ...\n" .. content
	local chunk, err = loadstring(functionSource)
	if not chunk then
		error("Failed to load Remotes: " .. err)
	end

	return chunk(game, RunService, ReplicatedStorage, Instance)
end

local Remotes = loadRemotes()

-- Initialize remotes on server
Remotes:InitServer()

local iterations = 1000000
local eventName = "RequestAttack"

print("Starting benchmark with " .. iterations .. " iterations...")

-- Baseline measurement
local start = os.clock()
for i = 1, iterations do
	local event = Remotes:GetEvent(eventName)
end
local stop = os.clock()

local elapsed = stop - start
print(string.format("Elapsed time: %.4f seconds", elapsed))
print(string.format("Average time per call: %.8f seconds", elapsed / iterations))
