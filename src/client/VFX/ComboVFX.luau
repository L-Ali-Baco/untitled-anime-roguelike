--[[
	ComboVFX.luau
	Vanguard M1 — 3-hit cel-shaded melee combo VFX (left-handed character).
	Hit 1: right-to-left slash → crescent tilted like "/"
	Hit 2: left-to-right slash → crescent tilted like "\"
	Hit 3: finisher — large crescent + sphere burst + impact circle + embers.

	MESH NOTE: crescent mesh (4876614851) has a native 90° CCW offset.
	           All CFrame rolls include a +90° base correction to compensate.
]]

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local ComboVFX = {}

-- PALETTE
local WHITE_HOT = Color3.fromRGB(255, 255, 200)
local NEON_PURPLE = Color3.fromRGB(178, 0, 255)
local DARK_IRON = Color3.fromRGB(43, 45, 66)

local ENERGY_SEQ = ColorSequence.new({
	ColorSequenceKeypoint.new(0.0, WHITE_HOT),
	ColorSequenceKeypoint.new(0.35, NEON_PURPLE),
	ColorSequenceKeypoint.new(1.0, DARK_IRON),
})

-- ASSET IDs
local TEX_SLASH_DARK = "rbxassetid://83704812675614"
local TEX_SLASH_LIGHT = "rbxassetid://70803221046616"
local MESH_CRESCENT_ID = "rbxassetid://4876614851"
local TEX_IMPACT_CIRCLE = "rbxassetid://16924624153"
local TEX_LIGHT_CLOUD = "rbxassetid://883906867"
local TEX_SHARD = "rbxassetid://133968093303018"

-- Mesh native orientation is 90° CCW from expected — this corrects it.
local MESH_ROT_CORRECTION = 90 -- degrees

-- HELPERS

local function makePart(props: {
	Color: Color3?,
	Size: Vector3?,
	CFrame: CFrame?,
	Shape: Enum.PartType?,
	Transparency: number?,
}): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Color = props.Color or WHITE_HOT
	p.Size = props.Size or Vector3.new(1, 1, 1)
	p.Shape = props.Shape or Enum.PartType.Block
	p.Transparency = props.Transparency or 0
	if props.CFrame then
		p.CFrame = props.CFrame
	end
	p.Parent = workspace.Terrain
	return p
end

local function applyFlipbook(e: ParticleEmitter)
	e.FlipbookLayout = Enum.ParticleFlipbookLayout.Grid8x8
	e.FlipbookMode = Enum.ParticleFlipbookMode.OneShot
end

-- Emit blocky neon sparks
local function emitSparks(worldPos: Vector3, count: number, speed: number)
	local att = Instance.new("Attachment")
	att.WorldPosition = worldPos
	att.Parent = workspace.Terrain
	local e = Instance.new("ParticleEmitter")
	e.Texture = TEX_SHARD
	e.Color = ENERGY_SEQ
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.35),
		NumberSequenceKeypoint.new(0.4, 0.2),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.6, 0.15),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Speed = NumberRange.new(speed * 0.6, speed)
	e.Lifetime = NumberRange.new(0.1, 0.28)
	e.SpreadAngle = Vector2.new(90, 90)
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Drag = 6
	e.Rate = 0
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-400, 400)
	e.Parent = att
	e:Emit(count)
	Debris:AddItem(att, 0.4)
end

-- Emit floating ember sparks (for finisher)
local function emitEmbers(worldPos: Vector3, count: number)
	local att = Instance.new("Attachment")
	att.WorldPosition = worldPos
	att.Parent = workspace.Terrain
	local e = Instance.new("ParticleEmitter")
	e.Texture = TEX_SHARD
	e.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0.0, WHITE_HOT),
		ColorSequenceKeypoint.new(0.3, NEON_PURPLE),
		ColorSequenceKeypoint.new(1.0, DARK_IRON),
	})
	e.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.15),
		NumberSequenceKeypoint.new(0.4, 0.3),
		NumberSequenceKeypoint.new(1, 0),
	})
	e.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.5, 0.2),
		NumberSequenceKeypoint.new(1, 1),
	})
	e.Speed = NumberRange.new(4, 14)
	e.Lifetime = NumberRange.new(0.3, 0.6)
	e.SpreadAngle = Vector2.new(120, 120)
	e.LightEmission = 1
	e.LightInfluence = 0
	e.Drag = 2
	e.Acceleration = Vector3.new(0, 7, 0)
	e.Rate = 0
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-300, 300)
	e.Parent = att
	e:Emit(count)
	Debris:AddItem(att, 0.75)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- CRESCENT SLASH MARK
--   hitPos:  world position where the swing lands
--   lookDir: horizontal look direction of attacker
--   rollDeg: tilt in degrees AFTER the mesh correction
--            Positive = "/" tilt (hit 1, R-to-L)
--            Negative = "\" tilt (hit 2, L-to-R)
-- ─────────────────────────────────────────────────────────────────────────────

local SWEEP_DURATION = 0.16

local function spawnCrescent(hitPos: Vector3, lookDir: Vector3, rollDeg: number)
	local up = Vector3.new(0, 1, 0)
	local right = lookDir:Cross(up).Unit
	if right.Magnitude < 0.01 then
		right = Vector3.new(1, 0, 0)
	end

	-- Build base CFrame: crescent faces the attacker (flat face perpendicular to lookDir)
	-- Apply mesh correction (+90°) then the per-hit tilt (rollDeg)
	local totalRoll = math.rad(MESH_ROT_CORRECTION + rollDeg)
	local baseCF = CFrame.new(hitPos) * CFrame.fromMatrix(Vector3.zero, right, up) * CFrame.Angles(0, 0, totalRoll)

	-- ── LAYER 1: Dark iron base crescent (largest, longest duration) ──────────
	local dark = Instance.new("Part")
	dark.Anchored = true
	dark.CanCollide = false
	dark.CanQuery = false
	dark.CanTouch = false
	dark.CastShadow = false
	dark.Size = Vector3.new(1, 1, 1)
	dark.Material = Enum.Material.Neon
	dark.Color = DARK_IRON
	dark.Transparency = 0.1
	local darkMesh = Instance.new("SpecialMesh")
	darkMesh.MeshType = Enum.MeshType.FileMesh
	darkMesh.MeshId = MESH_CRESCENT_ID
	darkMesh.Scale = Vector3.new(7, 7, 1.2)
	darkMesh.TextureId = ""
	darkMesh.Parent = dark
	dark.CFrame = baseCF
	dark.Parent = workspace.Terrain

	TweenService:Create(dark, TweenInfo.new(SWEEP_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Transparency = 1,
	}):Play()
	Debris:AddItem(dark, SWEEP_DURATION + 0.04)

	-- ── LAYER 2: Neon purple mid ───────────────────────────────────────────────
	task.delay(0.02, function()
		local mid = Instance.new("Part")
		mid.Anchored = true
		mid.CanCollide = false
		mid.CanQuery = false
		mid.CanTouch = false
		mid.CastShadow = false
		mid.Size = Vector3.new(1, 1, 1)
		mid.Material = Enum.Material.Neon
		mid.Color = NEON_PURPLE
		mid.Transparency = 0
		local midMesh = Instance.new("SpecialMesh")
		midMesh.MeshType = Enum.MeshType.FileMesh
		midMesh.MeshId = MESH_CRESCENT_ID
		midMesh.Scale = Vector3.new(5.5, 5.5, 1.0)
		midMesh.TextureId = ""
		midMesh.Parent = mid
		mid.CFrame = baseCF * CFrame.Angles(0, 0, math.rad(4))
		mid.Parent = workspace.Terrain
		TweenService
			:Create(mid, TweenInfo.new(SWEEP_DURATION * 0.85, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Transparency = 1,
			})
			:Play()
		Debris:AddItem(mid, SWEEP_DURATION + 0.02)
	end)

	-- ── LAYER 3: White hot core (smallest, quickest snap) ─────────────────────
	task.delay(0.035, function()
		local core = Instance.new("Part")
		core.Anchored = true
		core.CanCollide = false
		core.CanQuery = false
		core.CanTouch = false
		core.CastShadow = false
		core.Size = Vector3.new(1, 1, 1)
		core.Material = Enum.Material.Neon
		core.Color = WHITE_HOT
		core.Transparency = 0
		local coreMesh = Instance.new("SpecialMesh")
		coreMesh.MeshType = Enum.MeshType.FileMesh
		coreMesh.MeshId = MESH_CRESCENT_ID
		coreMesh.Scale = Vector3.new(3.8, 3.8, 0.8)
		coreMesh.TextureId = ""
		coreMesh.Parent = core
		core.CFrame = baseCF * CFrame.Angles(0, 0, math.rad(-3))
		core.Parent = workspace.Terrain
		TweenService
			:Create(core, TweenInfo.new(SWEEP_DURATION * 0.65, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
				Transparency = 1,
			})
			:Play()
		Debris:AddItem(core, SWEEP_DURATION + 0.02)
	end)

	-- ── Flipbook arc particles at the impact point ─────────────────────────────
	local arcAtt = Instance.new("Attachment")
	arcAtt.WorldPosition = hitPos
	arcAtt.Parent = workspace.Terrain

	local darkArc = Instance.new("ParticleEmitter")
	darkArc.Texture = TEX_SLASH_DARK
	applyFlipbook(darkArc)
	darkArc.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, DARK_IRON),
		ColorSequenceKeypoint.new(0.5, NEON_PURPLE),
		ColorSequenceKeypoint.new(1, DARK_IRON),
	})
	darkArc.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.15, 5.5),
		NumberSequenceKeypoint.new(0.6, 6.5),
		NumberSequenceKeypoint.new(1, 0),
	})
	darkArc.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.2, 0.05),
		NumberSequenceKeypoint.new(0.7, 0.35),
		NumberSequenceKeypoint.new(1, 1),
	})
	darkArc.Speed = NumberRange.new(0, 1)
	darkArc.Lifetime = NumberRange.new(0.14, 0.20)
	darkArc.SpreadAngle = Vector2.new(8, 8)
	darkArc.LightEmission = 1
	darkArc.LightInfluence = 0
	darkArc.Rate = 0
	darkArc.Rotation = NumberRange.new(MESH_ROT_CORRECTION + rollDeg - 15, MESH_ROT_CORRECTION + rollDeg + 10)
	darkArc.RotSpeed = NumberRange.new(-350, -180)
	darkArc.Parent = arcAtt
	darkArc:Emit(8)

	local lightArc = Instance.new("ParticleEmitter")
	lightArc.Texture = TEX_SLASH_LIGHT
	applyFlipbook(lightArc)
	lightArc.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, WHITE_HOT),
		ColorSequenceKeypoint.new(0.4, NEON_PURPLE),
		ColorSequenceKeypoint.new(1, DARK_IRON),
	})
	lightArc.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.12, 4),
		NumberSequenceKeypoint.new(0.55, 5),
		NumberSequenceKeypoint.new(1, 0),
	})
	lightArc.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.15, 0),
		NumberSequenceKeypoint.new(0.65, 0.25),
		NumberSequenceKeypoint.new(1, 1),
	})
	lightArc.Speed = NumberRange.new(0, 1)
	lightArc.Lifetime = NumberRange.new(0.11, 0.17)
	lightArc.SpreadAngle = Vector2.new(6, 6)
	lightArc.LightEmission = 1
	lightArc.LightInfluence = 0
	lightArc.Rate = 0
	lightArc.Rotation = NumberRange.new(MESH_ROT_CORRECTION + rollDeg - 12, MESH_ROT_CORRECTION + rollDeg + 8)
	lightArc.RotSpeed = NumberRange.new(-420, -220)
	lightArc.Parent = arcAtt
	lightArc:Emit(6)

	Debris:AddItem(arcAtt, 0.35)

	-- ── PointLight flash ──────────────────────────────────────────────────────
	local la = Instance.new("Attachment")
	la.WorldPosition = hitPos
	la.Parent = workspace.Terrain
	local fl = Instance.new("PointLight")
	fl.Color = NEON_PURPLE
	fl.Brightness = 3
	fl.Range = 14
	fl.Parent = la
	TweenService:Create(fl, TweenInfo.new(0.12), { Brightness = 0 }):Play()
	Debris:AddItem(la, 0.2)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- HIT 3 FINISHER
-- ─────────────────────────────────────────────────────────────────────────────

local function playFinisher(hitPos: Vector3, lookDir: Vector3)
	-- Large crescent mark for finisher (extra roll for emphasis)
	spawnCrescent(hitPos, lookDir, 15)

	-- 3-layer sphere burst
	local baseSphere = makePart({
		Color = DARK_IRON,
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(5, 5, 5),
		CFrame = CFrame.new(hitPos),
	})
	TweenService:Create(baseSphere, TweenInfo.new(0.22, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(20, 20, 20),
		Transparency = 1,
	}):Play()
	Debris:AddItem(baseSphere, 0.3)

	task.delay(0.02, function()
		local midSphere = makePart({
			Color = NEON_PURPLE,
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(3.5, 3.5, 3.5),
			CFrame = CFrame.new(hitPos),
		})
		TweenService:Create(midSphere, TweenInfo.new(0.18, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(15, 15, 15),
			Transparency = 1,
		}):Play()
		Debris:AddItem(midSphere, 0.25)
	end)

	task.delay(0.04, function()
		local coreSphere = makePart({
			Color = WHITE_HOT,
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(2, 2, 2),
			CFrame = CFrame.new(hitPos),
		})
		TweenService:Create(coreSphere, TweenInfo.new(0.10, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(9, 9, 9),
			Transparency = 1,
		}):Play()
		Debris:AddItem(coreSphere, 0.16)
	end)

	-- Ground shockwave rings
	local groundPos = hitPos - Vector3.new(0, 1.5, 0)
	local ring = makePart({
		Color = NEON_PURPLE,
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, 1, 1),
		CFrame = CFrame.new(groundPos) * CFrame.Angles(0, 0, math.rad(90)),
	})
	TweenService:Create(ring, TweenInfo.new(0.28, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
		Size = Vector3.new(0.15, 22, 22),
		Transparency = 1,
	}):Play()
	Debris:AddItem(ring, 0.38)

	task.delay(0.03, function()
		local ring2 = makePart({
			Color = DARK_IRON,
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.22, 1, 1),
			CFrame = CFrame.new(groundPos) * CFrame.Angles(0, 0, math.rad(90)),
		})
		TweenService:Create(ring2, TweenInfo.new(0.32, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.1, 28, 28),
			Transparency = 1,
		}):Play()
		Debris:AddItem(ring2, 0.42)
	end)

	-- Impact flash PointLight
	local flashAtt = Instance.new("Attachment")
	flashAtt.WorldPosition = hitPos
	flashAtt.Parent = workspace.Terrain
	local flash = Instance.new("PointLight")
	flash.Color = NEON_PURPLE
	flash.Brightness = 7
	flash.Range = 26
	flash.Parent = flashAtt
	TweenService:Create(flash, TweenInfo.new(0.22), { Brightness = 0 }):Play()
	Debris:AddItem(flashAtt, 0.35)

	-- Impact circle ring
	local ringAtt = Instance.new("Attachment")
	ringAtt.WorldPosition = groundPos
	ringAtt.Parent = workspace.Terrain
	local impactCircle = Instance.new("ParticleEmitter")
	impactCircle.Texture = TEX_IMPACT_CIRCLE
	impactCircle.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, WHITE_HOT),
		ColorSequenceKeypoint.new(0.4, NEON_PURPLE),
		ColorSequenceKeypoint.new(1, DARK_IRON),
	})
	impactCircle.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.2, 10),
		NumberSequenceKeypoint.new(0.7, 12),
		NumberSequenceKeypoint.new(1, 0),
	})
	impactCircle.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0),
		NumberSequenceKeypoint.new(0.35, 0.15),
		NumberSequenceKeypoint.new(0.8, 0.6),
		NumberSequenceKeypoint.new(1, 1),
	})
	impactCircle.Speed = NumberRange.new(0, 0)
	impactCircle.Lifetime = NumberRange.new(0.22, 0.30)
	impactCircle.SpreadAngle = Vector2.new(0, 0)
	impactCircle.LightEmission = 1
	impactCircle.LightInfluence = 0
	impactCircle.Rate = 0
	impactCircle.Rotation = NumberRange.new(-15, 15)
	impactCircle.RotSpeed = NumberRange.new(-80, 80)
	impactCircle.Parent = ringAtt
	impactCircle:Emit(3)
	Debris:AddItem(ringAtt, 0.4)

	-- Light cloud smoke puff
	local smokeAtt = Instance.new("Attachment")
	smokeAtt.WorldPosition = hitPos
	smokeAtt.Parent = workspace.Terrain
	local puff = Instance.new("ParticleEmitter")
	puff.Texture = TEX_LIGHT_CLOUD
	puff.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0.0, WHITE_HOT),
		ColorSequenceKeypoint.new(0.35, NEON_PURPLE),
		ColorSequenceKeypoint.new(1.0, DARK_IRON),
	})
	puff.Size = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 1),
		NumberSequenceKeypoint.new(0.4, 4.5),
		NumberSequenceKeypoint.new(1, 6),
	})
	puff.Transparency = NumberSequence.new({
		NumberSequenceKeypoint.new(0, 0.1),
		NumberSequenceKeypoint.new(0.4, 0.45),
		NumberSequenceKeypoint.new(1, 1),
	})
	puff.Speed = NumberRange.new(6, 18)
	puff.Lifetime = NumberRange.new(0.3, 0.5)
	puff.SpreadAngle = Vector2.new(90, 90)
	puff.LightEmission = 0.4
	puff.LightInfluence = 0
	puff.Rate = 0
	puff.Rotation = NumberRange.new(0, 360)
	puff.RotSpeed = NumberRange.new(-60, 60)
	puff.Parent = smokeAtt
	puff:Emit(14)
	Debris:AddItem(smokeAtt, 0.65)

	emitSparks(hitPos, 32, 50)
	emitEmbers(hitPos, 22)
	emitEmbers(groundPos, 10)
end

-- ─────────────────────────────────────────────────────────────────────────────
-- PUBLIC API
-- ─────────────────────────────────────────────────────────────────────────────

--[[
	Play a combo hit VFX.
	@param hitPos  Vector3 — swing contact point (4 studs in front of character)
	@param hitNum  number  — 1, 2, or 3
	@param char    Model?  — attacker model (provides look direction)
]]
function ComboVFX.Play(hitPos: Vector3, hitNum: number, char: Model?)
	local lookDir = Vector3.new(0, 0, -1)
	if char then
		local root = char:FindFirstChild("HumanoidRootPart") :: BasePart?
		if root then
			lookDir = root.CFrame.LookVector
		end
	end

	if hitNum == 3 then
		playFinisher(hitPos, lookDir)
	elseif hitNum == 2 then
		-- Hit 2: left-to-right (left-handed character) → "\" tilt → negative roll
		spawnCrescent(hitPos, lookDir, -30)
		emitSparks(hitPos, 9, 32)
	else
		-- Hit 1: right-to-left → "/" tilt → positive roll
		spawnCrescent(hitPos, lookDir, 30)
		emitSparks(hitPos, 7, 28)
	end
end

--[[
	Convenience: play all 3 combo hits in sequence.
]]
function ComboVFX.PlayFull(startPos: Vector3, char: Model?, delays: { number }?)
	local d = delays or { 0.25, 0.25 }
	ComboVFX.Play(startPos, 1, char)
	task.delay(d[1], function()
		ComboVFX.Play(startPos, 2, char)
		task.delay(d[2], function()
			ComboVFX.Play(startPos, 3, char)
		end)
	end)
end

return ComboVFX
