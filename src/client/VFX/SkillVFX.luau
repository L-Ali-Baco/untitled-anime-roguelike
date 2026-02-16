--[[
    SkillVFX.luau
    Handles visual effects for character skills.
    
    Biker King VFX use the same flipbook fire textures as FlamethrowerVFX
    for visual cohesion across all abilities.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local SkillVFX = {}

-- ═══════════════════════════════════════════════════════════════
-- SHARED FIRE CONSTANTS — Same palette + textures as FlamethrowerVFX
-- ═══════════════════════════════════════════════════════════════

local TEX_FIRE_A = "rbxassetid://13528076463" -- 4x4
local TEX_DETAIL = "rbxassetid://10768424377" -- 8x8
local TEX_FIRE_B = "rbxassetid://9754671071" -- 4x4

local WHITE_HOT = Color3.fromRGB(255, 250, 215)
local YELLOW = Color3.fromRGB(255, 215, 50)
local AMBER = Color3.fromRGB(255, 165, 30)
local ORANGE = Color3.fromRGB(240, 105, 15)
local CRIMSON = Color3.fromRGB(195, 45, 20)
local MAROON = Color3.fromRGB(90, 20, 10)

local function applyFlipbook(e: ParticleEmitter, layout: Enum.ParticleFlipbookLayout)
	e.FlipbookLayout = layout
	e.FlipbookMode = Enum.ParticleFlipbookMode.OneShot
	e.FlipbookFramerate = NumberRange.new(22, 28)
end

-- ═══════════════════════════════════════════════════════════════
-- VANGUARD SKILLS (unchanged)
-- ═══════════════════════════════════════════════════════════════

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
		Transparency = 1,
	})
	tween:Play()

	Debris:AddItem(ring, 0.5)

	-- Ground Cracks (Placeholder: Blocks)
	for _ = 1, 5 do
		local rock = Instance.new("Part")
		rock.Size = Vector3.new(2, 2, 2)
		rock.Anchored = true
		rock.CanCollide = false
		rock.Material = Enum.Material.Slate
		rock.Color = Color3.fromRGB(50, 50, 50)
		rock.Position = position + Vector3.new(math.random(-5, 5), -1, math.random(-5, 5))
		rock.Orientation = Vector3.new(math.random(0, 360), math.random(0, 360), math.random(0, 360))
		rock.Parent = workspace.Terrain

		TweenService:Create(rock, TweenInfo.new(0.3), {
			Position = rock.Position + Vector3.new(0, 3, 0),
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
		for _ = 1, hitCount do
			if not rootPart or not rootPart.Parent then
				break
			end

			local slash = Instance.new("Part")
			slash.Size = Vector3.new(8, 0.5, 8)
			slash.Anchored = true
			slash.CanCollide = false
			slash.Material = Enum.Material.Neon
			slash.Color = Color3.fromRGB(100, 200, 255)

			-- Random offset in front
			local offset = CFrame.new(0, 0, -5) * CFrame.Angles(0, math.rad(math.random(-30, 30)), 0)
			slash.CFrame = rootPart.CFrame
				* offset
				* CFrame.Angles(math.rad(math.random(-15, 15)), 0, math.rad(math.random(-180, 180)))
			slash.Parent = workspace.Terrain

			TweenService:Create(slash, TweenInfo.new(0.2), {
				Transparency = 1,
				Size = Vector3.new(12, 0.5, 12),
			}):Play()

			Debris:AddItem(slash, 0.2)
			task.wait(interval)
		end
	end)
end

-- ═══════════════════════════════════════════════════════════════
-- GUNSLINGER SKILLS (unchanged)
-- ═══════════════════════════════════════════════════════════════

--[[
    Create shotgun tracers
]]
local function playBuckshotBlast(rootPart)
	local origin = rootPart.Position
	local lookDir = rootPart.CFrame.LookVector

	for _ = 1, 5 do
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
		p1.CFrame = CFrame.lookAt(origin, endPos) * CFrame.new(0, 0, -dist / 2)

		-- Tween Fade
		TweenService:Create(p1, TweenInfo.new(0.25), { -- Longer duration
			Transparency = 1,
			Size = Vector3.new(0, 0, dist),
		}):Play()

		Debris:AddItem(p1, 0.25)
	end
end

--[[
    Overclock buff effect (Particles instead of Highlight)
]]
local function playOverclock(character, duration)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local attachment = Instance.new("Attachment")
	attachment.Parent = root

	local particles = Instance.new("ParticleEmitter")
	particles.Color = ColorSequence.new(Color3.fromRGB(255, 100, 0), Color3.fromRGB(255, 50, 0))
	particles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	particles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(1, 1),
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

-- ═══════════════════════════════════════════════════════════════
-- BIKER KING SKILLS — Flipbook fire matching M1 flamethrower
-- ═══════════════════════════════════════════════════════════════

--[[
    Inferno Ramp: Intense fire aura wrapping the character
    2-layer flipbook emitter on body + pulsing PointLight
]]
local function playInfernoRamp(character, duration)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local att = Instance.new("Attachment")
	att.Name = "InfernoAura"
	att.Parent = root

	-- Layer 1: Core fire aura (rising from body)
	local core = Instance.new("ParticleEmitter")
	core.Name = "InfernoCore"
	core.Texture = TEX_FIRE_A
	applyFlipbook(core, Enum.ParticleFlipbookLayout.Grid4x4)
	core.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, WHITE_HOT),
		ColorSequenceKeypoint.new(0.2, YELLOW),
		ColorSequenceKeypoint.new(0.5, AMBER),
		ColorSequenceKeypoint.new(1, ORANGE),
	})
	core.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(0.3, 2.0),
		NumberSequenceKeypoint.new(0.7, 2.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	core.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.2, 0),
		NumberSequenceKeypoint.new(0.6, 0.1),
		NumberSequenceKeypoint.new(1, 1),
	})
	core.LightEmission = 1
	core.LightInfluence = 0
	core.Speed = NumberRange.new(4, 10)
	core.Acceleration = Vector3.new(0, 12, 0) -- Rise up
	core.Rate = 45
	core.Lifetime = NumberRange.new(0.4, 0.7)
	core.SpreadAngle = Vector2.new(30, 30)
	core.Drag = 1
	core.Rotation = NumberRange.new(0, 360)
	core.RotSpeed = NumberRange.new(-120, 120)
	core.ZOffset = 1
	core.Parent = att

	-- Layer 2: Outer smoky fire
	local outer = Instance.new("ParticleEmitter")
	outer.Name = "InfernoOuter"
	outer.Texture = TEX_FIRE_B
	applyFlipbook(outer, Enum.ParticleFlipbookLayout.Grid4x4)
	outer.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, AMBER),
		ColorSequenceKeypoint.new(0.3, ORANGE),
		ColorSequenceKeypoint.new(0.6, CRIMSON),
		ColorSequenceKeypoint.new(1, MAROON),
	})
	outer.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.2),
		NumberSequenceKeypoint.new(0.3, 3.0),
		NumberSequenceKeypoint.new(0.7, 3.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	outer.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.4),
		NumberSequenceKeypoint.new(0.15, 0.1),
		NumberSequenceKeypoint.new(0.6, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	outer.LightEmission = 0.6
	outer.LightInfluence = 0
	outer.Speed = NumberRange.new(3, 7)
	outer.Acceleration = Vector3.new(0, 8, 0)
	outer.Rate = 30
	outer.Lifetime = NumberRange.new(0.5, 0.8)
	outer.SpreadAngle = Vector2.new(40, 40)
	outer.Drag = 0.8
	outer.Rotation = NumberRange.new(0, 360)
	outer.RotSpeed = NumberRange.new(-150, 150)
	outer.ZOffset = 0
	outer.Parent = att

	-- Point Light for glow
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 155, 45)
	light.Brightness = 4
	light.Range = 25
	light.Parent = att

	-- Fire highlight glow on character
	local highlight = Instance.new("Highlight")
	highlight.FillColor = Color3.fromRGB(255, 100, 0)
	highlight.OutlineColor = Color3.fromRGB(255, 200, 50)
	highlight.FillTransparency = 0.7
	highlight.OutlineTransparency = 0.3
	highlight.Parent = character

	Debris:AddItem(att, duration)
	Debris:AddItem(highlight, duration)
end

--[[
    Flame Circle: Expanding fire ring with erupting flame pillars
    Ring Part + radial flipbook fire emitters + pulsing light
]]
local function playFlameCircle(rootPart, radius, duration)
	local position = rootPart.Position - Vector3.new(0, 2, 0)
	local tickRate = 0.5
	local ticks = math.floor(duration / tickRate)

	-- Neon fire ring (expanding)
	local ring = Instance.new("Part")
	ring.Name = "FlameCircle"
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 120, 20)
	ring.Transparency = 0.3
	ring.Size = Vector3.new(0.5, 2, 2)
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = workspace.Terrain

	-- Expand ring
	TweenService:Create(ring, TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.5, radius * 2, radius * 2),
	}):Play()

	-- Erupting fire at ring edge points
	local fireAttachments = {}
	local numPoints = 8
	for i = 1, numPoints do
		local angle = (i / numPoints) * math.pi * 2
		local edgePos = position + Vector3.new(math.cos(angle) * radius * 0.7, 0, math.sin(angle) * radius * 0.7)

		local att = Instance.new("Attachment")
		att.WorldPosition = edgePos
		att.Parent = workspace.Terrain

		-- Fire eruption emitter (flipbook)
		local fire = Instance.new("ParticleEmitter")
		fire.Name = "CircleFire"
		fire.Texture = TEX_FIRE_A
		applyFlipbook(fire, Enum.ParticleFlipbookLayout.Grid4x4)
		fire.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, WHITE_HOT),
			ColorSequenceKeypoint.new(0.2, YELLOW),
			ColorSequenceKeypoint.new(0.5, ORANGE),
			ColorSequenceKeypoint.new(1, CRIMSON),
		})
		fire.Size = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.5),
			NumberSequenceKeypoint.new(0.2, 2.0),
			NumberSequenceKeypoint.new(0.6, 3.0),
			NumberSequenceKeypoint.new(1, 0),
		})
		fire.Transparency = NumberSequence.new({
			NumberSequenceKeypoint.new(0, 0.2),
			NumberSequenceKeypoint.new(0.15, 0),
			NumberSequenceKeypoint.new(0.6, 0.1),
			NumberSequenceKeypoint.new(1, 1),
		})
		fire.LightEmission = 1
		fire.LightInfluence = 0
		fire.Speed = NumberRange.new(6, 14)
		fire.Acceleration = Vector3.new(0, 15, 0) -- Rise up like fire pillars
		fire.Rate = 25
		fire.Lifetime = NumberRange.new(0.4, 0.7)
		fire.SpreadAngle = Vector2.new(15, 15)
		fire.Drag = 1
		fire.Rotation = NumberRange.new(0, 360)
		fire.RotSpeed = NumberRange.new(-90, 90)
		fire.Parent = att

		table.insert(fireAttachments, att)
	end

	-- Central light
	local lightAtt = Instance.new("Attachment")
	lightAtt.WorldPosition = position
	lightAtt.Parent = workspace.Terrain
	local light = Instance.new("PointLight")
	light.Color = Color3.fromRGB(255, 120, 25)
	light.Brightness = 5
	light.Range = radius + 10
	light.Parent = lightAtt
	table.insert(fireAttachments, lightAtt)

	-- Pulse the ring opacity
	task.spawn(function()
		for _ = 1, ticks do
			if not ring or not ring.Parent then
				break
			end
			TweenService:Create(ring, TweenInfo.new(0.15), { Transparency = 0.1, Color = YELLOW }):Play()
			task.wait(0.15)
			TweenService:Create(ring, TweenInfo.new(0.15), { Transparency = 0.4, Color = ORANGE }):Play()
			task.wait(tickRate - 0.15)
		end
	end)

	-- Cleanup
	task.delay(duration, function()
		if ring and ring.Parent then
			TweenService:Create(ring, TweenInfo.new(0.3), { Transparency = 1 }):Play()
		end
		for _, att in fireAttachments do
			for _, child in att:GetChildren() do
				if child:IsA("ParticleEmitter") then
					child.Enabled = false
				end
			end
		end
	end)

	Debris:AddItem(ring, duration + 0.8)
	for _, att in fireAttachments do
		Debris:AddItem(att, duration + 0.8)
	end
end

--[[
    Meteor Stomp: Fire trail during launch + fire shockwave on impact
    2-layer flipbook trail + neon ring + burst on landing
]]
local function playMeteorStomp(rootPart)
	if not rootPart then
		return
	end

	-- Fire trail while airborne (2-layer, attached to body)
	local trailAtt = Instance.new("Attachment")
	trailAtt.Name = "MeteorTrail"
	trailAtt.Position = Vector3.new(0, -1, 0) -- Below feet
	trailAtt.Parent = rootPart

	-- Trail core (flipbook)
	local trailCore = Instance.new("ParticleEmitter")
	trailCore.Name = "TrailCore"
	trailCore.Texture = TEX_FIRE_A
	applyFlipbook(trailCore, Enum.ParticleFlipbookLayout.Grid4x4)
	trailCore.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, WHITE_HOT),
		ColorSequenceKeypoint.new(0.3, YELLOW),
		ColorSequenceKeypoint.new(0.6, AMBER),
		ColorSequenceKeypoint.new(1, ORANGE),
	})
	trailCore.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.0),
		NumberSequenceKeypoint.new(0.3, 2.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	trailCore.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.5, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	trailCore.LightEmission = 1
	trailCore.LightInfluence = 0
	trailCore.Speed = NumberRange.new(2, 5)
	trailCore.Acceleration = Vector3.new(0, -8, 0) -- Trail downward
	trailCore.Rate = 50
	trailCore.Lifetime = NumberRange.new(0.3, 0.5)
	trailCore.SpreadAngle = Vector2.new(25, 25)
	trailCore.Drag = 2
	trailCore.Rotation = NumberRange.new(0, 360)
	trailCore.RotSpeed = NumberRange.new(-120, 120)
	trailCore.ZOffset = 1
	trailCore.Parent = trailAtt

	-- Trail outer (detail layer)
	local trailOuter = Instance.new("ParticleEmitter")
	trailOuter.Name = "TrailOuter"
	trailOuter.Texture = TEX_DETAIL
	applyFlipbook(trailOuter, Enum.ParticleFlipbookLayout.Grid8x8)
	trailOuter.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, ORANGE),
		ColorSequenceKeypoint.new(0.4, CRIMSON),
		ColorSequenceKeypoint.new(1, MAROON),
	})
	trailOuter.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1.5),
		NumberSequenceKeypoint.new(0.4, 3.0),
		NumberSequenceKeypoint.new(1, 0),
	})
	trailOuter.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.5, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	trailOuter.LightEmission = 0.4
	trailOuter.LightInfluence = 0
	trailOuter.Speed = NumberRange.new(1, 4)
	trailOuter.Acceleration = Vector3.new(0, -5, 0)
	trailOuter.Rate = 30
	trailOuter.Lifetime = NumberRange.new(0.4, 0.6)
	trailOuter.SpreadAngle = Vector2.new(35, 35)
	trailOuter.Drag = 1.5
	trailOuter.Rotation = NumberRange.new(0, 360)
	trailOuter.RotSpeed = NumberRange.new(-150, 150)
	trailOuter.ZOffset = 0
	trailOuter.Parent = trailAtt

	-- Trail light
	local trailLight = Instance.new("PointLight")
	trailLight.Color = Color3.fromRGB(255, 140, 35)
	trailLight.Brightness = 3
	trailLight.Range = 20
	trailLight.Parent = trailAtt

	Debris:AddItem(trailAtt, 4)

	-- Monitor for landing → fire shockwave impact
	task.delay(0.4, function()
		task.spawn(function()
			local checks = 0
			while checks < 80 do -- Up to 4 seconds
				checks += 1
				if not rootPart or not rootPart.Parent then
					break
				end

				if rootPart.AssemblyLinearVelocity.Y > -2 and checks > 6 then
					-- LANDED! Spawn fire shockwave
					local pos = rootPart.Position - Vector3.new(0, 2, 0)

					-- Neon impact ring
					local ring = Instance.new("Part")
					ring.Name = "MeteorRing"
					ring.Anchored = true
					ring.CanCollide = false
					ring.CanQuery = false
					ring.CanTouch = false
					ring.CastShadow = false
					ring.Shape = Enum.PartType.Cylinder
					ring.Material = Enum.Material.Neon
					ring.Color = Color3.fromRGB(255, 120, 15)
					ring.Size = Vector3.new(0.8, 3, 3)
					ring.CFrame = CFrame.new(pos) * CFrame.Angles(0, 0, math.rad(90))
					ring.Parent = workspace.Terrain

					TweenService:Create(ring, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
						Size = Vector3.new(0.8, 28, 28),
						Transparency = 1,
					}):Play()
					Debris:AddItem(ring, 0.5)

					-- Fire burst (flipbook particles)
					local burstAtt = Instance.new("Attachment")
					burstAtt.WorldPosition = pos
					burstAtt.Parent = workspace.Terrain

					local burst = Instance.new("ParticleEmitter")
					burst.Texture = TEX_FIRE_A
					applyFlipbook(burst, Enum.ParticleFlipbookLayout.Grid4x4)
					burst.Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, WHITE_HOT),
						ColorSequenceKeypoint.new(0.2, YELLOW),
						ColorSequenceKeypoint.new(0.5, ORANGE),
						ColorSequenceKeypoint.new(1, CRIMSON),
					})
					burst.Size = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 1.0),
						NumberSequenceKeypoint.new(0.3, 3.5),
						NumberSequenceKeypoint.new(1, 0),
					})
					burst.Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0),
						NumberSequenceKeypoint.new(0.4, 0.1),
						NumberSequenceKeypoint.new(1, 1),
					})
					burst.LightEmission = 1
					burst.LightInfluence = 0
					burst.Speed = NumberRange.new(12, 30)
					burst.Acceleration = Vector3.new(0, 20, 0)
					burst.Lifetime = NumberRange.new(0.3, 0.6)
					burst.SpreadAngle = Vector2.new(70, 70)
					burst.Drag = 3
					burst.Rate = 0
					burst.Rotation = NumberRange.new(0, 360)
					burst.RotSpeed = NumberRange.new(-200, 200)
					burst.Parent = burstAtt
					burst:Emit(35)

					-- Outer ember detail
					local embers = Instance.new("ParticleEmitter")
					embers.Texture = TEX_DETAIL
					applyFlipbook(embers, Enum.ParticleFlipbookLayout.Grid8x8)
					embers.Color = ColorSequence.new({
						ColorSequenceKeypoint.new(0, ORANGE),
						ColorSequenceKeypoint.new(0.5, CRIMSON),
						ColorSequenceKeypoint.new(1, MAROON),
					})
					embers.Size = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0.6),
						NumberSequenceKeypoint.new(0.4, 2.0),
						NumberSequenceKeypoint.new(1, 0),
					})
					embers.Transparency = NumberSequence.new({
						NumberSequenceKeypoint.new(0, 0.2),
						NumberSequenceKeypoint.new(0.5, 0.4),
						NumberSequenceKeypoint.new(1, 1),
					})
					embers.LightEmission = 0.4
					embers.LightInfluence = 0
					embers.Speed = NumberRange.new(8, 20)
					embers.Lifetime = NumberRange.new(0.4, 0.7)
					embers.SpreadAngle = Vector2.new(80, 80)
					embers.Drag = 2
					embers.Rate = 0
					embers.Rotation = NumberRange.new(0, 360)
					embers.RotSpeed = NumberRange.new(-180, 180)
					embers.Parent = burstAtt
					embers:Emit(20)

					-- Impact flash
					local flash = Instance.new("PointLight")
					flash.Color = Color3.fromRGB(255, 140, 35)
					flash.Brightness = 6
					flash.Range = 30
					flash.Parent = burstAtt
					TweenService:Create(flash, TweenInfo.new(0.25), { Brightness = 0 }):Play()

					Debris:AddItem(burstAtt, 1.0)
					break
				end

				task.wait(0.05)
			end
		end)
	end)
end

-- ═══════════════════════════════════════════════════════════════
-- VFX DISPATCH
-- ═══════════════════════════════════════════════════════════════

--[[
    Handle skill used event
]]
local function onSkillUsed(player, _slot, skillData)
	SkillVFX:PlaySkillEffect(player, skillData)
end

function SkillVFX:PlaySkillEffect(player, skillData)
	print("[SkillVFX] Effect:", skillData.Name, "for", player.Name)
	local char = player.Character
	if not char then
		return
	end
	local root = char:FindFirstChild("HumanoidRootPart")

	if skillData.Name == "Seismic Slam" then
		if root then
			playSeismicSlam(root, skillData.Radius or 15)
		end
	elseif skillData.Name == "Blade Storm" then
		if root then
			playBladeStorm(root)
		end
	elseif skillData.Name == "Buckshot Blast" then
		if root then
			playBuckshotBlast(root)
		end
	elseif skillData.Name == "Overclock" then
		playOverclock(char, skillData.Duration or 6)
	elseif skillData.Name == "Iron Will" then
		playIronWill(char, skillData.Duration or 5)
	elseif skillData.Name == "Inferno Ramp" then
		playInfernoRamp(char, skillData.Duration or 5)
	elseif skillData.Name == "Flame Circle" then
		if root then
			playFlameCircle(root, skillData.Radius or 18, skillData.Duration or 3)
		end
	elseif skillData.Name == "Meteor Stomp" then
		if root then
			playMeteorStomp(root)
		end
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
