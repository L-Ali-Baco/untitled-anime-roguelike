--[[
	LightningVFX.luau
	=================
	Client-side visual effects for the StaticFilament (Chain Lightning) item proc.

	HOW IT CONNECTS TO THE SERVER:
	  ProcService (server) fires the "ChainLightningVFX" RemoteEvent to all clients
	  after resolving chain targets. Each client renders the bounces independently,
	  which is intentional — VFX is cosmetic and doesn't need to be perfectly
	  synchronised across clients.

	  Remote payload:  { {From: Vector3, To: Vector3}, ... }
	  One entry per chain bounce segment (e.g. 10 bounces = 10 table entries).

	VISUAL DESIGN:
	  Each arc is a thin neon block (the "LightningBeam" pool) positioned between
	  the two bounce endpoints, like a bullet tracer but electric. A PointLight
	  pulses at the impact point. The arc flashes in at full opacity then fades over
	  0.18 s, with a cascade delay of 0.06 s between bounces for a travelling
	  zap effect rather than all arcs appearing simultaneously.

	  Chain colour: bright cyan-white core → electric blue edges.
	  On crits (isCrit flag in payload): colour shifts to gold-white.

	POOLING:
	  Arc Parts → "LightningBeam" pool (40 slots; handles up to 4 simultaneous
	  10-bounce chains from 4 players with a 0.18 s lifetime overlap).
	  PointLights: created fresh per bounce impact; Debris:AddItem'd.
	  Attachments: not used (PointLight parented directly to workspace.Terrain).

	USAGE (from EnemyVFXController):
	  local LightningVFX = require(...)
	  ChainLightningRemote.OnClientEvent:Connect(function(bounces, isCrit)
	      LightningVFX:PlayChain(bounces, isCrit)
	  end)
]]

local TweenService = game:GetService("TweenService")
local Debris = game:GetService("Debris")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local VFXPool = require(script.Parent.VFXPool)

local LightningVFX = {}
LightningVFX.Name = "LightningVFX"

-- ── Colour Palettes ───────────────────────────────────────────────────────────

-- Normal chain: electric cyan-white
local NORMAL_CORE = Color3.fromRGB(180, 240, 255) -- pale cyan near-white
local NORMAL_ARC = Color3.fromRGB(50, 160, 255) -- electric blue

-- Critical chain: gold-white (more energy, more heat)
local CRIT_CORE = Color3.fromRGB(255, 250, 180) -- hot white-gold
local CRIT_ARC = Color3.fromRGB(255, 200, 50) -- amber gold

-- ── Timing ────────────────────────────────────────────────────────────────────

local ARC_LIFETIME = 0.18 -- seconds each arc stays visible
local ARC_RETURN_DELAY = ARC_LIFETIME + 0.05 -- pool return: slight buffer after fade
local BOUNCE_CASCADE_DELAY = 0.06 -- seconds between each consecutive bounce appearing

-- ── Pre-baked TweenInfos ──────────────────────────────────────────────────────

local ARC_FADE_TWEEN = TweenInfo.new(ARC_LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local ARC_FLASH_IN_TWEEN = TweenInfo.new(0.02, Enum.EasingStyle.Linear) -- instant flash-in
local LIGHT_FADE_TWEEN = TweenInfo.new(ARC_LIFETIME, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)

-- ── Private: Single Arc ───────────────────────────────────────────────────────

--[[
	_playArc(fromPos, toPos, arcColor, coreColor)

	Renders one arc segment (a thin neon beam) between two world positions.
	Fetches from the LightningBeam pool, tweens it from opaque to invisible,
	then returns it to the pool. All within ARC_LIFETIME seconds.

	This function is non-blocking (returns immediately after starting tweens).
	Called from a task.spawn in PlayChain for each bounce.
]]
local function _playArc(fromPos: Vector3, toPos: Vector3, arcColor: Color3, coreColor: Color3)
	local diff = toPos - fromPos
	local distance = diff.Magnitude
	if distance < 0.5 then
		-- Targets are too close — skip to avoid zero-length or degenerate beams.
		return
	end

	local midPoint = (fromPos + toPos) / 2

	-- ── Beam part ────────────────────────────────────────────────────────
	local beam = VFXPool:GetPart("LightningBeam")
	beam.Color = arcColor
	-- Width of the arc: thin (0.08) for normal, slightly thicker (0.12) for crits.
	-- Color already distinguishes them visually; this adds a tactile size difference.
	local w = if arcColor == CRIT_ARC then 0.12 else 0.08
	beam.Size = Vector3.new(w, w, distance)
	beam.CFrame = CFrame.lookAt(midPoint, toPos) -- orient along arc direction

	-- Flash in instantly at low transparency (0.1 = very bright neon).
	beam.Transparency = 0.1
	beam.Parent = workspace

	-- Fade out over ARC_LIFETIME.
	TweenService:Create(beam, ARC_FADE_TWEEN, { Transparency = 1 }):Play()

	-- Return to pool after full fade. Part is invisible by then; safe to park.
	VFXPool:ReturnPartDelayed("LightningBeam", beam, ARC_RETURN_DELAY)

	-- ── Impact PointLight at the target end ────────────────────────────
	-- PointLight: cheap; no pool overhead justified.
	local lightAtt = Instance.new("Attachment")
	lightAtt.WorldPosition = toPos
	lightAtt.Parent = workspace.Terrain

	local light = Instance.new("PointLight")
	light.Color = coreColor
	light.Brightness = 3
	light.Range = 12
	light.Parent = lightAtt

	TweenService:Create(light, LIGHT_FADE_TWEEN, { Brightness = 0 }):Play()
	Debris:AddItem(lightAtt, ARC_LIFETIME + 0.1)

	-- ── Jitter arcs (optional sub-arcs for detail) ─────────────────────
	-- Spawn 1 shorter secondary arc with a random midpoint offset to simulate
	-- the branching/jagged look of real lightning. Uses the same LightningBeam pool.
	-- The secondary arc is thinner and more transparent.
	local jitterOffset = Vector3.new(
		(math.random() - 0.5) * 3,
		(math.random() - 0.5) * 3,
		(math.random() - 0.5) * 3
	)
	local jitterMid = midPoint + jitterOffset

	-- First half of jitter arc: fromPos → jitterMid
	local halfDiff1 = jitterMid - fromPos
	local halfDist1 = halfDiff1.Magnitude
	if halfDist1 > 0.5 then
		local jitter1 = VFXPool:GetPart("LightningBeam")
		jitter1.Color = arcColor
		jitter1.Size = Vector3.new(0.04, 0.04, halfDist1)
		jitter1.CFrame = CFrame.lookAt((fromPos + jitterMid) / 2, jitterMid)
		jitter1.Transparency = 0.4
		jitter1.Parent = workspace
		TweenService:Create(jitter1, ARC_FADE_TWEEN, { Transparency = 1 }):Play()
		VFXPool:ReturnPartDelayed("LightningBeam", jitter1, ARC_RETURN_DELAY)
	end

	-- Second half: jitterMid → toPos
	local halfDiff2 = toPos - jitterMid
	local halfDist2 = halfDiff2.Magnitude
	if halfDist2 > 0.5 then
		local jitter2 = VFXPool:GetPart("LightningBeam")
		jitter2.Color = arcColor
		jitter2.Size = Vector3.new(0.04, 0.04, halfDist2)
		jitter2.CFrame = CFrame.lookAt((jitterMid + toPos) / 2, toPos)
		jitter2.Transparency = 0.4
		jitter2.Parent = workspace
		TweenService:Create(jitter2, ARC_FADE_TWEEN, { Transparency = 1 }):Play()
		VFXPool:ReturnPartDelayed("LightningBeam", jitter2, ARC_RETURN_DELAY)
	end
end

-- ── Public: PlayChain ─────────────────────────────────────────────────────────

--[[
	LightningVFX:PlayChain(bounces, isCrit?)

	Renders a full chain-lightning sequence as a cascade of arc segments.
	Each arc appears BOUNCE_CASCADE_DELAY seconds after the previous one,
	creating the visual of electricity travelling from target to target.

	@param bounces  {{From: Vector3, To: Vector3}}  Array of bounce segments.
	                Provided by the ChainLightningVFX remote from ProcService.
	@param isCrit   boolean?  If true, uses the gold crit colour palette.
]]
function LightningVFX:PlayChain(bounces: { { From: Vector3, To: Vector3 } }, isCrit: boolean?)
	if not bounces or #bounces == 0 then
		return
	end

	local arcColor = if isCrit then CRIT_ARC else NORMAL_ARC
	local coreColor = if isCrit then CRIT_CORE else NORMAL_CORE

	task.spawn(function()
		for i, bounce in bounces do
			-- Validate both positions before spawning.
			if typeof(bounce.From) ~= "Vector3" or typeof(bounce.To) ~= "Vector3" then
				continue
			end

			_playArc(bounce.From, bounce.To, arcColor, coreColor)

			-- Cascade delay: don't wait after the last arc.
			if i < #bounces then
				task.wait(BOUNCE_CASCADE_DELAY)
			end
		end
	end)
end

-- ── Public: PlaySingle ────────────────────────────────────────────────────────

--[[
	LightningVFX:PlaySingle(fromPos, toPos, isCrit?)

	Convenience wrapper for a single-arc lightning effect (e.g. skill usage,
	environmental hazard). Skips the cascade delay.
]]
function LightningVFX:PlaySingle(fromPos: Vector3, toPos: Vector3, isCrit: boolean?)
	local arcColor = if isCrit then CRIT_ARC else NORMAL_ARC
	local coreColor = if isCrit then CRIT_CORE else NORMAL_CORE
	_playArc(fromPos, toPos, arcColor, coreColor)
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

function LightningVFX:Init()
	print("[LightningVFX] Initialized")
end

function LightningVFX:Start()
	print("[LightningVFX] Started")
end

return LightningVFX
