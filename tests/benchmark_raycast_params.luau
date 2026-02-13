--[[
    Benchmark: RaycastParams Allocation vs Reuse

    This script demonstrates the memory allocation difference between creating a new RaycastParams
    instance for every raycast versus reusing a single instance.

    Usage: Run this script in a Roblox Studio command bar or a Script.
]]

local RaycastParamsMock = {}
RaycastParamsMock.__index = RaycastParamsMock

function RaycastParamsMock.new()
    local self = setmetatable({}, RaycastParamsMock)
    self.FilterDescendantsInstances = {}
    self.FilterType = Enum.RaycastFilterType.Exclude
    return self
end

-- Track allocations
local allocations = 0
local originalNew = RaycastParamsMock.new
function RaycastParamsMock.new()
    allocations = allocations + 1
    return originalNew()
end

-- Mock Workspace
local WorkspaceMock = {}
function WorkspaceMock:Raycast(origin, direction, params)
    return nil -- simplified
end

-- Setup
local character = Instance.new("Model")
local iterations = 1000

print("Running Benchmark: RaycastParams Allocation vs Reuse (" .. iterations .. " iterations)")

-- Test 1: Current Implementation (Allocation per call)
allocations = 0
local start1 = os.clock()
for i = 1, iterations do
    local params = RaycastParamsMock.new()
    params.FilterDescendantsInstances = { character }
    params.FilterType = Enum.RaycastFilterType.Exclude
    WorkspaceMock:Raycast(Vector3.new(), Vector3.new(0, 0, -10), params)
end
local time1 = os.clock() - start1
print(string.format("Current Implementation: %d Allocations, Time: %.6f seconds", allocations, time1))

-- Test 2: Optimized Implementation (Reuse single instance)
allocations = 0
local start2 = os.clock()
local sharedParams = RaycastParamsMock.new()
sharedParams.FilterType = Enum.RaycastFilterType.Exclude

for i = 1, iterations do
    sharedParams.FilterDescendantsInstances = { character }
    WorkspaceMock:Raycast(Vector3.new(), Vector3.new(0, 0, -10), sharedParams)
end
local time2 = os.clock() - start2
-- Count the initial allocation for sharedParams
allocations = allocations + 1
print(string.format("Optimized Implementation: %d Allocations, Time: %.6f seconds", allocations, time2))

local improvement = time1 / time2
print(string.format("Improvement: %.2fx faster (simulated)", improvement))
