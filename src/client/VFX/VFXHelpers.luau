--[[
    VFXHelpers.luau
    Reusable utility functions for creating VFX parts, particles, and effects.
    Eliminates repeated boilerplate across VFX modules.
]]

local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")

local VFXHelpers = {}

--[[
    Create a standard VFX part with common properties pre-set.
    All VFX parts are anchored, non-collidable, non-queryable, no shadows.

    @param props Table with optional overrides:
        Name: string, Shape: Enum.PartType, Material: Enum.Material,
        Color: Color3, Transparency: number, Size: Vector3,
        Position: Vector3, CFrame: CFrame, Parent: Instance
    @return Part
]]
function VFXHelpers.createPart(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Name = props.Name or "VFXPart"
	part.Anchored = if props.Anchored ~= nil then props.Anchored else true
	part.CanCollide = if props.CanCollide ~= nil then props.CanCollide else false
	part.CanQuery = if props.CanQuery ~= nil then props.CanQuery else false
	part.CanTouch = if props.CanTouch ~= nil then props.CanTouch else false
	part.CastShadow = false
	part.Shape = props.Shape or Enum.PartType.Block
	part.Material = props.Material or Enum.Material.Neon
	part.Color = props.Color or Color3.fromRGB(255, 255, 255)
	part.Transparency = if props.Transparency ~= nil then props.Transparency else 0
	part.Size = props.Size or Vector3.new(1, 1, 1)

	if props.CFrame then
		part.CFrame = props.CFrame
	elseif props.Position then
		part.Position = props.Position
	end

	part.Parent = props.Parent or workspace
	return part
end

--[[
    Create an Attachment at a world position, parented to Terrain.
    @return Attachment
]]
function VFXHelpers.createAttachment(worldPos: Vector3, parent: Instance?): Attachment
	local attachment = Instance.new("Attachment")
	attachment.WorldPosition = worldPos
	attachment.Parent = parent or workspace.Terrain
	return attachment
end

--[[
    Create a ParticleEmitter from a config table.
    All particle-specific properties are set from the config.

    @param config Table with particle properties:
        Color, Size, Transparency (as sequences),
        Lifetime, Speed, SpreadAngle, Drag, Rotation, RotSpeed
    @param parent Instance to parent the emitter to
    @return ParticleEmitter
]]
function VFXHelpers.createParticleEmitter(config: { [string]: any }, parent: Instance): ParticleEmitter
	local emitter = Instance.new("ParticleEmitter")

	if config.Color then
		emitter.Color = config.Color
	end
	if config.Size then
		emitter.Size = config.Size
	end
	if config.Transparency then
		emitter.Transparency = config.Transparency
	end

	emitter.Lifetime = config.Lifetime or NumberRange.new(0.5, 1)
	emitter.Speed = config.Speed or NumberRange.new(5, 15)
	emitter.SpreadAngle = config.SpreadAngle or Vector2.new(30, 30)
	emitter.Drag = config.Drag or 3
	emitter.Rate = 0 -- Always burst-emit for VFX
	emitter.Rotation = config.Rotation or NumberRange.new(0, 360)
	emitter.RotSpeed = config.RotSpeed or NumberRange.new(-60, 60)
	emitter.Parent = parent

	return emitter
end

--[[
    Create a Trail with two attachments on a carrier part.
    Returns the trail, carrier part, and both attachments.

    @param config Table with trail properties:
        AttachmentSpacing: number (distance between top/bottom attachments),
        Lifetime, MinLength, FaceCamera, LightEmission, LightInfluence,
        Color, Transparency, WidthScale (as sequences)
    @return trail: Trail, carrier: Part, attach0: Attachment, attach1: Attachment
]]
function VFXHelpers.createTrail(config: { [string]: any }): (Trail, Part, Attachment, Attachment)
	local spacing = config.AttachmentSpacing or 2

	local carrier = VFXHelpers.createPart({
		Name = config.Name or "TrailCarrier",
		Transparency = 1,
		Size = Vector3.new(1, 1, 1),
	})

	local attach0 = Instance.new("Attachment")
	attach0.Position = Vector3.new(0, spacing, 0)
	attach0.Parent = carrier

	local attach1 = Instance.new("Attachment")
	attach1.Position = Vector3.new(0, -spacing, 0)
	attach1.Parent = carrier

	local trail = Instance.new("Trail")
	trail.Attachment0 = attach0
	trail.Attachment1 = attach1
	trail.Lifetime = config.Lifetime or 0.4
	trail.MinLength = config.MinLength or 0.1
	trail.FaceCamera = if config.FaceCamera ~= nil then config.FaceCamera else true
	trail.LightEmission = config.LightEmission or 0.8
	trail.LightInfluence = config.LightInfluence or 0

	if config.Color then
		trail.Color = config.Color
	end
	if config.Transparency then
		trail.Transparency = config.Transparency
	end
	if config.WidthScale then
		trail.WidthScale = config.WidthScale
	end

	trail.Parent = carrier
	return trail, carrier, attach0, attach1
end

--[[
    Tween a part and auto-cleanup with Debris.

    @param instance Instance to tween
    @param tweenInfo TweenInfo for the animation
    @param goals Property goals table
    @param lifetime number? - seconds before Debris removes (default: tween duration + 0.1)
]]
function VFXHelpers.tweenAndCleanup(
	instance: Instance,
	tweenInfo: TweenInfo,
	goals: { [string]: any },
	lifetime: number?
)
	TweenService:Create(instance, tweenInfo, goals):Play()
	local cleanupTime = lifetime or (tweenInfo.Time + 0.1)
	Debris:AddItem(instance, cleanupTime)
end

--[[
    Client-side raycast to find the ground position below a point.
    Excludes enemies and player characters to hit only terrain/map geometry.

    @param position Vector3 - the reference position
    @return Vector3 - ground position (or original position as fallback)
]]
function VFXHelpers.findGroundPos(position: Vector3): Vector3
	local rayParams = RaycastParams.new()
	rayParams.FilterType = Enum.RaycastFilterType.Exclude
	local excludeList = CollectionService:GetTagged("Enemy")
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(excludeList, player.Character)
		end
	end
	rayParams.FilterDescendantsInstances = excludeList

	local rayOrigin = position + Vector3.new(0, 10, 0)
	local rayResult = workspace:Raycast(rayOrigin, Vector3.new(0, -30, 0), rayParams)
	return if rayResult then rayResult.Position + Vector3.new(0, 0.05, 0) else position
end

--[[
    Extract directional vectors from an enemy model.
    Returns the root part, forward direction, and right direction.

    @param enemyModel Model? - the enemy model
    @return rootPart: BasePart?, forward: Vector3, right: Vector3
]]
function VFXHelpers.getEnemyDirections(enemyModel: Model?): (BasePart?, Vector3, Vector3)
	local root = nil
	local forward = Vector3.new(0, 0, -1)
	local right = Vector3.new(1, 0, 0)

	if enemyModel then
		root = enemyModel:FindFirstChild("HumanoidRootPart")
			or enemyModel:FindFirstChild("Torso")
			or enemyModel.PrimaryPart
	end

	if root then
		forward = root.CFrame.LookVector
		right = root.CFrame.RightVector
	end

	return root, forward, right
end

--[[
    Apply distance-based screen shake. Intensity falls off with distance.

    @param shakeController The ScreenShakeController module (can be nil)
    @param position Vector3 - the VFX origin position
    @param maxDist number - max distance for shake to reach
    @param maxIntensity number - shake intensity at the center
    @param duration number - shake duration
]]
function VFXHelpers.distanceScreenShake(
	shakeController: any,
	position: Vector3,
	maxDist: number,
	maxIntensity: number,
	duration: number
)
	if not shakeController then
		return
	end

	local localPlayer = Players.LocalPlayer
	local character = localPlayer and localPlayer.Character
	if not character then
		return
	end

	local root = character:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	local dist = (root.Position - position).Magnitude
	if dist < maxDist then
		local intensity = math.clamp(1 - (dist / maxDist), 0.1, 1) * maxIntensity
		shakeController:Shake(intensity, duration)
	end
end

--[[
    Spawn physics debris that erupts and fades.

    @param groundPos Vector3 - spawn origin
    @param config Table:
        Count: number, SizeRange: {min, max}, Material: Enum.Material,
        ColorRange: {rMin, rMax, gMin, gMax, bMin, bMax},
        LaunchUp: {min, max}, LaunchOut: {min, max},
        SpawnRadius: {min, max}, FadeDelay: number, FadeDuration: number,
        LaunchDirection: Vector3? (optional directional bias)
]]
function VFXHelpers.spawnDebris(groundPos: Vector3, config: { [string]: any })
	local count = config.Count or 5
	local sizeMin = config.SizeRange and config.SizeRange[1] or 1
	local sizeMax = config.SizeRange and config.SizeRange[2] or 3
	local launchUpMin = config.LaunchUp and config.LaunchUp[1] or 30
	local launchUpMax = config.LaunchUp and config.LaunchUp[2] or 60
	local launchOutMin = config.LaunchOut and config.LaunchOut[1] or 10
	local launchOutMax = config.LaunchOut and config.LaunchOut[2] or 30
	local spawnDistMin = config.SpawnRadius and config.SpawnRadius[1] or 1
	local spawnDistMax = config.SpawnRadius and config.SpawnRadius[2] or 4
	local fadeDelay = config.FadeDelay or 0.8
	local fadeDuration = config.FadeDuration or 0.4

	for _ = 1, count do
		local size = math.random(sizeMin * 10, sizeMax * 10) / 10
		local rock = Instance.new("Part")
		rock.Size = Vector3.new(size, size * 0.7, size)
		rock.Anchored = false
		rock.CanCollide = true
		rock.CanQuery = false
		rock.CanTouch = false
		rock.CastShadow = false
		rock.Material = config.Material or Enum.Material.Slate

		if config.ColorRange then
			local cr = config.ColorRange
			rock.Color = Color3.fromRGB(math.random(cr[1], cr[2]), math.random(cr[3], cr[4]), math.random(cr[5], cr[6]))
		else
			rock.Color = Color3.fromRGB(math.random(45, 75), math.random(40, 65), math.random(35, 55))
		end

		local angle = math.random() * math.pi * 2
		local dist = math.random(spawnDistMin, spawnDistMax)
		rock.CFrame = CFrame.new(groundPos + Vector3.new(math.cos(angle) * dist, 0.5, math.sin(angle) * dist))
			* CFrame.Angles(math.random() * math.pi, math.random() * math.pi, math.random() * math.pi)
		rock.Parent = workspace

		local launchDir
		if config.LaunchDirection then
			launchDir = config.LaunchDirection
		else
			launchDir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		end

		local upForce = rock:GetMass() * math.random(launchUpMin, launchUpMax)
		local outForce = rock:GetMass() * math.random(launchOutMin, launchOutMax)
		rock:ApplyImpulse(Vector3.new(launchDir.X * outForce, upForce, launchDir.Z * outForce))
		rock:ApplyAngularImpulse(Vector3.new(math.random(-5, 5), math.random(-5, 5), math.random(-5, 5)))

		task.delay(fadeDelay, function()
			if rock.Parent then
				TweenService:Create(rock, TweenInfo.new(fadeDuration), { Transparency = 1 }):Play()
				Debris:AddItem(rock, fadeDuration + 0.1)
			end
		end)
	end
end

return VFXHelpers
