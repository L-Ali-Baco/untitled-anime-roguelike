--[[
    AttackVFXPlayer.luau
    Plays attack VFX by reading data-driven configs from AttackVFXConfig.
    
    Uses VFXHelpers for part/particle creation.
    Each VFX type (Slam, Swing, etc.) has a dedicated play function
    that interprets the config layers and renders them.
    
    Usage:
        local AttackVFXPlayer = require(...)
        AttackVFXPlayer:Init(screenShakeController)
        AttackVFXPlayer:Play("Slam", hitPosition, damage)
        AttackVFXPlayer:Play("Swing", hitPosition, damage, enemyModel)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local AttackVFXConfig = require(Shared:WaitForChild("Config"):WaitForChild("AttackVFXConfig"))
local VFXHelpers = require(script.Parent.VFXHelpers)

local AttackVFXPlayer = {}
AttackVFXPlayer.__index = AttackVFXPlayer

-- Reference to screen shake controller, set during Init
local ScreenShakeController = nil

--[[
    Initialize with optional dependencies.
    @param shakeController - ScreenShakeController module (or nil)
]]
function AttackVFXPlayer:Init(shakeController: any)
	ScreenShakeController = shakeController
end

-- ============================================================================
-- SLAM EFFECT
-- ============================================================================

--[[
    Play a ground slam effect from config.
    @param position Vector3 - impact position
    @param damage number - for scaling (reserved for future use)
    @param config table? - override config (defaults to AttackVFXConfig.Slam)
]]
function AttackVFXPlayer:PlaySlam(position: Vector3, _damage: number, config: { [string]: any }?)
	local cfg = config or AttackVFXConfig.Slam
	local groundPos = VFXHelpers.findGroundPos(position)
	local radius = cfg.Radius or 18

	-- === IMPACT FLASH ===
	if cfg.ImpactFlash then
		local fc = cfg.ImpactFlash
		local flash = VFXHelpers.createPart({
			Name = "SlamFlash",
			Shape = fc.Shape,
			Material = fc.Material,
			Color = fc.Color,
			Transparency = fc.Transparency,
			Size = fc.StartSize,
			Position = groundPos,
		})
		VFXHelpers.tweenAndCleanup(
			flash,
			TweenInfo.new(fc.TweenDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			fc.TweenTo,
			fc.Lifetime
		)
	end

	-- === GROUND CRACK ===
	if cfg.GroundCrack then
		local gc = cfg.GroundCrack
		local crack = VFXHelpers.createPart({
			Name = "SlamCrack",
			Shape = gc.Shape,
			Material = gc.Material,
			Color = gc.Color,
			Transparency = gc.Transparency,
			Size = gc.StartSize,
			CFrame = CFrame.new(groundPos) * CFrame.Angles(0, 0, math.rad(90)),
		})

		TweenService:Create(crack, TweenInfo.new(gc.ExpandDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), {
			Size = Vector3.new(0.15, radius * 1.2, radius * 1.2),
		}):Play()

		task.delay(gc.HoldTime, function()
			if crack.Parent then
				TweenService
					:Create(crack, TweenInfo.new(gc.FadeDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
						Transparency = 1,
					})
					:Play()
				Debris:AddItem(crack, gc.FadeDuration + 0.1)
			end
		end)
	end

	-- === SHOCKWAVE RINGS ===
	if cfg.ShockwaveRings then
		for _, rc in cfg.ShockwaveRings do
			local radiusMult = rc.RadiusMultiplier or 1
			task.delay(rc.Delay or 0, function()
				local ring = VFXHelpers.createPart({
					Name = "SlamRing",
					Shape = Enum.PartType.Cylinder,
					Material = Enum.Material.Neon,
					Color = rc.Color,
					Transparency = rc.Transparency or 0,
					Size = rc.StartSize,
					CFrame = CFrame.new(groundPos + Vector3.new(0, rc.HeightOffset or 0, 0))
						* CFrame.Angles(0, 0, math.rad(90)),
				})

				VFXHelpers.tweenAndCleanup(
					ring,
					TweenInfo.new(rc.Duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{
						Size = Vector3.new(rc.StartSize.X, radius * 2 * radiusMult, radius * 2 * radiusMult),
						Transparency = 1,
					},
					rc.Lifetime
				)
			end)
		end
	end

	-- === ROCK DEBRIS ===
	if cfg.RockDebris then
		VFXHelpers.spawnDebris(groundPos, cfg.RockDebris)
	end

	-- === DUST ===
	if cfg.Dust then
		local dustAttach = VFXHelpers.createAttachment(groundPos)

		if cfg.Dust.Up then
			local upEmitter = VFXHelpers.createParticleEmitter(cfg.Dust.Up, dustAttach)
			upEmitter:Emit(cfg.Dust.Up.EmitCount or 25)
		end

		if cfg.Dust.Ground then
			local groundEmitter = VFXHelpers.createParticleEmitter(cfg.Dust.Ground, dustAttach)
			groundEmitter:Emit(cfg.Dust.Ground.EmitCount or 20)
		end

		Debris:AddItem(dustAttach, cfg.Dust.AttachmentLifetime or 2)
	end

	-- === SCREEN SHAKE ===
	if cfg.ScreenShake then
		local sc = cfg.ScreenShake
		VFXHelpers.distanceScreenShake(ScreenShakeController, position, sc.MaxDist, sc.MaxIntensity, sc.Duration)
	end
end

-- ============================================================================
-- SWING EFFECT
-- ============================================================================

--[[
    Play a horizontal swing effect from config.
    @param position Vector3 - hit position
    @param damage number - for scaling (reserved for future use)
    @param enemyModel Model? - the attacking enemy (for direction)
    @param config table? - override config (defaults to AttackVFXConfig.Swing)
]]
function AttackVFXPlayer:PlaySwing(position: Vector3, _damage: number, enemyModel: Model?, config: { [string]: any }?)
	local cfg = config or AttackVFXConfig.Swing
	local enemyRoot, forwardDir, swingDirection = VFXHelpers.getEnemyDirections(enemyModel)
	local groundPos = VFXHelpers.findGroundPos(position)

	-- Calculate swing center for particle effects
	local swingCenter
	local centerCfg = cfg.CenterOffset or { Forward = 15, Down = 5 }
	if enemyRoot then
		swingCenter = enemyRoot.Position + Vector3.new(0, -centerCfg.Down, 0) + forwardDir * centerCfg.Forward
	else
		swingCenter = position + Vector3.new(0, 1, 0)
	end

	-- === TRAIL ARC ===
	if cfg.Trail then
		local tc = cfg.Trail
		local sweepRadius = tc.Radius or 20
		local sweepDuration = tc.Duration or 0.35
		local startAngle = math.rad(tc.StartAngle or -90)
		local endAngle = math.rad(tc.EndAngle or 90)
		local pivotOffset = tc.PivotOffset or Vector3.new(0, -5, 0)

		local pivotPos = if enemyRoot then enemyRoot.Position + pivotOffset else position

		-- Create trail using helper
		local trail, trailPart = VFXHelpers.createTrail({
			Name = "SwingTrailCarrier",
			AttachmentSpacing = tc.AttachmentSpacing or 2,
			Lifetime = tc.Lifetime or 0.4,
			LightEmission = tc.LightEmission or 0.8,
			Color = tc.Color,
			Transparency = tc.Transparency,
			WidthScale = tc.WidthScale,
		})

		-- Position at start of arc
		local startDir = forwardDir * math.cos(startAngle) + swingDirection * math.sin(startAngle)
		trailPart.Position = pivotPos + startDir * sweepRadius

		-- Animate along the arc
		task.spawn(function()
			task.wait() -- Let trail attach first frame

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

			task.wait(0.05)
			trail.Enabled = false
		end)

		Debris:AddItem(trailPart, sweepDuration + (tc.Lifetime or 0.4) + 0.2)
	end

	-- === WIND PARTICLES ===
	if cfg.WindParticles then
		local wc = cfg.WindParticles
		local windAttach = VFXHelpers.createAttachment(swingCenter)
		local windEmitter = VFXHelpers.createParticleEmitter(wc, windAttach)
		windEmitter:Emit(wc.EmitCount or 20)
		Debris:AddItem(windAttach, wc.AttachmentLifetime or 1)
	end

	-- === GROUND DUST ===
	if cfg.GroundDust then
		local dc = cfg.GroundDust
		local dustAttach = VFXHelpers.createAttachment(groundPos)
		local dustEmitter = VFXHelpers.createParticleEmitter(dc, dustAttach)
		dustEmitter:Emit(dc.EmitCount or 16)

		-- Second dust point offset along swing direction
		if dc.SecondPointOffset then
			local dustAttach2 = VFXHelpers.createAttachment(groundPos + swingDirection * dc.SecondPointOffset)
			local dust2 = dustEmitter:Clone()
			dust2.Parent = dustAttach2
			dust2:Emit(dc.SecondEmitCount or 10)
			Debris:AddItem(dustAttach2, dc.AttachmentLifetime or 1.5)
		end

		Debris:AddItem(dustAttach, dc.AttachmentLifetime or 1.5)
	end

	-- === SMALL DEBRIS ===
	if cfg.SmallDebris then
		local debrisConfig = table.clone(cfg.SmallDebris)
		-- Launch debris in swing direction with forward bias
		debrisConfig.LaunchDirection = (-swingDirection + Vector3.new(0, 0.5, 0) + forwardDir * 0.3).Unit
		VFXHelpers.spawnDebris(groundPos, debrisConfig)
	end

	-- === SCREEN SHAKE ===
	if cfg.ScreenShake then
		local sc = cfg.ScreenShake
		VFXHelpers.distanceScreenShake(ScreenShakeController, position, sc.MaxDist, sc.MaxIntensity, sc.Duration)
	end
end

-- ============================================================================
-- PUBLIC DISPATCH
-- ============================================================================

--[[
    Play an attack VFX by type name.
    @param vfxType string - "Slam", "Swing", etc.
    @param position Vector3 - hit/impact position
    @param damage number - attack damage
    @param enemyModel Model? - attacking enemy (needed for directional attacks)
    @param configOverride table? - optional config override
]]
function AttackVFXPlayer:Play(
	vfxType: string,
	position: Vector3,
	damage: number,
	enemyModel: Model?,
	configOverride: { [string]: any }?
)
	if vfxType == "Slam" then
		self:PlaySlam(position, damage, configOverride)
	elseif vfxType == "Swing" then
		self:PlaySwing(position, damage, enemyModel, configOverride)
	elseif vfxType == "LeapStart" then
		-- Wind-up VFX: reuses slam renderer with the LeapStart config (dust + small crack)
		self:PlaySlam(position, damage, configOverride or AttackVFXConfig.LeapStart)
	elseif vfxType == "LeapSlam" then
		-- Enhanced landing slam: reuses slam renderer with bigger LeapSlam config
		self:PlaySlam(position, damage, configOverride or AttackVFXConfig.LeapSlam)
	else
		warn("[AttackVFXPlayer] Unknown VFX type: " .. tostring(vfxType))
	end
end

return AttackVFXPlayer
