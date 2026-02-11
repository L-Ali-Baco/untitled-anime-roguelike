--[[
    SkillVFX.luau
    Handles visual effects for character skills.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local SkillVFX = {}

--[[
    Create a shockwave ring effect
]]
local function playSeismicSlam(rootPart, radius)
	local position = rootPart.Position - Vector3.new(0, 2, 0)
	
	-- Ring Part
	local ring = Instance.new("Part")
	ring.Name = "SeismicRing"
	ring.Anchored = true
	ring.CanCollide = false
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 100, 50)
	ring.Size = Vector3.new(0.5, 2, 2) -- Height 0.5, Diameter 2
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = workspace.Terrain
	
	-- Expand tween
	local tween = TweenService:Create(ring, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.5, radius * 2, radius * 2),
		Transparency = 1
	})
	tween:Play()
	
	Debris:AddItem(ring, 0.5)
	
	-- Ground Cracks (Placeholder: Blocks)
	for i = 1, 5 do
		local rock = Instance.new("Part")
		rock.Size = Vector3.new(2, 2, 2)
		rock.Anchored = true
		rock.CanCollide = false
		rock.Material = Enum.Material.Slate
		rock.Color = Color3.fromRGB(50, 50, 50)
		rock.Position = position + Vector3.new(math.random(-5,5), -1, math.random(-5,5))
		rock.Orientation = Vector3.new(math.random(0,360), math.random(0,360), math.random(0,360))
		rock.Parent = workspace.Terrain
		
		TweenService:Create(rock, TweenInfo.new(0.3), {
			Position = rock.Position + Vector3.new(0, 3, 0)
		}):Play()
		
		Debris:AddItem(rock, 2)
	end
end

--[[
    Create slash effects in a cone
]]
local function playBladeStorm(rootPart)
	local duration = 1.5
	local hitCount = 6
	local interval = duration / hitCount
	
	task.spawn(function()
		for i = 1, hitCount do
			if not rootPart or not rootPart.Parent then break end
			
			local slash = Instance.new("Part")
			slash.Size = Vector3.new(8, 0.5, 8)
			slash.Anchored = true
			slash.CanCollide = false
			slash.Material = Enum.Material.Neon
			slash.Color = Color3.fromRGB(100, 200, 255)
			
			-- Random offset in front
			local offset = CFrame.new(0, 0, -5) * CFrame.Angles(0, math.rad(math.random(-30, 30)), 0)
			slash.CFrame = rootPart.CFrame * offset * CFrame.Angles(math.rad(math.random(-15, 15)), 0, math.rad(math.random(-180, 180)))
			slash.Parent = workspace.Terrain
			
			TweenService:Create(slash, TweenInfo.new(0.2), {
				Transparency = 1,
				Size = Vector3.new(12, 0.5, 12)
			}):Play()
			
			Debris:AddItem(slash, 0.2)
			task.wait(interval)
		end
	end)
end

--[[
    Create shotgun tracers
]]
local function playBuckshotBlast(rootPart)
	local origin = rootPart.Position
	local lookDir = rootPart.CFrame.LookVector
	
	for i = 1, 5 do
		local spread = math.rad(25)
		local x = (math.random() - 0.5) * spread
		local y = (math.random() - 0.5) * spread
		local dir = (CFrame.new(Vector3.zero, lookDir) * CFrame.Angles(x, y, 0)).LookVector
		
		local endPos = origin + dir * 30
		
		-- Beam Part
		local p1 = Instance.new("Part")
		p1.Name = "Tracer"
		p1.Anchored = true
		p1.CanCollide = false
		p1.Material = Enum.Material.Neon
		p1.Color = Color3.fromRGB(255, 180, 50) -- Orange-Gold
		p1.Parent = workspace.Terrain
		
		local dist = (endPos - origin).Magnitude
		p1.Size = Vector3.new(0.3, 0.3, dist) -- Thicker
		p1.CFrame = CFrame.lookAt(origin, endPos) * CFrame.new(0, 0, -dist/2)
		
		-- Tween Fade
		TweenService:Create(p1, TweenInfo.new(0.25), { -- Longer duration
			Transparency = 1,
			Size = Vector3.new(0, 0, dist)
		}):Play()
		
		Debris:AddItem(p1, 0.25)
	end
end

--[[
    Overclock buff effect (Particles instead of Highlight)
]]
local function playOverclock(character, duration)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then return end
	
	local attachment = Instance.new("Attachment")
	attachment.Parent = root
	
	local particles = Instance.new("ParticleEmitter")
	particles.Color = ColorSequence.new(Color3.fromRGB(255, 100, 0), Color3.fromRGB(255, 50, 0))
	particles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 0)
	})
	particles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 1)
	})
	particles.Speed = NumberRange.new(2, 5)
	particles.Acceleration = Vector3.new(0, 5, 0) -- Rise up
	particles.Rate = 20
	particles.Lifetime = NumberRange.new(0.5, 1)
	particles.Parent = attachment
	
	Debris:AddItem(attachment, duration)
end

--[[
    Iron Will Shield Effect
]]
local function playIronWill(character, duration)
	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromRGB(100, 200, 255)
	highlight.OutlineColor = Color3.fromRGB(200, 255, 255)
	highlight.FillTransparency = 0.5
	highlight.OutlineTransparency = 0
	highlight.Parent = character
	
	Debris:AddItem(highlight, duration)
end

--[[
    Handle skill used event
]]
local function onSkillUsed(player, slot, skillData)
	SkillVFX:PlaySkillEffect(player, skillData)
end

function SkillVFX:PlaySkillEffect(player, skillData)
	print("[SkillVFX] Effect:", skillData.Name, "for", player.Name)
	local char = player.Character
	if not char then return end
	local root = char:FindFirstChild("HumanoidRootPart")
	
	if skillData.Name == "Seismic Slam" then
		if root then playSeismicSlam(root, skillData.Radius or 15) end
	elseif skillData.Name == "Blade Storm" then
		if root then playBladeStorm(root) end
	elseif skillData.Name == "Buckshot Blast" then
		if root then playBuckshotBlast(root) end
	elseif skillData.Name == "Overclock" then
		playOverclock(char, skillData.Duration or 6)
	elseif skillData.Name == "Iron Will" then
		playIronWill(char, skillData.Duration or 5)
	end
end

function SkillVFX:Init()
	print("[SkillVFX] Initialized")
end

function SkillVFX:Start()
	local usedRemote = Remotes:GetEvent("SkillUsed")
	if usedRemote then
		usedRemote.OnClientEvent:Connect(onSkillUsed)
	end
	print("[SkillVFX] Started")
end

return SkillVFX
