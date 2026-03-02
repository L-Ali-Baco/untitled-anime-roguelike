--!strict
--[[
	ComicShaderController.luau
	==========================
	"Pure Ink" pass. Zero textures, zero per-frame loops.

	WHAT THIS DOES
	──────────────
	Two one-shot operations at startup, never repeated:

	  1. Material pass — iterates every BasePart on the local player's character
	     and on every CollectionService "Enemy"-tagged model, setting:
	         Material    = SmoothPlastic   (kills reflective surface variation)
	         Reflectance = 0               (eliminates plastic sheen)
	     SmoothPlastic at Reflectance=0 is a flat, matte surface. Combined with
	     Lighting.Ambient = [0,0,0], the shadow side of any model is absolute
	     black — no gradient, no midtone, just a hard ink line where the light
	     stops. This is the cheapest possible route to the "Pure Ink" read.

	  2. Lighting reinforcement — writes the four Lighting properties that
	     produce the inky high-contrast look. Run here so the visual state is
	     guaranteed regardless of what was set in Studio at edit time.

	WHY NO TEXTURES
	───────────────
	Texture injection (6 Instance.new() calls × N parts × N enemies) caused
	measurable spawn stutter on 30-enemy hordes and draw-call bloat at scale.
	The material pass creates zero new instances — it only writes properties
	on already-existing Parts, which is free by comparison.

	MOBILE
	──────
	PerformanceController.IsMobile = true → Start() returns after reinforcing
	lighting only. The material pass is skipped because mobile GPUs already
	benefit from SmoothPlastic defaults set by the AssetSanitizer script.
]]

-- ── Services ──────────────────────────────────────────────────────────────────

local CollectionService = game:GetService("CollectionService")
local Lighting          = game:GetService("Lighting")
local Players           = game:GetService("Players")

-- Hardware tier — set at load time by PerformanceController.
-- script.Parent = Client.VFX → .Parent = Client → .Core.PerformanceController
local PerformanceController = require(script.Parent.Parent.Core.PerformanceController)

-- ── Module ────────────────────────────────────────────────────────────────────

local ComicShaderController = {}
ComicShaderController.Name = "ComicShaderController"

-- ── Private: Material Pass ────────────────────────────────────────────────────

-- Iterates all BaseParts in `model` and forces the Pure Ink material state.
-- Skips:
--   • Transparency == 1  — invisible hitbox parts; no visual effect.
--   • Neon material      — glowing VFX parts (attack sparks, beacon glow).
--                          Overwriting Neon would kill bloom and break the
--                          lighting contrast the Pure Ink look depends on.
local function applyMaterialPass(model: Model)
	for _, desc in model:GetDescendants() do
		if not desc:IsA("BasePart") then
			continue
		end
		if desc.Transparency == 1 then
			continue
		end
		if desc.Material == Enum.Material.Neon then
			continue
		end
		desc.Material    = Enum.Material.SmoothPlastic
		desc.Reflectance = 0
	end
end

-- ── Private: Lighting Reinforcement ──────────────────────────────────────────

-- Writes the Lighting properties that produce the "playable ink" look:
-- deep shadows with enough fill to read silhouettes, and a punchy sun so
-- lit faces pop hard against the dark fill.
-- Called once in Start(); no ongoing cost.
--
-- Source of truth for all values: docs/LightingSetup.md (Mode 2 variant).
local function reinforceLighting()
	-- Neutral grey shadow fill. [130, 130, 130] ≈ 51% brightness with no
	-- colour bias — shadows are clearly darker than lit surfaces without
	-- being a void, and no warm/cool tint pushes the look in either direction.
	Lighting.Ambient        = Color3.fromRGB(130, 130, 130)
	Lighting.OutdoorAmbient = Color3.fromRGB(130, 130, 130)

	-- 2.5 is the standard Roblox ShadowMap brightness. Keeps lit faces well-
	-- exposed without the overblown appearance of higher values.
	Lighting.Brightness = 2.5

	-- Pure white sunlight and shadow tint — no colour cast on either face.
	Lighting.ColorShift_Top    = Color3.fromRGB(255, 255, 255)
	Lighting.ColorShift_Bottom = Color3.fromRGB(255, 255, 255)

	-- 0.5/0.5 restores Roblox's default PBR environment contributions.
	-- Surfaces receive normal indirect diffuse and specular from the sky,
	-- preserving the standard look while OutlineController highlights still
	-- provide the ink-line contrast on character and enemy edges.
	Lighting.EnvironmentDiffuseScale  = 0.5
	Lighting.EnvironmentSpecularScale = 0.5
end

-- ── Lifecycle ─────────────────────────────────────────────────────────────────

function ComicShaderController:Init()
	-- Nothing to pre-allocate. Material pass runs at Start() after all
	-- services are up and CollectionService tags have had time to replicate.
end

function ComicShaderController:Start()
	-- Lighting reinforcement runs on ALL tiers — mobile included.
	-- It writes four properties once; no ongoing cost.
	reinforceLighting()

	-- Mobile: skip the material pass entirely.
	-- The AssetSanitizer command-bar script (docs/AssetSanitizer_CommandBar.lua)
	-- bakes SmoothPlastic + Reflectance=0 into enemy models at author time,
	-- so the pass is redundant on mobile and we avoid iterating descendants
	-- on a low-RAM device.
	if PerformanceController.IsMobile then
		return
	end

	-- ── Material pass: local player ───────────────────────────────────────────

	local localPlayer = Players.LocalPlayer

	local function onCharacterAdded(character: Model)
		-- Defer one frame so the character's full descendant tree has loaded
		-- before we iterate it.
		task.defer(function()
			applyMaterialPass(character)
		end)
	end

	if localPlayer.Character then
		onCharacterAdded(localPlayer.Character)
	end
	localPlayer.CharacterAdded:Connect(onCharacterAdded)

	-- ── Material pass: enemies ────────────────────────────────────────────────
	-- Covers enemies that were tagged before this controller started, and all
	-- future spawns. Deferred for the same replication-timing reason as above.

	local function onEnemyTagged(instance: Instance)
		local model = if instance:IsA("Model")
			then instance
			else instance:FindFirstAncestorOfClass("Model")
		if model then
			task.defer(function()
				applyMaterialPass(model)
			end)
		end
	end

	for _, instance in CollectionService:GetTagged("Enemy") do
		onEnemyTagged(instance)
	end

	CollectionService:GetInstanceAddedSignal("Enemy"):Connect(onEnemyTagged)
end

-- ── Return ────────────────────────────────────────────────────────────────────

return ComicShaderController
