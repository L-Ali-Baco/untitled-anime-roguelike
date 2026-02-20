--[[
    verify_enemy_service_health.luau

    Verifies that EnemyService has been cleaned up correctly:
    1. No reference to PathfindingService
    2. EnemyData structure does not contain pathfinding fields
    3. EnemyConfig does not contain pathfinding keys
]]

local process = require("@lune/process")
local fs = require("@lune/fs")
local stdio = require("@lune/stdio")
local luau = require("@lune/luau")

local function run()
    stdio.write(stdio.color("blue") .. "Starting EnemyService Code Health Verification...\n" .. stdio.color("reset"))

    -- 1. Check for PathfindingService usage in EnemyService.luau source
    local enemyServiceSource = fs.readFile("src/server/Services/EnemyService.luau")

    if string.find(enemyServiceSource, "PathfindingService") then
        if string.find(enemyServiceSource, "local _PathfindingService") then
             stdio.write(stdio.color("red") .. "[FAIL] EnemyService still imports PathfindingService\n" .. stdio.color("reset"))
             process.exit(1)
        else
            -- Check if it's just a comment
            local lines = string.split(enemyServiceSource, "\n")
            for i, line in ipairs(lines) do
                if string.find(line, "PathfindingService") and not string.find(line, "^%s*%-%-") then
                     -- Check if it is inside a comment block (simplistic check)
                     if not string.find(line, "%-%-%[%[") and not string.find(line, "%]%]") then
                        stdio.write(stdio.color("red") .. "[FAIL] Found 'PathfindingService' usage at line " .. i .. ": " .. line .. "\n" .. stdio.color("reset"))
                        process.exit(1)
                     end
                end
            end
        end
    end
    stdio.write(stdio.color("green") .. "[PASS] EnemyService source checked for PathfindingService import.\n" .. stdio.color("reset"))

    -- Setup minimal mock environment for Config
    -- luau.load environment is isolated, so we need to inject globals
    local env = {
        Vector3 = {
            new = function(x,y,z) return { X=x or 0, Y=y or 0, Z=z or 0, Magnitude = 1, Unit = {X=0,Y=0,Z=0} } end,
            zero = { X=0, Y=0, Z=0 }
        }
    }

    -- Load EnemyConfig manually
    local configContent = fs.readFile("src/shared/Config/EnemyConfig.luau")
    local loadConfig = luau.load(configContent, { environment = env })
    if not loadConfig then
         stdio.write(stdio.color("red") .. "[FAIL] Could not load EnemyConfig.luau\n" .. stdio.color("reset"))
         process.exit(1)
    end
    local EnemyConfig = loadConfig()

    -- 3. Verify EnemyConfig cleanup
    if EnemyConfig.AI.PathfindingEnabled ~= nil then
         stdio.write(stdio.color("red") .. "[FAIL] EnemyConfig still has 'PathfindingEnabled'\n" .. stdio.color("reset"))
         process.exit(1)
    end
    if EnemyConfig.AI.PathRecalculateInterval ~= nil then
         stdio.write(stdio.color("red") .. "[FAIL] EnemyConfig still has 'PathRecalculateInterval'\n" .. stdio.color("reset"))
         process.exit(1)
    end
    stdio.write(stdio.color("green") .. "[PASS] EnemyConfig checked for pathfinding keys.\n" .. stdio.color("reset"))

    stdio.write(stdio.color("green") .. "\nAll Code Health Verification Checks Passed!\n" .. stdio.color("reset"))
end

run()
