--[[
    DamageNumbers.luau
    Floating damage text that pops up when damage is dealt.
    - Uses BillboardGui for world-space positioning
    - Floats upward and fades out
    - Color/size varies by damage type
]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)

local DamageNumbers = {}

-- Config shorthand
local Config = CombatConfig.DamageNumbers

-- Default damage type if not specified
local DEFAULT_TYPE = "Normal"

--[[
    Spawn a floating damage number at the given world position.
    @param position: World position to spawn at (typically enemy HumanoidRootPart position)
    @param damage: The damage amount to display
    @param damageType: Optional type of damage ("Normal", "Critical", "Finisher", etc.)
]]
function DamageNumbers:Spawn(position: Vector3, damage: number, damageType: string?)
	if not Config.Enabled then
		return
	end

	damageType = damageType or DEFAULT_TYPE

	-- Get color and size multiplier for this damage type
	local color = Config.Colors[damageType] or Config.Colors.Normal
	local sizeMultiplier = Config.SizeMultipliers[damageType] or 1.0

	-- Base billboard size (in studs), scaled by damage type
	local baseWidth = 4 * sizeMultiplier
	local baseHeight = 2 * sizeMultiplier

	-- Random X offset to prevent numbers from stacking
	local randomOffsetX = (math.random() - 0.5) * 2 * Config.RandomOffsetX
	local spawnPosition = position + Vector3.new(randomOffsetX, 0, 0)

	-- Create anchor part (invisible, just for BillboardGui attachment)
	local anchor = Instance.new("Part")
	anchor.Name = "DamageNumberAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Position = spawnPosition
	anchor.Parent = workspace

	-- Create BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DamageNumber"
	billboard.Size = UDim2.fromScale(baseWidth, baseHeight)
	billboard.StudsOffset = Vector3.new(0, 1, 0) -- Slightly above anchor
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Adornee = anchor
	billboard.Parent = anchor

	-- Create text label
	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "DamageText"
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.Position = UDim2.fromScale(0, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.Text = tostring(math.floor(damage))
	textLabel.TextColor3 = color
	textLabel.TextScaled = true
	textLabel.FontFace = Config.FontFace
	textLabel.TextTransparency = 0
	textLabel.Parent = billboard

	-- Add text stroke (outline) for readability
	if Config.StrokeEnabled then
		local stroke = Instance.new("UIStroke")
		stroke.Color = Config.StrokeColor
		stroke.Thickness = Config.StrokeThickness
		stroke.Transparency = 0
		stroke.Parent = textLabel
	end

	-- Initial scale pop effect
	local initialScale = 1.3
	billboard.Size = UDim2.fromScale(baseWidth * initialScale, baseHeight * initialScale)

	-- Pop-in tween (quick scale down to normal)
	local popTween = TweenService:Create(
		billboard,
		TweenInfo.new(0.1, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.fromScale(baseWidth, baseHeight) }
	)
	popTween:Play()

	-- Float upward animation
	local endPosition = spawnPosition + Vector3.new(0, Config.RiseHeight, 0)
	local floatTween = TweenService:Create(
		anchor,
		TweenInfo.new(Config.Duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = endPosition }
	)
	floatTween:Play()

	-- Fade out animation (starts after a brief delay)
	local fadeDelay = Config.Duration * 0.4 -- Start fading at 40% through
	local fadeDuration = Config.Duration * 0.6

	task.delay(fadeDelay, function()
		if not textLabel or not textLabel.Parent then
			return
		end

		local fadeTween = TweenService:Create(
			textLabel,
			TweenInfo.new(fadeDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ TextTransparency = 1 }
		)
		fadeTween:Play()

		-- Also fade stroke if present
		local stroke = textLabel:FindFirstChildOfClass("UIStroke")
		if stroke then
			local strokeFade = TweenService:Create(
				stroke,
				TweenInfo.new(fadeDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Transparency = 1 }
			)
			strokeFade:Play()
		end
	end)

	-- Cleanup
	Debris:AddItem(anchor, Config.Duration + 0.1)

	return anchor
end

--[[
    Spawn damage number attached to a character's HumanoidRootPart position.
    Convenience wrapper that extracts position from character.
    @param character: The character Model that was hit
    @param damage: The damage amount to display
    @param damageType: Optional type of damage
]]
function DamageNumbers:SpawnOnCharacter(character: Model, damage: number, damageType: string?)
	if not character then
		return
	end

	local rootPart = character:FindFirstChild("HumanoidRootPart")
	if not rootPart then
		-- Fallback to PrimaryPart or first part
		rootPart = character.PrimaryPart or character:FindFirstChildWhichIsA("BasePart")
	end

	if not rootPart then
		return
	end

	-- Spawn slightly above the character's head area
	local position = rootPart.Position + Vector3.new(0, 2, 0)
	return self:Spawn(position, damage, damageType)
end

--[[
    Spawn a healing number (green, floats up)
    @param position: World position to spawn at
    @param healAmount: The healing amount to display
]]
function DamageNumbers:SpawnHeal(position: Vector3, healAmount: number)
	return self:Spawn(position, healAmount, "Heal")
end

--[[
    Spawn healing number on a character
    @param character: The character Model being healed
    @param healAmount: The healing amount to display
]]
function DamageNumbers:SpawnHealOnCharacter(character: Model, healAmount: number)
	return self:SpawnOnCharacter(character, healAmount, "Heal")
end

--[[
    Spawn a text-based floating number (for "DODGE", "MISS", etc.)
    @param position: World position to spawn at
    @param text: The text to display
    @param damageType: The type (affects color/size) - e.g. "Dodge"
]]
function DamageNumbers:SpawnText(position: Vector3, text: string, damageType: string?)
	if not Config.Enabled then
		return
	end

	damageType = damageType or DEFAULT_TYPE

	-- Get color and size multiplier for this damage type
	local color = Config.Colors[damageType] or Config.Colors.Normal
	local sizeMultiplier = Config.SizeMultipliers[damageType] or 1.0

	-- Base billboard size (in studs), scaled by damage type
	local baseWidth = 4 * sizeMultiplier
	local baseHeight = 2 * sizeMultiplier

	-- Random X offset to prevent numbers from stacking
	local randomOffsetX = (math.random() - 0.5) * 2 * Config.RandomOffsetX
	local spawnPosition = position + Vector3.new(randomOffsetX, 0, 0)

	-- Create anchor part (invisible, just for BillboardGui attachment)
	local anchor = Instance.new("Part")
	anchor.Name = "DamageNumberAnchor"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.CastShadow = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(0.1, 0.1, 0.1)
	anchor.Position = spawnPosition
	anchor.Parent = workspace

	-- Create BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "DamageNumber"
	billboard.Size = UDim2.fromScale(baseWidth, baseHeight)
	billboard.StudsOffset = Vector3.new(0, 1, 0) -- Slightly above anchor
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Adornee = anchor
	billboard.Parent = anchor

	-- Create text label
	local textLabel = Instance.new("TextLabel")
	textLabel.Name = "DamageText"
	textLabel.Size = UDim2.fromScale(1, 1)
	textLabel.Position = UDim2.fromScale(0, 0)
	textLabel.BackgroundTransparency = 1
	textLabel.Text = text -- Use provided text directly
	textLabel.TextColor3 = color
	textLabel.TextScaled = true
	textLabel.FontFace = Config.FontFace
	textLabel.TextTransparency = 0
	textLabel.Parent = billboard

	-- Add text stroke (outline) for readability
	if Config.StrokeEnabled then
		local stroke = Instance.new("UIStroke")
		stroke.Color = Config.StrokeColor
		stroke.Thickness = Config.StrokeThickness
		stroke.Transparency = 0
		stroke.Parent = textLabel
	end

	-- Initial scale pop effect
	local initialScale = 1.3
	billboard.Size = UDim2.fromScale(baseWidth * initialScale, baseHeight * initialScale)

	-- Pop-in tween (quick scale down to normal)
	local popTween = TweenService:Create(
		billboard,
		TweenInfo.new(0.1, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
		{ Size = UDim2.fromScale(baseWidth, baseHeight) }
	)
	popTween:Play()

	-- Float upward animation
	local endPosition = spawnPosition + Vector3.new(0, Config.RiseHeight, 0)
	local floatTween = TweenService:Create(
		anchor,
		TweenInfo.new(Config.Duration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
		{ Position = endPosition }
	)
	floatTween:Play()

	-- Fade out animation (starts after a brief delay)
	local fadeDelay = Config.Duration * 0.4 -- Start fading at 40% through
	local fadeDuration = Config.Duration * 0.6

	task.delay(fadeDelay, function()
		if not textLabel or not textLabel.Parent then
			return
		end

		local fadeTween = TweenService:Create(
			textLabel,
			TweenInfo.new(fadeDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
			{ TextTransparency = 1 }
		)
		fadeTween:Play()

		-- Also fade stroke if present
		local stroke = textLabel:FindFirstChildOfClass("UIStroke")
		if stroke then
			local strokeFade = TweenService:Create(
				stroke,
				TweenInfo.new(fadeDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.In),
				{ Transparency = 1 }
			)
			strokeFade:Play()
		end
	end)

	-- Cleanup
	Debris:AddItem(anchor, Config.Duration + 0.1)

	return anchor
end

return DamageNumbers
