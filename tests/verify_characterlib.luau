--[[
    Standalone verification script for CharacterLib.
    This script mocks the Roblox API and verifies the logic of CharacterLib.
    Run with `lune run tests/verify_characterlib.luau` (if lune is installed)
]]

local process = { exit = function(code) end } -- Fallback if not in lune
if _G.process then process = _G.process end

-- 1. Mock Roblox API
local MockInstance = {}
MockInstance.__index = MockInstance

function MockInstance.new(className)
    local self = setmetatable({
        ClassName = className,
        Name = className,
        Parent = nil,
        _children = {},
        _attributes = {},
        PrimaryPart = nil, -- For Model
        Health = 100, -- For Humanoid
    }, MockInstance)
    return self
end

function MockInstance:FindFirstChild(name)
    for _, child in ipairs(self._children) do
        if child.Name == name then
            return child
        end
    end
    return nil
end

function MockInstance:FindFirstChildOfClass(className)
    for _, child in ipairs(self._children) do
        if child:IsA(className) then
            return child
        end
    end
    return nil
end

function MockInstance:IsA(className)
    if self.ClassName == className then return true end
    if className == "BasePart" and (self.ClassName == "Part" or self.ClassName == "MeshPart") then return true end
    if className == "Model" and self.ClassName == "Model" then return true end
    return false
end

function MockInstance:GetAttribute(name)
    return self._attributes[name]
end

function MockInstance:SetAttribute(name, value)
    self._attributes[name] = value
end

function MockInstance:SetParent(parent)
    self.Parent = parent
    if parent then
        table.insert(parent._children, self)
    end
end

-- Polyfill Instance.new for the test setup, though CharacterLib doesn't use it.
-- Polyfill Instance.new for the test setup
local Instance = {
    new = function(className)
        return MockInstance.new(className)
    end
}
_G.Instance = Instance

-- 2. Load CharacterLib
-- We try to require it relative to this script.
-- Assuming running from project root: require("src/shared/Lib/CharacterLib")
local CharacterLib
local success, result = pcall(function()
    return require("src/shared/Lib/CharacterLib")
end)

if not success then
    -- Try relative path if running from tests dir?
    success, result = pcall(function()
        return require("../src/shared/Lib/CharacterLib")
    end)
end

if not success then
    print("Failed to require CharacterLib: " .. tostring(result))
    -- Fallback: manually define it if we can't load the file (e.g. if we are just verifying logic via reading)
    -- But since we want to verify the ACTUAL code, we really want to require it.
    -- If we can't require it, we can't verify it with this script.
    os.exit(1)
end

CharacterLib = result

-- 3. Run Tests
local function runTest(name, func)
    print("Running " .. name .. "...")
    local status, err = pcall(func)
    if status then
        print("  PASS")
    else
        print("  FAIL")
        print("Error: " .. tostring(err))
        os.exit(1)
    end
end

local function assertEqual(actual, expected, msg)
    if actual ~= expected then
        error(msg or string.format("Expected %s, got %s", tostring(expected), tostring(actual)))
    end
end

print("Starting Verification for CharacterLib...")

runTest("GetRootPart returns nil for nil model", function()
    assertEqual(CharacterLib:GetRootPart(nil), nil)
end)

runTest("GetRootPart returns HumanoidRootPart", function()
    local model = Instance.new("Model")
    local hrp = Instance.new("Part")
    hrp.Name = "HumanoidRootPart"
    hrp:SetParent(model)

    assertEqual(CharacterLib:GetRootPart(model), hrp)
end)

runTest("GetRootPart returns Root if HRP missing", function()
    local model = Instance.new("Model")
    local root = Instance.new("Part")
    root.Name = "Root"
    root:SetParent(model)

    assertEqual(CharacterLib:GetRootPart(model), root)
end)

runTest("GetRootPart prioritizes HumanoidRootPart", function()
    local model = Instance.new("Model")
    local hrp = Instance.new("Part")
    hrp.Name = "HumanoidRootPart"
    hrp:SetParent(model)
    local root = Instance.new("Part")
    root.Name = "Root"
    root:SetParent(model)

    assertEqual(CharacterLib:GetRootPart(model), hrp)
end)

runTest("GetRootPart returns PrimaryPart if no named roots", function()
    local model = Instance.new("Model")
    local pp = Instance.new("Part")
    pp.Name = "RandomPart"
    pp:SetParent(model)
    model.PrimaryPart = pp

    assertEqual(CharacterLib:GetRootPart(model), pp)
end)

runTest("GetRootPart returns any BasePart as fallback", function()
    local model = Instance.new("Model")
    local part = Instance.new("Part")
    part.Name = "SomePart"
    part:SetParent(model)

    assertEqual(CharacterLib:GetRootPart(model), part)
end)

runTest("GetRootPart skips non-BasePart named root", function()
    local model = Instance.new("Model")
    local folder = Instance.new("Folder") -- Not a BasePart
    folder.Name = "HumanoidRootPart"
    folder:SetParent(model)

    local root = Instance.new("Part")
    root.Name = "Root"
    root:SetParent(model)

    assertEqual(CharacterLib:GetRootPart(model), root)
end)

runTest("IsCustomRig checks attribute", function()
    local model = Instance.new("Model")
    model:SetAttribute("IsCustomRig", true)
    assertEqual(CharacterLib:IsCustomRig(model), true)

    model:SetAttribute("IsCustomRig", false)
    assertEqual(CharacterLib:IsCustomRig(model), false)
end)

print("All tests passed successfully!")
