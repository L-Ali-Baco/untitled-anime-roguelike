--[[
    EnemyVFXController.luau
    Client-side controller for enemy visual effects.
    
    Listens to server events and plays VFX:
    - Enemy attack effects (when enemy attacks player)
    - Enemy spawn effects
    - Enemy death effects (ragdoll, fade out)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local EnemyVFXController = {}
EnemyVFXController.Name = "EnemyVFXController"

-- References to VFX modules (set in Init)
local DamageNumbers = nil
local ScreenShakeController = nil

-- Connections
local connections: { RBXScriptConnection } = {}

-- Track player health for damage numbers on actual hits
local lastPlayerHealth: number? = nil

-- Hitstun cooldown tracking to prevent double-application
-- Key: enemy Model, Value: last hitstun time
local hitstunCooldowns: { [Model]: number } = {}
local HITSTUN_COOLDOWN = 0.25 -- Minimum time between hitstun effects on same enemy

--[[
    Create attack warning indicator at enemy position
]]
local function createAttackIndicator(enemyModel: Model, targetPosition: Vector3)
	local enemyRoot = enemyModel:FindFirstChild("HumanoidRootPart")
		or enemyModel:FindFirstChild("Torso")
		or enemyModel.PrimaryPart

	if not enemyRoot then
		return
	end

	-- Create a red flash effect on the enemy to telegraph attack
	local highlight = Instance.new("Highlight")
	highlight.Adornee = enemyModel
	highlight.FillColor = Color3.fromRGB(255, 50, 50)
	highlight.FillTransparency = 0.7
	highlight.OutlineColor = Color3.fromRGB(255, 0, 0)
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = enemyModel

	-- Flash animation
	local flashTween = TweenService:Create(
		highlight,
		TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.InOut, 1, true),
		{ FillTransparency = 0.3 }
	)
	flashTween:Play()

	-- Cleanup after flash
	Debris:AddItem(highlight, 0.35)
end

--[[
    Create a ground slam effect
    Layered: Impact flash → Ground crack → Shockwave ring → Rock debris → Dust cloud
]]
local function playSlamEffect(position: Vector3, damage: number)
	local slamRadius = 18 -- Visual radius in studs

	-- Client-side raycast to find the actual ground (exclude enemies + characters)
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local excludeList = CollectionService:GetTagged("Enemy")
	-- Also exclude player characters
	for _, player in game:GetService("Players"):GetPlayers() do
		if player.Character then
			table.insert(excludeList, player.Character)
		end
	end
	rayParams.FilterDescendantsInstances = excludeList

	local rayOrigin = position + Vector3.new(0, 10, 0)
	local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -30, 0), rayParams)
	local groundPos = if rayResult then rayResult.Position + Vector3.new(0, 0.05, 0) else position

	-- === 1. IMPACT FLASH (hemisphere on the ground) ===
	local flash = Instance.new("Part")
	flash.Name = "SlamFlash"
	flash.Anchored = true
	flash.CanCollide = false
	flash.CanQuery = false
	flash.CanTouch = false
	flash.CastShadow = false
	flash.Shape = Enum.PartType.Ball
	flash.Material = Enum.Material.Neon
	flash.Color = Color3.fromRGB(255, 180, 80)
	flash.Transparency = 0.1
	flash.Size = Vector3.new(4, 4, 4)
	flash.Position = groundPos
	flash.Parent = workspace

	TweenService:Create(flash, TweenInfo.new(0.15, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(10, 6, 10), -- Wider than tall to hug the ground
		Transparency = 1,
	}):Play()
	Debris:AddItem(flash, 0.2)

	-- === 2. GROUND CRACK (dark flat disc flush with floor) ===
	local crack = Instance.new("Part")
	crack.Name = "SlamCrack"
	crack.Anchored = true
	crack.CanCollide = false
	crack.CanQuery = false
	crack.CanTouch = false
	crack.CastShadow = false
	crack.Shape = Enum.PartType.Cylinder
	crack.Material = Enum.Material.Slate
	crack.Color = Color3.fromRGB(30, 25, 20)
	crack.Transparency = 0.3
	crack.Size = Vector3.new(0.15, 1, 1)
	crack.CFrame = CFrame.new(groundPos) * CFrame.Angles(0, 0, math.rad(90))
	crack.Parent = workspace

	TweenService:Create(crack, TweenInfo.new(0.1, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.15, slamRadius * 1.2, slamRadius * 1.2),
	}):Play()

	task.delay(0.8, function()
		if crack.Parent then
			TweenService:Create(crack, TweenInfo.new(1.0, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
				Transparency = 1,
			}):Play()
			Debris:AddItem(crack, 1.1)
		end
	end)

	-- === 3. SHOCKWAVE RING (flush with ground) ===
	local ring = Instance.new("Part")
	ring.Name = "SlamRing"
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.Neon
	ring.Color = Color3.fromRGB(255, 120, 40)
	ring.Transparency = 0
	ring.Size = Vector3.new(1.5, 3, 3)
	ring.CFrame = CFrame.new(groundPos + Vector3.new(0, 0.2, 0)) * CFrame.Angles(0, 0, math.rad(90))
	ring.Parent = workspace

	TweenService:Create(ring, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(1.5, slamRadius * 2, slamRadius * 2),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.4)

	-- Second ring (delayed, slightly different color)
	task.delay(0.05, function()
		local ring2 = Instance.new("Part")
		ring2.Name = "SlamRing2"
		ring2.Anchored = true
		ring2.CanCollide = false
		ring2.CanQuery = false
		ring2.CanTouch = false
		ring2.CastShadow = false
		ring2.Shape = Enum.PartType.Cylinder
		ring2.Material = Enum.Material.Neon
		ring2.Color = Color3.fromRGB(255, 200, 100)
		ring2.Transparency = 0.3
		ring2.Size = Vector3.new(1, 2, 2)
		ring2.CFrame = CFrame.new(groundPos + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90))
		ring2.Parent = workspace

		TweenService:Create(ring2, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(1, slamRadius * 1.6, slamRadius * 1.6),
			Transparency = 1,
		}):Play()
		Debris:AddItem(ring2, 0.45)
	end)

	-- === 4. ROCK DEBRIS (erupt from ground at impact point) ===
	for _ = 1, 8 do
		local rockSize = math.random(15, 35) / 10
		local rock = Instance.new("Part")
		rock.Size = Vector3.new(rockSize, rockSize * 0.7, rockSize)
		rock.Anchored = false
		rock.CanCollide = true
		rock.CanQuery = false
		rock.CanTouch = false
		rock.CastShadow = false
		rock.Material = Enum.Material.Slate
		rock.Color = Color3.fromRGB(math.random(45, 75), math.random(40, 65), math.random(35, 55))
		local angle = math.random() * math.pi * 2
		local dist = math.random(1, 4)
		-- Spawn at ground level, not floating
		rock.CFrame = CFrame.new(groundPos + Vector3.new(math.cos(angle) * dist, 0.5, math.sin(angle) * dist))
			* CFrame.Angles(math.random() * math.pi, math.random() * math.pi, math.random() * math.pi)
		rock.Parent = workspace

		local launchDir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local upForce = rock:GetMass() * math.random(40, 70)
		local outForce = rock:GetMass() * math.random(15, 35)
		rock:ApplyImpulse(Vector3.new(launchDir.X * outForce, upForce, launchDir.Z * outForce))
		rock:ApplyAngularImpulse(Vector3.new(math.random(-5, 5), math.random(-5, 5), math.random(-5, 5)))

		task.delay(0.8, function()
			if rock.Parent then
				TweenService:Create(rock, TweenInfo.new(0.4), { Transparency = 1 }):Play()
				Debris:AddItem(rock, 0.5)
			end
		end)
	end

	-- === 5. DUST CLOUD (ground level) ===
	local dustAttach = Instance.new("Attachment")
	dustAttach.WorldPosition = groundPos
	dustAttach.Parent = workspace.Terrain

	-- Upward dust burst
	local dustUp = Instance.new("ParticleEmitter")
	dustUp.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(180, 160, 130)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 110, 100)),
	})
	dustUp.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 3),
		NumberSequenceKeypoint.new(0.3, 6),
		NumberSequenceKeypoint.new(1, 8),
	})
	dustUp.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.4, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	dustUp.Lifetime = NumberRange.new(0.6, 1.2)
	dustUp.Speed = NumberRange.new(15, 35)
	dustUp.SpreadAngle = Vector2.new(30, 30)
	dustUp.Drag = 4
	dustUp.Rate = 0
	dustUp.Rotation = NumberRange.new(0, 360)
	dustUp.RotSpeed = NumberRange.new(-60, 60)
	dustUp.Parent = dustAttach
	dustUp:Emit(25)

	-- Ground-spreading dust
	local dustGround = Instance.new("ParticleEmitter")
	dustGround.Color = ColorSequence.new(Color3.fromRGB(140, 130, 110))
	dustGround.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2),
		NumberSequenceKeypoint.new(0.5, 5),
		NumberSequenceKeypoint.new(1, 7),
	})
	dustGround.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(0.6, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	dustGround.Lifetime = NumberRange.new(0.8, 1.5)
	dustGround.Speed = NumberRange.new(10, 25)
	dustGround.SpreadAngle = Vector2.new(180, 10)
	dustGround.Drag = 6
	dustGround.Rate = 0
	dustGround.Rotation = NumberRange.new(0, 360)
	dustGround.RotSpeed = NumberRange.new(-30, 30)
	dustGround.Parent = dustAttach
	dustGround:Emit(20)

	Debris:AddItem(dustAttach, 2)

	-- === 6. SCREEN SHAKE for nearby player ===
	if ScreenShakeController then
		local Players = game:GetService("Players")
		local LocalPlayer = Players.LocalPlayer
		local character = LocalPlayer.Character
		if character then
			local root = character:FindFirstChild("HumanoidRootPart")
			if root then
				local dist = (root.Position - position).Magnitude
				if dist < 50 then
					local intensity = math.clamp(1 - (dist / 50), 0.2, 1)
					ScreenShakeController:Shake(intensity * 0.8, 0.25)
				end
			end
		end
	end
end

--[[
    Create a horizontal hammer swing effect
    Directional: uses enemy facing to sweep arc from right-to-left across body
    Low horizontal swing - VFX appears in front of the enemy near waist/knee height
    Layers: Sweep trail → Arc flash → Slash lines → Wind particles → Ground dust → Debris → Screen shake
]]
local function playSwingEffect(position: Vector3, damage: number, enemyModel: Model?)
	-- Get enemy facing direction for directional VFX
	local enemyRoot = nil
	local swingDirection = Vector3.new(1, 0, 0) -- Default right direction
	local forwardDir = Vector3.new(0, 0, -1)

	if enemyModel then
		enemyRoot = enemyModel:FindFirstChild("HumanoidRootPart")
			or enemyModel:FindFirstChild("Torso")
			or enemyModel.PrimaryPart
	end

	if enemyRoot then
		forwardDir = enemyRoot.CFrame.LookVector
		-- Swing goes from enemy's right to left (cross-body hammer sweep)
		swingDirection = enemyRoot.CFrame.RightVector
	end

	-- Low swing: position VFX near ground level, far out in front of the large enemy
	local swingCenter
	if enemyRoot then
		-- Low swing: -5 studs below root (near ground), 15 studs in front
		swingCenter = enemyRoot.Position + Vector3.new(0, -5, 0) + forwardDir * 15
	else
		-- Fallback: just above the hit position (which is on the ground)
		swingCenter = position + Vector3.new(0, 1, 0)
	end

	-- Client-side raycast to find the actual ground
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local excludeList = CollectionService:GetTagged("Enemy")
	for _, player in game:GetService("Players"):GetPlayers() do
		if player.Character then
			table.insert(excludeList, player.Character)
		end
	end
	rayParams.FilterDescendantsInstances = excludeList

	local rayOrigin = position + Vector3.new(0, 10, 0)
	local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -30, 0), rayParams)
	local groundPos = if rayResult then rayResult.Position + Vector3.new(0, 0.05, 0) else position

	-- === 1. HAMMER SWING ARC (smooth Trail ribbon) ===
	-- Uses Roblox Trail instance for a smooth, non-blocky swing slash
	local sweepRadius = 26
	local sweepDuration = 0.25
	local startAngle = math.rad(-90) -- Enemy's left
	local endAngle = math.rad(60) -- Enemy's right (shorter end)

	-- Pivot at enemy's low position
	local pivotPos = if enemyRoot then enemyRoot.Position + Vector3.new(0, -5, 0) else position

	-- Invisible part that carries the trail attachments along the arc
	local trailPart = Instance.new("Part")
	trailPart.Name = "SwingTrailCarrier"
	trailPart.Anchored = true
	trailPart.CanCollide = false
	trailPart.CanQuery = false
	trailPart.CanTouch = false
	trailPart.CastShadow = false
	trailPart.Transparency = 1
	trailPart.Size = Vector3.new(1, 1, 1)
	trailPart.Parent = workspace

	-- Two attachments define the trail's width (spaced apart = trail height)
	local attach0 = Instance.new("Attachment")
	attach0.Position = Vector3.new(0, 2, 0) -- Top edge of trail
	attach0.Parent = trailPart

	local attach1 = Instance.new("Attachment")
	attach1.Position = Vector3.new(0, -2, 0) -- Bottom edge of trail
	attach1.Parent = trailPart

	-- The Trail instance - creates a smooth ribbon as the part moves
	local trail = Instance.new("Trail")
	trail.Attachment0 = attach0
	trail.Attachment1 = attach1
	trail.Lifetime = 0.4 -- How long the trail ribbon stays visible
	trail.MinLength = 0.1
	trail.FaceCamera = true
	trail.LightEmission = 0.8 -- Glow effect
	trail.LightInfluence = 0
	trail.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 240, 150)), -- Bright white-yellow at leading edge
		ColorSequenceKeypoint.new(0.3, Color3.fromRGB(255, 180, 60)), -- Warm orange
		ColorSequenceKeypoint.new(0.7, Color3.fromRGB(230, 100, 20)), -- Deep orange
		ColorSequenceKeypoint.new(1, Color3.fromRGB(180, 50, 10)), -- Dark red at trailing edge
	})
	trail.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0), -- Solid at leading edge
		NumberSequenceKeypoint.new(0.5, 0.2),
		NumberSequenceKeypoint.new(0.8, 0.6),
		NumberSequenceKeypoint.new(1, 1), -- Fully faded at trailing edge
	})
	trail.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1), -- Full width at leading edge
		NumberSequenceKeypoint.new(0.5, 1.2), -- Slightly wider in middle
		NumberSequenceKeypoint.new(1, 0.3), -- Tapers at trailing edge
	})
	trail.Parent = trailPart

	-- Position the carrier at the start of the arc before enabling
	local startDir = forwardDir * math.cos(startAngle) + swingDirection * math.sin(startAngle)
	trailPart.Position = pivotPos + startDir * sweepRadius

	-- Animate the carrier part along the arc
	task.spawn(function()
		-- Let the trail attach first frame
		task.wait()

		local startTime = os.clock()
		while true do
			local elapsed = os.clock() - startTime
			local t = math.clamp(elapsed / sweepDuration, 0, 1)
			if t >= 1 then
				break
			end

			-- Easing: slow start, fast middle, slow end
			local eased
			if t < 0.12 then
				eased = (t / 0.12) * 0.03
			elseif t < 0.88 then
				local mid = (t - 0.12) / 0.76
				eased = 0.03 + mid * 0.94
			else
				local tail = (t - 0.88) / 0.12
				eased = 0.97 + tail * 0.03
			end

			local currentAngle = startAngle + (endAngle - startAngle) * eased
			local outDir = forwardDir * math.cos(currentAngle) + swingDirection * math.sin(currentAngle)
			trailPart.Position = pivotPos + outDir * sweepRadius

			task.wait()
		end

		-- Final position
		local endDir = forwardDir * math.cos(endAngle) + swingDirection * math.sin(endAngle)
		trailPart.Position = pivotPos + endDir * sweepRadius

		-- Disable trail so it stops drawing, then let existing trail fade naturally
		task.wait(0.05)
		trail.Enabled = false
	end)

	Debris:AddItem(trailPart, sweepDuration + trail.Lifetime + 0.2)

	-- === 4. WIND/FORCE PARTICLES (burst outward from the swing arc) ===
	local windAttach = Instance.new("Attachment")
	windAttach.WorldPosition = swingCenter
	windAttach.Parent = workspace.Terrain

	local windParticles = Instance.new("ParticleEmitter")
	windParticles.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 200, 120)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(200, 140, 60)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(140, 100, 40)),
	})
	windParticles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.5),
		NumberSequenceKeypoint.new(0.3, 2.5),
		NumberSequenceKeypoint.new(1, 4),
	})
	windParticles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.4, 0.4),
		NumberSequenceKeypoint.new(1, 1),
	})
	windParticles.Lifetime = NumberRange.new(0.2, 0.6)
	windParticles.Speed = NumberRange.new(15, 40)
	windParticles.SpreadAngle = Vector2.new(60, 30)
	windParticles.Drag = 4
	windParticles.Rate = 0
	windParticles.Rotation = NumberRange.new(0, 360)
	windParticles.RotSpeed = NumberRange.new(-80, 80)
	windParticles.Parent = windAttach
	windParticles:Emit(20)

	Debris:AddItem(windAttach, 1)

	-- === 5. GROUND DUST (kicked up along the sweep path) ===
	local dustAttach = Instance.new("Attachment")
	dustAttach.WorldPosition = groundPos
	dustAttach.Parent = workspace.Terrain

	local dust = Instance.new("ParticleEmitter")
	dust.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(180, 160, 130)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(120, 110, 95)),
	})
	dust.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2),
		NumberSequenceKeypoint.new(0.4, 4),
		NumberSequenceKeypoint.new(1, 6),
	})
	dust.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.5, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	dust.Lifetime = NumberRange.new(0.4, 1.0)
	dust.Speed = NumberRange.new(8, 25)
	dust.SpreadAngle = Vector2.new(160, 15)
	dust.Drag = 5
	dust.Rate = 0
	dust.Rotation = NumberRange.new(0, 360)
	dust.RotSpeed = NumberRange.new(-50, 50)
	dust.Parent = dustAttach
	dust:Emit(16)

	-- Second dust point offset along the swing direction
	local dustAttach2 = Instance.new("Attachment")
	dustAttach2.WorldPosition = groundPos + swingDirection * 5
	dustAttach2.Parent = workspace.Terrain

	local dust2 = dust:Clone()
	dust2.Parent = dustAttach2
	dust2:Emit(10)

	Debris:AddItem(dustAttach, 1.5)
	Debris:AddItem(dustAttach2, 1.5)

	-- === 6. SMALL DEBRIS (pebbles flung by the force) ===
	for _ = 1, 3 do
		local pebbleSize = math.random(5, 12) / 10
		local pebble = Instance.new("Part")
		pebble.Size = Vector3.new(pebbleSize, pebbleSize * 0.6, pebbleSize)
		pebble.Anchored = false
		pebble.CanCollide = true
		pebble.CanQuery = false
		pebble.CanTouch = false
		pebble.CastShadow = false
		pebble.Material = Enum.Material.Slate
		pebble.Color = Color3.fromRGB(math.random(50, 80), math.random(45, 70), math.random(40, 60))
		local angle = math.random() * math.pi * 2
		local dist = math.random(1, 3)
		pebble.CFrame = CFrame.new(groundPos + Vector3.new(math.cos(angle) * dist, 0.3, math.sin(angle) * dist))
			* CFrame.Angles(math.random() * math.pi, math.random() * math.pi, math.random() * math.pi)
		pebble.Parent = workspace

		-- Launch in the swing direction (left) with some upward force
		local launchDir = (-swingDirection + Vector3.new(0, 0.5, 0) + forwardDir * 0.3).Unit
		local upForce = pebble:GetMass() * math.random(25, 45)
		local outForce = pebble:GetMass() * math.random(10, 25)
		pebble:ApplyImpulse(Vector3.new(launchDir.X * outForce, upForce, launchDir.Z * outForce))
		pebble:ApplyAngularImpulse(Vector3.new(math.random(-3, 3), math.random(-3, 3), math.random(-3, 3)))

		task.delay(0.7, function()
			if pebble.Parent then
				TweenService:Create(pebble, TweenInfo.new(0.3), { Transparency = 1 }):Play()
				Debris:AddItem(pebble, 0.4)
			end
		end)
	end

	-- === 7. SCREEN SHAKE (medium intensity) ===
	if ScreenShakeController then
		local Players = game:GetService("Players")
		local LocalPlayer = Players.LocalPlayer
		local character = LocalPlayer.Character
		if character then
			local root = character:FindFirstChild("HumanoidRootPart")
			if root then
				local dist = (root.Position - position).Magnitude
				if dist < 45 then
					local intensity = math.clamp(1 - (dist / 45), 0.1, 0.8)
					ScreenShakeController:Shake(intensity * 0.6, 0.18)
				end
			end
		end
	end
end

--[[
    Handle enemy attack event
    Shows damage taken, screen shake, and slam VFX
]]
local function onEnemyAttack(data)
	-- data = { Enemy, Target, HitPosition, Damage, AttackType, IsSlam }

	local enemy = data.Enemy
	local target = data.Target
	local hitPosition = data.HitPosition
	local damage = data.Damage
	local attackType = data.AttackType

	-- Attack-specific VFX
	if hitPosition then
		if attackType == "Slam" or (not attackType and data.IsSlam) then
			playSlamEffect(hitPosition, damage or 15)
		elseif attackType == "Swing" then
			playSwingEffect(hitPosition, damage or 12, enemy)
		end
	end

	-- Create attack telegraph on enemy
	if enemy and target then
		createAttackIndicator(enemy, hitPosition)
	end

	-- NOTE: Damage numbers and hit screen shake are NOT shown here.
	-- This event fires BEFORE hit detection, so we don't know if the player
	-- was actually hit or dodged. Damage numbers should be driven by actual
	-- health changes on the Humanoid, not this event.
end

--[[
    Handle enemy death event
    Creates instant death effects - NO RAGDOLL to avoid blocking shots
    
    Death Effect: Smoke burst + rapid dissolve
    - Immediately disables raycasting so dead enemies don't block shots
    - Quick dissolve animation (0.3s)
    - Smoke particle burst at death position
]]
local function onEnemyDied(data)
	-- data = { Target, Killer, Position }

	local enemyModel = data.Target
	local position = data.Position

	if not enemyModel or not enemyModel.Parent then
		return
	end

	local rootPart = enemyModel:FindFirstChild("HumanoidRootPart")
		or enemyModel:FindFirstChild("Torso")
		or enemyModel.PrimaryPart

	local deathPosition = rootPart and rootPart.Position or position

	-- IMMEDIATELY disable all physics interactions
	-- This is critical to prevent dead enemies from blocking shots
	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			part.CanCollide = false
			part.CanQuery = false -- Don't block raycasts!
			part.CanTouch = false
			part.Anchored = true -- Freeze in place (no ragdoll)
		end
	end

	-- === DEATH VFX: Smoke Burst ===
	local smokeAttachment = Instance.new("Attachment")
	smokeAttachment.WorldPosition = deathPosition
	smokeAttachment.Parent = workspace.Terrain

	-- Smoke particles
	local smokeParticles = Instance.new("ParticleEmitter")
	smokeParticles.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(80, 80, 80)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(40, 40, 40)),
	})
	smokeParticles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.3, 3),
		NumberSequenceKeypoint.new(1, 5),
	})
	smokeParticles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.2),
		NumberSequenceKeypoint.new(0.5, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	smokeParticles.Lifetime = NumberRange.new(0.4, 0.8)
	smokeParticles.Speed = NumberRange.new(5, 15)
	smokeParticles.SpreadAngle = Vector2.new(180, 180)
	smokeParticles.Rate = 0
	smokeParticles.Parent = smokeAttachment

	-- Emit smoke burst
	smokeParticles:Emit(20)

	-- Cleanup smoke after particles finish
	Debris:AddItem(smokeAttachment, 1)

	-- === DEATH VFX: Rapid Dissolve ===
	-- Quick fade (0.3s) so enemy disappears fast
	local dissolveDuration = 0.3

	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			-- Shrink and fade simultaneously
			local dissolveTween = TweenService:Create(
				part,
				TweenInfo.new(dissolveDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{
					Transparency = 1,
					Size = part.Size * 0.1, -- Shrink to 10%
				}
			)
			dissolveTween:Play()
		elseif part:IsA("Decal") or part:IsA("Texture") then
			local fadeTween = TweenService:Create(
				part,
				TweenInfo.new(dissolveDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Transparency = 1 }
			)
			fadeTween:Play()
		end
	end

	-- NOTE: We do NOT destroy the model here!
	-- The server owns the model and will destroy it via EnemyService.
	-- Client only handles visual effects (fade/shrink).
	-- Destroying here would cause replication issues.
end

--[[
    Handle damage blocked event (player dodged with I-frames)
    Shows "DODGE" text and visual feedback
]]
local function onDamageBlocked(data)
	-- data = { Enemy, Position, DamageBlocked }

	local position = data.Position
	local damageBlocked = data.DamageBlocked

	-- Show "DODGE" damage number
	if DamageNumbers then
		DamageNumbers:SpawnText(position + Vector3.new(0, 2, 0), "DODGE", "Dodge")
	end

	-- White flash on screen edge (optional subtle feedback)
	-- Could be implemented via ScreenEffects module

	-- Brief slow-mo feel (optional - tiny hitstop for satisfaction)
	-- This would call HitstopController if we want that feel
end

--[[
    Handle enemy spawn event
    Creates spawn effects
]]
local function onEnemySpawned(data)
	-- data = { Enemy, Position, EnemyType }

	local enemyModel = data.Enemy
	local position = data.Position

	if not enemyModel then
		return
	end

	-- Spawn dust/smoke effect
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = position
	attachment.Parent = workspace.Terrain

	local particles = Instance.new("ParticleEmitter")
	particles.Color = ColorSequence.new(Color3.fromRGB(100, 100, 100))
	particles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.5, 2),
		NumberSequenceKeypoint.new(1, 0),
	})
	particles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.3),
		NumberSequenceKeypoint.new(1, 1),
	})
	particles.Lifetime = NumberRange.new(0.5, 1)
	particles.Speed = NumberRange.new(5, 10)
	particles.SpreadAngle = Vector2.new(180, 180)
	particles.Rate = 0
	particles.Parent = attachment

	particles:Emit(15)

	Debris:AddItem(attachment, 1.5)

	-- Scale-in effect on enemy
	for _, part in enemyModel:GetDescendants() do
		if part:IsA("BasePart") then
			local originalSize = part.Size
			part.Size = originalSize * 0.1

			local scaleTween = TweenService:Create(
				part,
				TweenInfo.new(0.3, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Size = originalSize }
			)
			scaleTween:Play()
		end
	end
end

--[[
    Handle enemy state change event
    Plays visual effects based on new state (e.g. hitstun flinch)
]]
local function onEnemyStateChanged(enemyModel: Model, newState: string)
	if not enemyModel or not enemyModel.Parent then
		return
	end

	local rootPart = enemyModel:FindFirstChild("HumanoidRootPart")
		or enemyModel:FindFirstChild("Torso")
		or enemyModel.PrimaryPart

	if not rootPart then
		return
	end

	if newState == "Hitstun" then
		EnemyVFXController:PlayHitstun(enemyModel)
	end
end

--[[
    Play hitstun VFX immediately (Public for client prediction)
    
    IMPORTANT: This function uses VISUAL-ONLY feedback (Highlights, particles).
    It does NOT manipulate the enemy's CFrame or Size, which would conflict with 
    Humanoid physics or attached UI elements like health bars.
    
    Effects:
    - Intense white->red highlight flash
    - Impact particles burst
]]
function EnemyVFXController:PlayHitstun(enemyModel: Model)
	if not enemyModel or not enemyModel.Parent then
		return
	end

	-- Cooldown check to prevent double-application from prediction + server broadcast
	local now = os.clock()
	local lastHitstun = hitstunCooldowns[enemyModel]
	if lastHitstun and (now - lastHitstun) < HITSTUN_COOLDOWN then
		return -- Already playing hitstun effect, skip
	end
	hitstunCooldowns[enemyModel] = now

	local rootPart = enemyModel:FindFirstChild("HumanoidRootPart")
		or enemyModel:FindFirstChild("Torso")
		or enemyModel.PrimaryPart

	if not rootPart then
		return
	end

	-- === EFFECT 1: INTENSE HIGHLIGHT FLASH ===
	-- Destroy any existing hitstun highlight
	local existingHighlight = enemyModel:FindFirstChild("HitstunHighlight")
	if existingHighlight then
		existingHighlight:Destroy()
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "HitstunHighlight"
	highlight.Adornee = enemyModel
	-- Start with bright WHITE for maximum impact
	highlight.FillColor = Color3.fromRGB(255, 255, 255)
	highlight.FillTransparency = 0 -- Fully opaque!
	highlight.OutlineColor = Color3.fromRGB(255, 100, 100)
	highlight.OutlineTransparency = 0
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	highlight.Parent = enemyModel

	-- Animate highlight: white -> red -> fade out
	task.spawn(function()
		-- Hold white flash briefly
		task.wait(0.05)
		if not highlight or not highlight.Parent then
			return
		end

		-- Transition to red
		highlight.FillColor = Color3.fromRGB(255, 50, 50)
		highlight.FillTransparency = 0.2

		task.wait(0.05)
		if not highlight or not highlight.Parent then
			return
		end

		-- Fade out
		local fadeSteps = 4
		for i = 1, fadeSteps do
			task.wait(0.04)
			if not highlight or not highlight.Parent then
				return
			end

			local alpha = i / fadeSteps
			highlight.FillTransparency = 0.2 + (0.8 * alpha)
			highlight.OutlineTransparency = alpha
		end

		-- Cleanup
		if highlight and highlight.Parent then
			highlight:Destroy()
		end
	end)

	-- === EFFECT 2: IMPACT PARTICLES ===
	-- NOTE: Size pulse removed - it was causing issues with attached health bars
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = rootPart.Position
	attachment.Parent = workspace.Terrain

	-- Red/orange impact sparks
	local impactParticles = Instance.new("ParticleEmitter")
	impactParticles.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, Color3.fromRGB(255, 200, 100)),
		ColorSequenceKeypoint.new(0.5, Color3.fromRGB(255, 100, 50)),
		ColorSequenceKeypoint.new(1, Color3.fromRGB(200, 50, 50)),
	})
	impactParticles.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.8),
		NumberSequenceKeypoint.new(0.3, 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	impactParticles.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.8, 0.5),
		NumberSequenceKeypoint.new(1, 1),
	})
	impactParticles.Lifetime = NumberRange.new(0.15, 0.3)
	impactParticles.Speed = NumberRange.new(10, 25)
	impactParticles.SpreadAngle = Vector2.new(180, 180)
	impactParticles.Rate = 0
	impactParticles.Parent = attachment

	-- Emit burst
	impactParticles:Emit(12)

	-- Cleanup particles
	Debris:AddItem(attachment, 0.5)

	-- Cleanup cooldown entry after a delay
	task.delay(1, function()
		if hitstunCooldowns[enemyModel] == now then
			hitstunCooldowns[enemyModel] = nil
		end
	end)
end

--[[
    Initialize the controller
]]
function EnemyVFXController:Init()
	-- Get VFX modules
	local function tryRequire(path)
		local success, result = pcall(function()
			return require(path)
		end)
		return success and result or nil
	end

	DamageNumbers = tryRequire(script.Parent.Parent.VFX.DamageNumbers)
	ScreenShakeController = tryRequire(script.Parent.Parent.VFX.ScreenShakeController)

	print("[EnemyVFXController] Initialized")
end

--[[
    Start the controller
]]
function EnemyVFXController:Start()
	-- Connect to remote events
	local enemyAttackRemote = Remotes:GetEvent("EnemyAttack")
	if enemyAttackRemote then
		table.insert(connections, enemyAttackRemote.OnClientEvent:Connect(onEnemyAttack))
	end

	local enemyDiedRemote = Remotes:GetEvent("EnemyDied")
	if enemyDiedRemote then
		table.insert(connections, enemyDiedRemote.OnClientEvent:Connect(onEnemyDied))
	end

	local enemySpawnedRemote = Remotes:GetEvent("EnemySpawned")
	if enemySpawnedRemote then
		table.insert(connections, enemySpawnedRemote.OnClientEvent:Connect(onEnemySpawned))
	end

	local damageBlockedRemote = Remotes:GetEvent("DamageBlocked")
	if damageBlockedRemote then
		table.insert(connections, damageBlockedRemote.OnClientEvent:Connect(onDamageBlocked))
	end

	local stateRemote = Remotes:GetEvent("EnemyStateChanged")
	if stateRemote then
		table.insert(connections, stateRemote.OnClientEvent:Connect(onEnemyStateChanged))
	end

	-- Listen for player health changes to show damage numbers on actual hits
	local Players = game:GetService("Players")
	local LocalPlayer = Players.LocalPlayer

	local function onCharacterAdded(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10) :: Humanoid?
		if not humanoid then
			return
		end

		lastPlayerHealth = humanoid.Health

		local healthConn = humanoid.HealthChanged:Connect(function(newHealth: number)
			local oldHealth = lastPlayerHealth or humanoid.MaxHealth
			lastPlayerHealth = newHealth

			local delta = oldHealth - newHealth
			if delta > 0 then
				-- Player took damage — show damage number and screen shake
				if DamageNumbers then
					DamageNumbers:SpawnOnCharacter(character, delta, "Normal")
				end
				if ScreenShakeController then
					local intensity = math.clamp(delta / 30, 0.15, 0.6)
					ScreenShakeController:Shake(intensity, 0.15)
				end
			end
		end)
		table.insert(connections, healthConn)
	end

	if LocalPlayer.Character then
		task.spawn(onCharacterAdded, LocalPlayer.Character)
	end
	table.insert(connections, LocalPlayer.CharacterAdded:Connect(onCharacterAdded))

	print("[EnemyVFXController] Started")
end

--[[
    Cleanup
]]
function EnemyVFXController:Destroy()
	for _, connection in connections do
		connection:Disconnect()
	end
	table.clear(connections)
end

return EnemyVFXController
