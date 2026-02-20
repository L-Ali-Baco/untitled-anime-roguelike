--[[
    Benchmark Baseline: Measures the performance of creating flamethrower parts every frame.
    To run this in Roblox Studio:
    1. Create a LocalScript in StarterPlayerScripts.
    2. Paste this code.
    3. Run the game and check output.
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local ITERATIONS = 1000 -- Number of frames to simulate
local VOXEL_COUNT = 6
local STRAY_COUNT = 3

local function benchmark()
    local totalTime = 0

    local rootPart = Instance.new("Part")
    rootPart.CFrame = CFrame.new(0, 10, 0)
    rootPart.Parent = workspace

    print("Starting Benchmark: Flamethrower Part Creation")

    for i = 1, ITERATIONS do
        local start = os.clock()

        -- Simulate handleFlamethrowerTick logic (simplified)
        local originCFrame = rootPart.CFrame
        local forwardDir = originCFrame.LookVector
        local rightDir = originCFrame.RightVector
        local upDir = originCFrame.UpVector

        -- A) MAIN FLAME BLOCKS
        for _ = 1, VOXEL_COUNT do
            local angle = tick() * 12 + (math.random() * 2)
            local turbX = math.sin(angle) * 0.15
            local turbY = math.cos(angle * 0.7) * 0.15

            local spreadX = (math.random() - 0.5) * 0.4 + turbX
            local spreadY = (math.random() - 0.5) * 0.4 + turbY

            local dir = (forwardDir + rightDir * spreadX + upDir * spreadY).Unit
            local speed = 45 * (0.85 + math.random() * 0.4)
            local lifetime = 0.6 + math.random() * 0.3

            local startSize = 1.0
            local endSize = 5.0

            local cube = Instance.new("Part")
            cube.Name = "AnimeFire"
            cube.Anchored = true
            cube.CanCollide = false
            cube.CanQuery = false
            cube.CanTouch = false
            cube.Material = Enum.Material.Neon
            cube.Size = Vector3.new(startSize, startSize, startSize)
            cube.Color = Color3.fromRGB(255, 255, 200)
            cube.Transparency = 0

            local rot = CFrame.Angles(math.random()*6, math.random()*6, math.random()*6)
            cube.CFrame = originCFrame * rot
            cube.Parent = workspace.Terrain
            Debris:AddItem(cube, lifetime + 0.1)

            local travelDist = speed * lifetime
            local endPos = originCFrame.Position + dir * travelDist + Vector3.new(0, 4, 0)

            local tweenInfo = TweenInfo.new(lifetime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
            local targetRot = rot * CFrame.Angles(math.random()*3, math.random()*3, math.random()*3)

            local tween = TweenService:Create(cube, tweenInfo, {
                CFrame = CFrame.new(endPos) * targetRot,
                Size = Vector3.new(endSize, endSize, endSize),
                Transparency = 1
            })
            tween:Play()

            task.spawn(function()
                task.wait(lifetime * 0.1)
                if not cube.Parent then return end
                TweenService:Create(cube, TweenInfo.new(lifetime * 0.2), {Color = Color3.fromRGB(255, 180, 50)}):Play()
                task.wait(lifetime * 0.2)
                if not cube.Parent then return end
                TweenService:Create(cube, TweenInfo.new(lifetime * 0.3), {Color = Color3.fromRGB(200, 60, 20)}):Play()
                task.wait(lifetime * 0.2)
                if not cube.Parent then return end
                TweenService:Create(cube, TweenInfo.new(lifetime * 0.2), {Color = Color3.fromRGB(60, 60, 60)}):Play()
            end)
        end

        -- B) SPARK SPRAY
        for _ = 1, STRAY_COUNT do
            local spreadAmount = 1.0
            local spreadX = (math.random() - 0.5) * spreadAmount
            local spreadY = (math.random() - 0.5) * spreadAmount

            local dir = (forwardDir + rightDir * spreadX + upDir * spreadY).Unit
            local speed = 110 * (0.7 + math.random() * 0.6)
            local lifetime = 0.35

            local spark = Instance.new("Part")
            spark.Name = "FireSpark"
            spark.Anchored = true
            spark.CanCollide = false
            spark.CanQuery = false
            spark.Material = Enum.Material.Neon
            spark.Size = Vector3.new(0.2, 0.2, 0.2)
            spark.Color = Color3.fromRGB(255, 255, 180)
            spark.CFrame = originCFrame
            spark.Parent = workspace.Terrain
            Debris:AddItem(spark, lifetime + 0.1)

            local endPos = originCFrame.Position + dir * (speed * lifetime)

            TweenService:Create(spark, TweenInfo.new(lifetime, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out), {
                Position = endPos,
                Size = Vector3.new(0, 0, 0),
                Transparency = 0.5
            }):Play()
        end

        local elapsed = os.clock() - start
        totalTime = totalTime + elapsed

        if i % 100 == 0 then
            task.wait() -- Yield to prevent script timeout
        end
    end

    print(string.format("Average Time per Frame: %.6f ms", (totalTime / ITERATIONS) * 1000))
    print(string.format("Total Time for %d frames: %.6f s", ITERATIONS, totalTime))

    rootPart:Destroy()
end

benchmark()
