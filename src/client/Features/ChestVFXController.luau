--[[
	ChestVFXController.luau
	Client-side visual feedback for chest opening events.

	Receives "ChestOpened" from ChestService and plays two independent effects:

	  1. Lid tween: finds the "Lid" BasePart in the chest model and tweens its CFrame
	     by -90° around the local X axis (swinging the lid open backwards).
	     Done client-side for smooth 60 fps animation — server-side TweenService
	     replication introduces per-frame network lag that makes the tween stutter.

	  2. Item preview: spawns a temporary neon sphere above the chest, colour-coded by
	     rarity, tweens it upward (~3 studs over 0.5 s), holds for 1.5 s, then fades
	     out (Transparency 0→1 over 0.5 s) and destroys itself.
	     This gives the iconic "item floating above the chest" read from games like
	     Risk of Rain 2 and Binding of Isaac.
]]

local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))

local ChestVFXController = {
	Name = "ChestVFXController",
}

-- ============================================================
-- RARITY COLOUR MAP
-- ============================================================
-- Maps the rarity string (from LootManager) to a colour for the floating preview sphere.
-- These match the item card colours used in ItemSelectionScreen.
local RARITY_COLORS: { [string]: Color3 } = {
	Common = Color3.fromRGB(200, 200, 200), -- Neutral grey
	Uncommon = Color3.fromRGB(100, 220, 100), -- Soft green
	Rare = Color3.fromRGB(80, 140, 220), -- Bold blue
	Epic = Color3.fromRGB(160, 80, 220), -- Vibrant purple
	Legendary = Color3.fromRGB(255, 190, 0), -- Warm gold
}
local DEFAULT_COLOR = Color3.fromRGB(200, 200, 200) -- Fallback if rarity is unknown

-- ============================================================
-- LID TWEEN
-- ============================================================

-- How long the lid takes to swing open. Back easing overshoots slightly then settles
-- for a satisfying "thunk" feel.
local LID_TWEEN_DURATION = 0.55

--[[
	Tween the "Lid" part in chestModel open by rotating it -90° around its local X axis.
	The pivot is implicitly at the part's CFrame origin; since the lid's CFrame is
	set so its back edge aligns with the body's back edge, this creates a natural hinge.

	If the model has no "Lid" part (e.g. a custom asset without that part name),
	this function silently returns — the server has already granted the item so the
	player is never blocked.
]]
local function tweenLidOpen(chestModel: Model)
	local lid = chestModel:FindFirstChild("Lid") :: BasePart?
	if not lid then
		return
	end

	-- Target CFrame: rotate -90° around the lid's own X axis.
	-- CFrame * CFrame.Angles(radians, 0, 0) rotates in object space (local X = hinge axis).
	-- Negative angle swings the lid BACK and UP (away from the player standing in front).
	local targetCFrame = lid.CFrame * CFrame.Angles(math.rad(-90), 0, 0)

	local tweenInfo = TweenInfo.new(
		LID_TWEEN_DURATION,
		Enum.EasingStyle.Back, -- Slight overshoot for a physical "thud" feel
		Enum.EasingDirection.Out
	)
	local tween = TweenService:Create(lid, tweenInfo, { CFrame = targetCFrame })
	tween:Play()
end

-- ============================================================
-- ITEM PREVIEW FLOAT
-- ============================================================

-- Vertical rise: how many studs the sphere floats upward from its spawn point.
local PREVIEW_RISE_HEIGHT = 3.5 -- studs
-- Duration of the upward float tween.
local PREVIEW_RISE_DURATION = 0.5 -- seconds
-- How long the item hovers at peak before fading out.
local PREVIEW_HOLD_DURATION = 1.5 -- seconds
-- Duration of the transparency fade-out tween.
local PREVIEW_FADE_DURATION = 0.5 -- seconds

--[[
	Spawns a colour-coded neon sphere above the chest and animates it upward, holds,
	then fades it out and destroys it. Uses task.spawn so it doesn't yield the remote
	callback and block other effects from running simultaneously.
]]
local function spawnItemPreview(chestModel: Model, rarity: string)
	-- Find an appropriate anchor point (top of the Body part, or bounding box centre)
	local body = chestModel:FindFirstChild("Body") :: BasePart?
	local spawnPos: Vector3
	if body then
		-- Spawn just above the body's top face
		spawnPos = body.Position + Vector3.new(0, body.Size.Y / 2 + 1, 0)
	else
		local cf: CFrame = chestModel:GetBoundingBox()
		spawnPos = cf.Position + Vector3.new(0, 2, 0)
	end

	-- Build the preview sphere
	local sphere = Instance.new("Part")
	sphere.Name = "ChestItemPreview"
	sphere.Shape = Enum.PartType.Ball
	sphere.Size = Vector3.new(1.5, 1.5, 1.5)
	sphere.Color = RARITY_COLORS[rarity] or DEFAULT_COLOR
	sphere.Material = Enum.Material.Neon
	sphere.CastShadow = false
	sphere.CanCollide = false
	sphere.Anchored = true
	sphere.Transparency = 0
	sphere.CFrame = CFrame.new(spawnPos)
	sphere.Parent = workspace

	-- Run the float + fade sequence on its own thread so other VFX aren't blocked.
	task.spawn(function()
		-- Phase 1: float upward
		local riseTween = TweenService:Create(
			sphere,
			TweenInfo.new(PREVIEW_RISE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
			{ CFrame = CFrame.new(spawnPos + Vector3.new(0, PREVIEW_RISE_HEIGHT, 0)) }
		)
		riseTween:Play()
		riseTween.Completed:Wait()

		-- Phase 2: hover at peak
		task.wait(PREVIEW_HOLD_DURATION)

		-- Phase 3: fade out
		local fadeTween = TweenService:Create(
			sphere,
			TweenInfo.new(PREVIEW_FADE_DURATION, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ Transparency = 1 }
		)
		fadeTween:Play()
		fadeTween.Completed:Wait()

		sphere:Destroy()
	end)
end

-- ============================================================
-- LIFECYCLE
-- ============================================================

function ChestVFXController:Init()
	print("[ChestVFXController] Initializing...")
end

function ChestVFXController:Start()
	local remote = Remotes:GetEvent("ChestOpened")
	if not remote then
		warn("[ChestVFXController] 'ChestOpened' remote not found — chest VFX will not play")
		return
	end

	remote.OnClientEvent:Connect(function(payload: { [string]: any })
		-- Validate payload fields defensively
		local chestModel = payload.ChestModel
		local rarity = payload.Rarity or "Common"

		if not chestModel or not chestModel:IsA("Model") or not chestModel.Parent then
			return -- Model was removed before the remote arrived
		end

		-- Play both effects independently (neither blocks the other)
		tweenLidOpen(chestModel)
		spawnItemPreview(chestModel, rarity)
	end)

	print("[ChestVFXController] Started — listening for ChestOpened")
end

return ChestVFXController
