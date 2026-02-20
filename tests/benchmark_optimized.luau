--[[
    Benchmark Optimized: Measures the performance of using Object Pool + ParticleEmitter logic.
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

-- Mock Pool Implementation for Benchmark
local FlamePool = {
    Available = {},
    Active = {},
    Template = nil,
    Container = nil,
}

function FlamePool:Init()
    if self.Template then return end

    local part = Instance.new("Part")
    part.Name = "AnimeFire"
    part.Anchored = true
    part.CanCollide = false
    part.CanQuery = false
    part.CanTouch = false
    part.CastShadow = false
    part.Material = Enum.Material.Neon
    part.TopSurface = Enum.SurfaceType.Smooth
    part.BottomSurface = Enum.SurfaceType.Smooth
    self.Template = part

    self.Container = Instance.new("Folder")
    self.Container.Name = "FlameContainer"
    self.Container.Parent = workspace.Terrain
end

function FlamePool:Get()
    if not self.Template then self:Init() end
    local part = table.remove(self.Available)
    if not part then
        part = self.Template:Clone()
        part.Parent = self.Container
    end
    part.Transparency = 0
    return part
end

function FlamePool:Return(part)
    part.CFrame = CFrame.new(0, -1000, 0)
    table.insert(self.Available, part)
end

function FlamePool:Update(dt)
    for i = #self.Active, 1, -1 do
        local data = self.Active[i]
        data.Elapsed += dt

        if data.Elapsed >= data.Lifetime then
            self:Return(data.Part)
            table.remove(self.Active, i)
        else
            local progress = data.Elapsed / data.Lifetime
            local alpha = TweenService:GetValue(progress, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

            -- Position
            local newPos = data.StartPos:Lerp(data.EndPos, alpha)

            -- Rotation
            local rotOffset = CFrame.Angles(
                data.RotSpeed.X * data.Elapsed,
                data.RotSpeed.Y * data.Elapsed,
                data.RotSpeed.Z * data.Elapsed
            )
            local currentRot = data.StartRot * rotOffset
            data.Part.CFrame = CFrame.new(newPos) * currentRot

            -- Size
            local size = data.StartSize + (data.EndSize - data.StartSize) * alpha
            data.Part.Size = Vector3.new(size, size, size)

            -- Color
            local color
            if progress < 0.1 then
                local t = progress / 0.1
                color = Color3.fromRGB(255, 255, 200):Lerp(Color3.fromRGB(255, 180, 50), t)
            elseif progress < 0.3 then
                local t = (progress - 0.1) / 0.2
                color = Color3.fromRGB(255, 180, 50):Lerp(Color3.fromRGB(200, 60, 20), t)
            elseif progress < 0.5 then
                local t = (progress - 0.3) / 0.2
                color = Color3.fromRGB(200, 60, 20):Lerp(Color3.fromRGB(60, 60, 60), t)
            else
                color = Color3.fromRGB(60, 60, 60)
            end
            data.Part.Color = color

            -- Transparency
            data.Part.Transparency = alpha
        end
    end
end

local function benchmark()
    local totalTime = 0

    local rootPart = Instance.new("Part")
    rootPart.CFrame = CFrame.new(0, 10, 0)
    rootPart.Parent = workspace

    -- Pre-warm pool (optional, but realistic)
    FlamePool:Init()
    for i = 1, 300 do
        FlamePool:Return(FlamePool:Get())
    end

    -- Setup ParticleEmitter (once)
    local att = Instance.new("Attachment")
    att.Parent = rootPart
    local em = Instance.new("ParticleEmitter")
    em.Parent = att
    em.Enabled = false

    print("Starting Benchmark: Optimized Flamethrower")

    for i = 1, ITERATIONS do
        local start = os.clock()

        -- Simulate Frame Logic
        local dt = 1/60
        FlamePool:Update(dt) -- Update active flames

        -- Simulate handleFlamethrowerTick logic
        local originCFrame = rootPart.CFrame
        local forwardDir = originCFrame.LookVector
        local rightDir = originCFrame.RightVector
        local upDir = originCFrame.UpVector

        -- A) MAIN FLAME BLOCKS (Using Object Pool)
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

            local cube = FlamePool:Get()
            cube.Size = Vector3.new(startSize, startSize, startSize)
            cube.Color = Color3.fromRGB(255, 255, 200)

            local rot = CFrame.Angles(math.random()*6, math.random()*6, math.random()*6)
            cube.CFrame = originCFrame * rot

            local travelDist = speed * lifetime
            local endPos = originCFrame.Position + dir * travelDist + Vector3.new(0, 4, 0)

            table.insert(FlamePool.Active, {
                Part = cube,
                Lifetime = lifetime,
                Elapsed = 0,
                StartPos = originCFrame.Position,
                EndPos = endPos,
                StartSize = startSize,
                EndSize = endSize,
                StartRot = rot,
                RotSpeed = Vector3.new(math.random()*3, math.random()*3, math.random()*3),
                Direction = dir,
                Speed = speed
            })
        end

        -- B) SPARK SPRAY (Using ParticleEmitter)
        em:Emit(STRAY_COUNT)

        local elapsed = os.clock() - start
        totalTime = totalTime + elapsed

        if i % 100 == 0 then
            task.wait()
        end
    end

    print(string.format("Average Time per Frame: %.6f ms", (totalTime / ITERATIONS) * 1000))
    print(string.format("Total Time for %d frames: %.6f s", ITERATIONS, totalTime))

    rootPart:Destroy()
    FlamePool.Container:Destroy()
end

benchmark()
