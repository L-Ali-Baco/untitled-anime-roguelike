--!strict
--[[
	SlashVFX.luau
	M2 "Aerial Slash" — Void Energy Slash (Kassadin Force Pulse aesthetic)

	Visual design:
	- Deep violet/void palette: pale core → bright purple → near-black void
	- PRIMARY: Expanding arcane energy wall (Trail on X-axis wingtips)
	- SECONDARY: Angular void-shard needles shedding backward (VelocityParallel)
	- TERTIARY: Soft volumetric glow puffs for depth
	- No SpecialMesh — trail + particles carry the entire visual, zero arc artifacts
]]

local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local SlashVFX = {}

-- [[ ASSET CONSTANTS ]]
local ASSETS = {
	ARCANE_TEX = "rbxassetid://18453651571", -- flowing energy texture (trail + glow)
	VOID_SHARD = "rbxassetid://133968093303018", -- diamond/angular shard particle
}

-- [[ COLOR CONSTANTS — void palette ]]
local COLORS = {
	PALE_CORE = Color3.fromRGB(220, 190, 255), -- near-white hot violet (leading edge)
	VOID_PURPLE = Color3.fromRGB(130, 0, 255), -- saturated void purple (body)
	DEEP_VOID = Color3.fromRGB(12, 0, 40), -- near-black void (trailing wake)
}

-- [[ VFX CONFIGURATION ]]
local VFX_CONFIG = {
	TWEEN_DURATION = 0.65,
	START_SIZE = Vector3.new(6, 6, 0.4), -- Part size: controls trail span at cast
	END_SIZE = Vector3.new(40, 40, 0.4), -- Part size: controls trail span at end
	TRAVEL_DISTANCE = 45,
	TRAIL_LIFETIME = 0.4,
}

local SLASH_TWEEN_INFO =
	TweenInfo.new(VFX_CONFIG.TWEEN_DURATION, Enum.EasingStyle.Exponential, Enum.EasingDirection.Out)

--[[
    opts (optional):
      scale      number?   — uniform size+range multiplier (e.g. 0.8 for echo)
      mainColor  Color3?   — overrides PALE_CORE (leading-edge / core glow)
      bodyColor  Color3?   — overrides VOID_PURPLE (body trail + point light)
    All fields are optional; omitted values fall back to the defaults above.
]]
export type SlashOpts = {
	scale: number?,
	mainColor: Color3?,
	bodyColor: Color3?,
}

function SlashVFX.Play(originPos: Vector3, lookVector: Vector3, opts: SlashOpts?)
	local dir = lookVector.Magnitude > 0.001 and lookVector.Unit or Vector3.new(0, 0, -1)

	-- Resolve opts with fallbacks
	local scale = (opts and opts.scale) or 1.0
	local coreCol = (opts and opts.mainColor) or COLORS.PALE_CORE
	local bodyCol = (opts and opts.bodyColor) or COLORS.VOID_PURPLE

	-- Scale sizes and travel distance
	local startSize = VFX_CONFIG.START_SIZE * scale
	local endSize = VFX_CONFIG.END_SIZE * scale
	local travelDist = VFX_CONFIG.TRAVEL_DISTANCE * scale

	-- ROTATION: x=90 lays flat, y=180 faces forward, z=15 gives Kassadin's angular tilt
	local baseRotation = CFrame.lookAt(Vector3.zero, dir)
	local flatRotation = baseRotation * CFrame.Angles(math.rad(90), math.rad(180), math.rad(15))
	local spawnCFrame = CFrame.new(originPos + dir * 3) * flatRotation
	local targetCFrame = CFrame.new(spawnCFrame.Position + dir * travelDist) * flatRotation

	-- ── CARRIER PART ────────────────────────────────────────────────────────────
	-- Fully transparent — it's only an anchor for Trail attachments + emitters.
	-- Part.Size grows to drive trail width; no mesh means no arc artifact.
	local part = Instance.new("Part")
	part.Name = "VoidSlashProjectile"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = startSize
	part.CFrame = spawnCFrame

	-- ── ARCANE WALL TRAIL ────────────────────────────────────────────────────────
	-- Two attachments on the local X axis (the true horizontal wingspan axis)
	-- AND one in the middle, pushed forward, so the two trails together form an ARC shape `<`
	local attLeft = Instance.new("Attachment")
	attLeft.Name = "WingLeft"
	attLeft.Parent = part

	local attCenter = Instance.new("Attachment")
	attCenter.Name = "NoseCenter"
	attCenter.Parent = part

	local attRight = Instance.new("Attachment")
	attRight.Name = "WingRight"
	attRight.Parent = part

	-- Left half of the arc
	local trailLeft = Instance.new("Trail")
	trailLeft.Attachment0 = attLeft
	trailLeft.Attachment1 = attCenter
	trailLeft.Texture = ASSETS.ARCANE_TEX
	trailLeft.TextureMode = Enum.TextureMode.Stretch
	trailLeft.FaceCamera = false
	trailLeft.LightEmission = 1
	trailLeft.LightInfluence = 0
	trailLeft.Lifetime = VFX_CONFIG.TRAIL_LIFETIME
	trailLeft.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, coreCol),
		ColorSequenceKeypoint.new(0.15, bodyCol),
		ColorSequenceKeypoint.new(1, COLORS.DEEP_VOID),
	})
	trailLeft.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.5, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	trailLeft.WidthScale = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.6, 0.7),
		NumberSequenceKeypoint.new(1, 0),
	})
	trailLeft.Parent = part

	-- Right half of the arc
	local trailRight = trailLeft:Clone()
	trailRight.Attachment0 = attCenter
	trailRight.Attachment1 = attRight
	trailRight.Parent = part

	-- ── VOID SHARD NEEDLES ───────────────────────────────────────────────────────
	-- Angular crystal fragments shedding backward at high speed.
	-- VelocityParallel + Squash=-0.7 stretches them into sharp needles.
	local shardAtt = Instance.new("Attachment")
	shardAtt.Name = "ShardEmitter"
	shardAtt.Parent = part

	local shards = Instance.new("ParticleEmitter")
	shards.Texture = ASSETS.VOID_SHARD
	shards.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, coreCol),
		ColorSequenceKeypoint.new(0.3, bodyCol),
		ColorSequenceKeypoint.new(1, COLORS.DEEP_VOID),
	})
	shards.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 2),
		NumberSequenceKeypoint.new(0.25, 3.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	shards.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.6, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	shards.EmissionDirection = Enum.NormalId.Back
	shards.Speed = NumberRange.new(20, 50)
	shards.Drag = 5
	shards.Lifetime = NumberRange.new(0.2, 0.4)
	shards.SpreadAngle = Vector2.new(20, 20)
	shards.Orientation = Enum.ParticleOrientation.VelocityParallel
	shards.Rotation = NumberRange.new(-90, -90) -- orient along velocity axis
	shards.RotSpeed = NumberRange.new(0)
	shards.Squash = NumberSequence.new(-0.7) -- severely stretched → sharp needle look
	shards.LightEmission = 1
	shards.Rate = 45
	shards.Parent = shardAtt

	-- ── VOLUMETRIC GLOW PUFFS ────────────────────────────────────────────────────
	-- Large, slow, soft blobs that add depth and void "cloud" behind the slash.
	local glowAtt = Instance.new("Attachment")
	glowAtt.Name = "GlowEmitter"
	glowAtt.Parent = part

	local glow = Instance.new("ParticleEmitter")
	glow.Texture = ASSETS.ARCANE_TEX
	glow.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, bodyCol),
		ColorSequenceKeypoint.new(1, COLORS.DEEP_VOID),
	})
	glow.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 8),
		NumberSequenceKeypoint.new(1, 0),
	})
	glow.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.55),
		NumberSequenceKeypoint.new(1, 1),
	})
	glow.EmissionDirection = Enum.NormalId.Back
	glow.Speed = NumberRange.new(3, 10)
	glow.Drag = 6
	glow.Lifetime = NumberRange.new(0.25, 0.5)
	glow.SpreadAngle = Vector2.new(50, 50)
	glow.Rotation = NumberRange.new(0, 360)
	glow.RotSpeed = NumberRange.new(-50, 50)
	glow.LightEmission = 0.8
	glow.Rate = 12
	glow.Parent = glowAtt

	-- ── POINT LIGHT ──────────────────────────────────────────────────────────────
	local light = Instance.new("PointLight")
	light.Color = bodyCol
	light.Range = 22
	light.Brightness = 3
	light.Parent = part

	part.Parent = workspace.Terrain

	-- ── ANIMATION ────────────────────────────────────────────────────────────────
	local alive = true

	-- Part.Size grows → trail spans wider each frame via wingtip tracker.
	-- No Transparency tween on the Part (already 1); CFrame carries it forward.
	TweenService:Create(part, SLASH_TWEEN_INFO, {
		Size = endSize,
		CFrame = targetCFrame,
	}):Play()

	TweenService:Create(light, SLASH_TWEEN_INFO, {
		Range = 38,
		Brightness = 0,
	}):Play()

	-- Wingtip tracker: keeps trail attachments at the true X-axis wingspan edges
	-- as Part.Size.X grows from 6 → 40 during the tween.
	-- We ALSO push the center forward and the wings backwards on the Z axis to form the crescent arc shape!
	local trackerConn: RBXScriptConnection
	trackerConn = RunService.RenderStepped:Connect(function()
		if not alive or not part.Parent then
			trackerConn:Disconnect()
			return
		end
		local halfSpan = (part.Size.X / 2) * 0.95
		local curveDepth = part.Size.X * 0.25 -- The curve depth grows with the size of the projectile

		attLeft.Position = Vector3.new(halfSpan, 0, curveDepth) -- Pulled backwards
		attCenter.Position = Vector3.new(0, 0, -curveDepth * 0.5) -- Pushed forwards
		attRight.Position = Vector3.new(-halfSpan, 0, curveDepth) -- Pulled backwards
	end)

	-- At tween end: stop all emitters, disable trail.
	-- Trail segments already painted fade naturally over TRAIL_LIFETIME.
	task.delay(VFX_CONFIG.TWEEN_DURATION, function()
		alive = false
		if trailLeft and trailLeft.Parent then
			trailLeft.Enabled = false
		end
		if trailRight and trailRight.Parent then
			trailRight.Enabled = false
		end
		if shards and shards.Parent then
			shards.Enabled = false
		end
		if glow and glow.Parent then
			glow.Enabled = false
		end
	end)

	-- Authoritative cleanup — Debris holds its own reference.
	Debris:AddItem(part, VFX_CONFIG.TWEEN_DURATION + VFX_CONFIG.TRAIL_LIFETIME + 0.2)
end

function SlashVFX.PlayFromChar(char: Model)
	local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	SlashVFX.Play(root.Position, root.CFrame.LookVector)
end

return SlashVFX
