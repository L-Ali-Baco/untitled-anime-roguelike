--[[
    DamageNumbers.luau
    Floating damage text.
    Refactored to use VFXPool and VFXSystem.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")
local VFXPool = require(script.Parent.VFXPool)
local VFXSystem = require(script.Parent.VFXSystem)
local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)

local DamageNumbers = {}
local Config = CombatConfig.DamageNumbers
local DEFAULT_TYPE = "Normal"

local function getTemplate()
	local anchor = Instance.new("Part")
	anchor.Name = "DamageNumberAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)

	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DamageNumber"
	billboard.StudsOffset = Vector3.new(0, 1, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Adornee = anchor
	billboard.Parent = anchor

	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "DamageText"
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.BackgroundTransparency = 1
	textLabel.TextScaled = true
	textLabel.FontFace = Config.FontFace
	textLabel.Parent = billboard

	if Config.StrokeEnabled then
		local stroke = Instance.new("UIStroke")
		stroke.Name = "Stroke"
		stroke.Color = Config.StrokeColor
		stroke.Thickness = Config.StrokeThickness
		stroke.Parent = textLabel
	end

	return anchor
end

function DamageNumbers:Spawn(position: Vector3, damage: number, damageType: string?)
	if not Config.Enabled then return end
	damageType = damageType or DEFAULT_TYPE

	local color = Config.Colors[damageType] or Config.Colors.Normal
	local sizeMult = Config.SizeMultipliers[damageType] or 1.0
	local baseW = 4 * sizeMult
	local baseH = 2 * sizeMult

	local randomX = (math.random() - 0.5) * 2 * Config.RandomOffsetX
	local startPos = position + Vector3.new(randomX, 0, 0)
	local endPos = startPos + Vector3.new(0, Config.RiseHeight, 0)

	local anchor = VFXPool:Get("DamageNumberAnchor", getTemplate())
	anchor.Position = startPos
	anchor.Parent = workspace

	local bb = anchor:FindFirstChild("DamageNumber")
	local txt = bb and bb:FindFirstChild("DamageText")
	local stroke = txt and txt:FindFirstChild("Stroke")

	if txt then
		txt.Text = tostring(math.floor(damage))
		txt.TextColor3 = color
		txt.TextTransparency = 0
	end
	if stroke then
		stroke.Transparency = 0
	end

	local duration = Config.Duration
	local popDur = 0.1
	local fadeStart = 0.4

	local popStartSize = UDim2.fromScale(baseW * 1.3, baseH * 1.3)
	local normalSize = UDim2.fromScale(baseW, baseH)

	VFXSystem:Play(anchor, duration, function(inst, alpha)
		local posAlpha = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		inst.Position = startPos:Lerp(endPos, posAlpha)

		local popAlphaRaw = alpha * (duration / popDur)
		if popAlphaRaw <= 1 then
			local popAlpha = TweenService:GetValue(popAlphaRaw, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			if bb then
				bb.Size = popStartSize:Lerp(normalSize, popAlpha)
			end
		else
			if bb then bb.Size = normalSize end
		end

		if alpha > fadeStart then
			local fadeLocal = (alpha - fadeStart) / (1 - fadeStart)
			local fadeAlpha = TweenService:GetValue(fadeLocal, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			if txt then txt.TextTransparency = fadeAlpha end
			if stroke then stroke.Transparency = fadeAlpha end
		end
	end, {
		PoolName = "DamageNumberAnchor"
	})

	return anchor
end

function DamageNumbers:SpawnOnCharacter(character, damage, damageType)
	if not character then return end
	local root = character:FindFirstChild("HumanoidRootPart") or character.PrimaryPart
	if not root then return end
	return self:Spawn(root.Position + Vector3.new(0, 2, 0), damage, damageType)
end

function DamageNumbers:SpawnHeal(position, amount)
	return self:Spawn(position, amount, "Heal")
end

function DamageNumbers:SpawnHealOnCharacter(character, amount)
	return self:SpawnOnCharacter(character, amount, "Heal")
end

function DamageNumbers:SpawnText(position, text, damageType)
	if not Config.Enabled then return end
	damageType = damageType or DEFAULT_TYPE

	local color = Config.Colors[damageType] or Config.Colors.Normal
	local sizeMult = Config.SizeMultipliers[damageType] or 1.0
	local baseW = 4 * sizeMult
	local baseH = 2 * sizeMult

	local randomX = (math.random() - 0.5) * 2 * Config.RandomOffsetX
	local startPos = position + Vector3.new(randomX, 0, 0)
	local endPos = startPos + Vector3.new(0, Config.RiseHeight, 0)

	local anchor = VFXPool:Get("DamageNumberAnchor", getTemplate())
	anchor.Position = startPos
	anchor.Parent = workspace

	local bb = anchor:FindFirstChild("DamageNumber")
	local txt = bb and bb:FindFirstChild("DamageText")
	local stroke = txt and txt:FindFirstChild("Stroke")

	if txt then
		txt.Text = text
		txt.TextColor3 = color
		txt.TextTransparency = 0
	end
	if stroke then
		stroke.Transparency = 0
	end

	local duration = Config.Duration
	local popDur = 0.1
	local fadeStart = 0.4

	local popStartSize = UDim2.fromScale(baseW * 1.3, baseH * 1.3)
	local normalSize = UDim2.fromScale(baseW, baseH)

	VFXSystem:Play(anchor, duration, function(inst, alpha)
		local posAlpha = TweenService:GetValue(alpha, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
		inst.Position = startPos:Lerp(endPos, posAlpha)

		local popAlphaRaw = alpha * (duration / popDur)
		if popAlphaRaw <= 1 then
			local popAlpha = TweenService:GetValue(popAlphaRaw, Enum.EasingStyle.Back, Enum.EasingDirection.Out)
			if bb then
				bb.Size = popStartSize:Lerp(normalSize, popAlpha)
			end
		else
			if bb then bb.Size = normalSize end
		end

		if alpha > fadeStart then
			local fadeLocal = (alpha - fadeStart) / (1 - fadeStart)
			local fadeAlpha = TweenService:GetValue(fadeLocal, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
			if txt then txt.TextTransparency = fadeAlpha end
			if stroke then stroke.Transparency = fadeAlpha end
		end
	end, {
		PoolName = "DamageNumberAnchor"
	})

	return anchor
end

return DamageNumbers
