--[[
	EnemyHealthBar.luau
	World-space health bars that appear above enemies.
	
	Features:
	- BillboardGui for world-space positioning
	- Smooth damage animation (delayed red bar)
	- Fades in/out based on distance and combat state
	- Color changes based on health percentage
	- Optional enemy name display
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local EnemyConfig = require(ReplicatedStorage.Shared.Config.EnemyConfig)
local CombatConfig = require(ReplicatedStorage.Shared.Config.CombatConfig)
local ClassConfig = require(ReplicatedStorage.Shared.Config.ClassConfig)
local EnemyLib = require(ReplicatedStorage.Shared.Lib.EnemyLib)

local EnemyHealthBar = {}

-- Configuration
local Config = {
	-- Bar dimensions
	BarWidth = 4, -- Studs (BillboardGui size)
	BarHeight = 0.4,
	BarPixelHeight = 8, -- Actual pixel height of the bar

	-- Visibility
	MaxDistance = 100, -- Increased to accommodate ranged classes (Gunner 60 range)
	FadeStartDistance = 80, -- Start fading further out
	ShowWhenFullHealth = true, -- Always show bars so players can see enemy types/positions
	FadeInTime = 0.15,
	FadeOutTime = 0.3,

	-- Damage animation
	DamageDelayTime = 0.5, -- How long before red bar catches up
	DamageLerpSpeed = 3, -- How fast red bar moves

	-- Hit flash effect
	HitFlashEnabled = true,
	HitFlashColor = Color3.fromRGB(255, 255, 255), -- White flash on model
	HitFlashDuration = 0.15, -- How long the flash lasts (longer = more visible)
	HitFlashOutlineColor = Color3.fromRGB(255, 50, 50), -- Bright red outline
	HitFlashFillTransparency = 0.2, -- More opaque fill (lower = more visible)
	HitFlashOutlineTransparency = 0, -- Solid outline
	HealthBarFlashColor = Color3.fromRGB(255, 255, 255), -- White flash on bar

	-- Colors
	HealthColorHigh = Color3.fromRGB(80, 220, 100), -- Green (>60%)
	HealthColorMid = Color3.fromRGB(255, 200, 50), -- Yellow (30-60%)
	HealthColorLow = Color3.fromRGB(255, 70, 70), -- Red (<30%)
	DamageColor = Color3.fromRGB(180, 50, 50), -- Delayed damage bar
	BackgroundColor = Color3.fromRGB(20, 20, 20),
	BorderColor = Color3.fromRGB(40, 40, 40),

	-- Name display
	ShowName = true,
	NameTextSize = 12,
	NameColor = Color3.fromRGB(255, 255, 255),

	-- Attack range indicator (shows when enemy is in player's attack range)
	InRangeIndicatorEnabled = true,
	InRangeColor = Color3.fromRGB(255, 170, 0), -- Bright orange/gold outline when in range
	InRangeOutlineTransparency = 0, -- Solid outline (fully visible)
	InRangeFillTransparency = 0.8, -- Slight fill for extra visibility
	InRangeFallbackRange = 15, -- Fallback if class not detected
}

-- Active health bars
-- Key: enemy Model, Value: health bar data
local activeHealthBars: { [Model]: HealthBarData } = {}
local totalHighlights = 0
local MAX_HIGHLIGHTS = 31 -- Roblox limit is 31, use all of them

-- Type definition
type HealthBarData = {
	Enemy: Model,
	Humanoid: Humanoid,
	Billboard: BillboardGui,
	FillBar: Frame,
	DamageBar: Frame,
	NameLabel: TextLabel?,
	Highlight: Highlight?, -- Single highlight for both in-range and hit flash
	IsInRange: boolean,
	IsFlashing: boolean, -- Currently showing hit flash
	CurrentHealth: number,
	MaxHealth: number,
	DisplayedHealth: number, -- For smooth animation
	DelayedHealth: number, -- Red bar (delayed damage)
	LastDamageTime: number,
	IsVisible: boolean,
	Connections: { RBXScriptConnection },
}

local LocalPlayer = Players.LocalPlayer

-- Cache the player's attack range (updated when class changes)
local cachedPlayerAttackRange: number = Config.InRangeFallbackRange

--[[
	Calculate the player's attack range based on their current class
]]
local function getPlayerAttackRange(): number
	-- Check player's class from attribute
	local className = LocalPlayer:GetAttribute("Class")

	if not className then
		return Config.InRangeFallbackRange
	end

	local classData = ClassConfig[className]
	if not classData then
		return Config.InRangeFallbackRange
	end

	-- Use explicit HighlightRange if available (easiest configuration)
	if classData.HighlightRange then
		return classData.HighlightRange
	end

	-- Ranged class fallback: use RangedAttack.Range
	if classData.AttackType == "Ranged" and classData.RangedAttack then
		local range = classData.RangedAttack.Range or Config.InRangeFallbackRange
		return range
	end

	-- Melee class fallback: calculate from CombatConfig hitbox
	local attacks = classData.Attacks or CombatConfig.Attacks
	if attacks and attacks[1] then
		local firstAttack = attacks[1]
		local offset = firstAttack.HitboxOffset
		local size = firstAttack.HitboxSize
		if offset and size then
			local range = offset.Z + size.Z / 2
			return range
		end
	end

	return Config.InRangeFallbackRange
end

--[[
	Update the cached attack range (call when class changes)
]]
local function updateCachedAttackRange()
	cachedPlayerAttackRange = getPlayerAttackRange()
end

--[[
	Get health color based on percentage
]]
local function getHealthColor(percent: number): Color3
	if percent > 0.6 then
		return Config.HealthColorHigh
	elseif percent > 0.3 then
		-- Lerp between yellow and green
		local t = (percent - 0.3) / 0.3
		return Config.HealthColorMid:Lerp(Config.HealthColorHigh, t)
	else
		-- Lerp between red and yellow
		local t = percent / 0.3
		return Config.HealthColorLow:Lerp(Config.HealthColorMid, t)
	end
end

--[[
	Flash the enemy model when hit (white/red highlight)
	Uses the shared highlight - temporarily overrides in-range state
]]
local function flashEnemyModel(data: HealthBarData)
	if not Config.HitFlashEnabled or not data.Highlight then
		return
	end

	local highlight = data.Highlight
	data.IsFlashing = true

	-- Set flash colors (override in-range)
	highlight.FillColor = Config.HitFlashColor
	highlight.FillTransparency = Config.HitFlashFillTransparency
	highlight.OutlineColor = Config.HitFlashOutlineColor
	highlight.OutlineTransparency = Config.HitFlashOutlineTransparency
	highlight.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop

	-- Fade out the flash, then restore in-range state
	local startTime = os.clock()
	local duration = Config.HitFlashDuration
	local startFillTransparency = Config.HitFlashFillTransparency
	local startOutlineTransparency = Config.HitFlashOutlineTransparency

	local connection
	connection = RunService.Heartbeat:Connect(function()
		local elapsed = os.clock() - startTime
		local alpha = elapsed / duration

		if alpha >= 1 then
			connection:Disconnect()
			data.IsFlashing = false

			-- Restore to in-range state or hide
			highlight.DepthMode = Enum.HighlightDepthMode.Occluded
			if data.IsInRange and data.CurrentHealth > 0 then
				highlight.FillColor = Config.InRangeColor
				highlight.OutlineColor = Config.InRangeColor
				highlight.FillTransparency = Config.InRangeFillTransparency
				highlight.OutlineTransparency = Config.InRangeOutlineTransparency
			else
				highlight.FillTransparency = 1
				highlight.OutlineTransparency = 1
			end
			return
		end

		-- Fade transparency (ease out for snappier feel)
		local easedAlpha = alpha * alpha -- Quadratic ease
		highlight.FillTransparency = startFillTransparency + (1 - startFillTransparency) * easedAlpha
		highlight.OutlineTransparency = startOutlineTransparency + (1 - startOutlineTransparency) * easedAlpha
	end)
end

--[[
	Flash the health bar white when hit
]]
local function flashHealthBar(fillBar: Frame)
	if not Config.HitFlashEnabled then
		return
	end

	-- Store original color
	local originalColor = fillBar.BackgroundColor3

	-- Flash white
	fillBar.BackgroundColor3 = Config.HealthBarFlashColor

	-- Return to original color after brief delay
	task.delay(Config.HitFlashDuration * 0.5, function()
		if fillBar and fillBar.Parent then
			-- Tween back to health color
			local tweenBack = TweenService:Create(
				fillBar,
				TweenInfo.new(Config.HitFlashDuration, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
				{ BackgroundColor3 = originalColor }
			)
			tweenBack:Play()
		end
	end)
end

--[[
	Create highlight for an enemy (only if under limit)
]]
local function createHighlight(enemy: Model): Highlight?
	if totalHighlights >= MAX_HIGHLIGHTS then
		return nil
	end

	local highlight = Instance.new("Highlight")
	highlight.Name = "EnemyHighlight"
	highlight.Adornee = enemy
	highlight.FillColor = Config.InRangeColor
	highlight.FillTransparency = 1
	highlight.OutlineColor = Config.InRangeColor
	highlight.OutlineTransparency = 1
	highlight.DepthMode = Enum.HighlightDepthMode.Occluded
	highlight.Parent = enemy

	totalHighlights += 1
	return highlight
end

--[[
	Update in-range highlight visibility (only when not flashing)
]]
local function updateInRangeHighlight(data: HealthBarData, playerDistance: number)
	if not Config.InRangeIndicatorEnabled then
		return
	end

	-- Dynamically create highlight if we have room and it's missing
	if not data.Highlight and totalHighlights < MAX_HIGHLIGHTS then
		data.Highlight = createHighlight(data.Enemy)
	end

	if not data.Highlight then
		return
	end

	-- Don't update while flashing (hit flash takes priority)
	if data.IsFlashing then
		return
	end

	local highlight = data.Highlight

	-- Check if enemy is within player's attack range (uses cached class-based range)
	local shouldShow = playerDistance <= cachedPlayerAttackRange and data.CurrentHealth > 0

	if shouldShow and not data.IsInRange then
		-- Just entered range - show highlight
		data.IsInRange = true
		highlight.FillColor = Config.InRangeColor
		highlight.OutlineColor = Config.InRangeColor
		highlight.FillTransparency = Config.InRangeFillTransparency
		highlight.OutlineTransparency = Config.InRangeOutlineTransparency
	elseif not shouldShow and data.IsInRange then
		-- Just left range - hide highlight
		data.IsInRange = false
		highlight.FillTransparency = 1
		highlight.OutlineTransparency = 1
	end
end

--[[
	Create health bar UI for an enemy
]]
local function createHealthBar(enemy: Model, humanoid: Humanoid?): HealthBarData?
	-- Hide Roblox's default health bar (only if humanoid exists)
	if humanoid then
		humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
		humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	end

	-- Find attachment point (head or root)
	local head = enemy:FindFirstChild("Head")
	local rootPart = enemy:FindFirstChild("HumanoidRootPart") or enemy.PrimaryPart
	local attachPart = head or rootPart

	if not attachPart then
		return nil
	end

	-- Get enemy type config for offset
	local enemyType = enemy.Name
	local typeConfig = EnemyConfig.Types[enemyType]
	local offset = typeConfig and typeConfig.HealthBarOffset or Vector3.new(0, 3, 0)
	local showName = typeConfig and typeConfig.NameDisplayed or false

	-- Create BillboardGui
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "EnemyHealthBar"
	billboard.Adornee = attachPart
	billboard.Size = UDim2.fromScale(Config.BarWidth, Config.BarHeight)
	billboard.StudsOffset = offset
	billboard.AlwaysOnTop = false
	billboard.LightInfluence = 0
	billboard.MaxDistance = Config.MaxDistance
	billboard.ResetOnSpawn = false

	-- Container frame
	local container = Instance.new("Frame")
	container.Name = "Container"
	container.Size = UDim2.fromScale(1, 1)
	container.BackgroundTransparency = 1
	container.Parent = billboard

	-- Background bar
	local background = Instance.new("Frame")
	background.Name = "Background"
	background.AnchorPoint = Vector2.new(0.5, 0.5)
	background.Position = UDim2.fromScale(0.5, 0.5)
	background.Size = UDim2.new(1, 0, 0, Config.BarPixelHeight)
	background.BackgroundColor3 = Config.BackgroundColor
	background.BorderSizePixel = 0
	background.Parent = container

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 3)
	bgCorner.Parent = background

	local bgStroke = Instance.new("UIStroke")
	bgStroke.Color = Config.BorderColor
	bgStroke.Thickness = 1
	bgStroke.Transparency = 0.5
	bgStroke.Parent = background

	-- Damage bar (red, shows delayed damage)
	local damageBar = Instance.new("Frame")
	damageBar.Name = "DamageBar"
	damageBar.AnchorPoint = Vector2.new(0, 0.5)
	damageBar.Position = UDim2.fromScale(0, 0.5)
	damageBar.Size = UDim2.fromScale(1, 1)
	damageBar.BackgroundColor3 = Config.DamageColor
	damageBar.BorderSizePixel = 0
	damageBar.ZIndex = 1
	damageBar.Parent = background

	local dmgCorner = Instance.new("UICorner")
	dmgCorner.CornerRadius = UDim.new(0, 3)
	dmgCorner.Parent = damageBar

	-- Health fill bar (green/yellow/red)
	local fillBar = Instance.new("Frame")
	fillBar.Name = "FillBar"
	fillBar.AnchorPoint = Vector2.new(0, 0.5)
	fillBar.Position = UDim2.fromScale(0, 0.5)
	fillBar.Size = UDim2.fromScale(1, 1)
	fillBar.BackgroundColor3 = Config.HealthColorHigh
	fillBar.BorderSizePixel = 0
	fillBar.ZIndex = 2
	fillBar.Parent = background

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 3)
	fillCorner.Parent = fillBar

	-- Shine effect on fill bar
	local shine = Instance.new("Frame")
	shine.Name = "Shine"
	shine.Size = UDim2.fromScale(1, 0.4)
	shine.Position = UDim2.fromScale(0, 0)
	shine.BackgroundColor3 = Color3.fromRGB(255, 255, 255)
	shine.BackgroundTransparency = 0.85
	shine.BorderSizePixel = 0
	shine.ZIndex = 3
	shine.Parent = fillBar

	local shineCorner = Instance.new("UICorner")
	shineCorner.CornerRadius = UDim.new(0, 3)
	shineCorner.Parent = shine

	-- Name label (optional)
	local nameLabel: TextLabel? = nil
	if Config.ShowName and showName then
		nameLabel = Instance.new("TextLabel")
		nameLabel.Name = "EnemyName"
		nameLabel.AnchorPoint = Vector2.new(0.5, 1)
		nameLabel.Position = UDim2.new(0.5, 0, 0.5, -(Config.BarPixelHeight / 2) - 2)
		nameLabel.Size = UDim2.new(1, 0, 0, Config.NameTextSize)
		nameLabel.BackgroundTransparency = 1
		nameLabel.Text = enemyType
		nameLabel.TextColor3 = Config.NameColor
		nameLabel.TextSize = Config.NameTextSize
		nameLabel.Font = Enum.Font.GothamBold
		nameLabel.TextStrokeColor3 = Color3.fromRGB(0, 0, 0)
		nameLabel.TextStrokeTransparency = 0.5
		nameLabel.Parent = container
	end

	-- Parent to enemy (so it auto-destroys with enemy)
	billboard.Parent = enemy

	-- NOTE: Highlight is NOT created here anymore
	-- It will be created dynamically in updateInRangeHighlight when the enemy
	-- comes into attack range. This prevents wasting the highlight limit on
	-- far-away enemies that don't need highlighting yet.

	-- Create data
	local data: HealthBarData = {
		Enemy = enemy,
		Humanoid = humanoid, -- May be nil for attribute-based enemies
		Billboard = billboard,
		FillBar = fillBar,
		DamageBar = damageBar,
		NameLabel = nameLabel,
		Highlight = nil, -- Created dynamically when in range
		IsInRange = false,
		IsFlashing = false,
		CurrentHealth = EnemyLib:GetHealth(enemy),
		MaxHealth = EnemyLib:GetMaxHealth(enemy),
		DisplayedHealth = EnemyLib:GetHealth(enemy),
		DelayedHealth = EnemyLib:GetHealth(enemy),
		LastDamageTime = 0,
		IsVisible = true,
		Connections = {},
	}

	-- Listen to health changes via attributes (humanoid-free enemies)
	if enemy:GetAttribute("IsEnemy") then
		local healthConn = enemy:GetAttributeChangedSignal("Health"):Connect(function()
			local newHealth: number = (enemy:GetAttribute("Health") :: number?) or 0
			local oldHealth = data.CurrentHealth
			data.CurrentHealth = newHealth
			data.MaxHealth = (enemy:GetAttribute("MaxHealth") :: number?) or data.MaxHealth

			-- Immediately update fill bar for responsive feedback
			local healthPercent = math.max(0, newHealth / data.MaxHealth)
			data.FillBar.Size = UDim2.fromScale(healthPercent, 1)
			data.FillBar.BackgroundColor3 = getHealthColor(healthPercent)

			-- If took damage, trigger flash effects and reset delay timer
			if newHealth < oldHealth then
				data.LastDamageTime = os.clock()
				flashEnemyModel(data)
				flashHealthBar(data.FillBar)
			end

			-- Immediate update for healing
			if newHealth > oldHealth then
				data.DelayedHealth = newHealth
			end
		end)
		table.insert(data.Connections, healthConn)

		-- Listen for enemy death via IsDead attribute
		local diedConn = enemy:GetAttributeChangedSignal("IsDead"):Connect(function()
			if enemy:GetAttribute("IsDead") then
				-- Immediately show empty health bar
				data.CurrentHealth = 0
				data.FillBar.Size = UDim2.fromScale(0, 1)

				-- Immediately hide highlight
				if data.Highlight then
					data.Highlight.FillTransparency = 1
					data.Highlight.OutlineTransparency = 1
					data.IsInRange = false
					data.IsFlashing = false
				end

				-- Wait a moment to show the final hit, then fade out
				task.delay(0.5, function()
					if not data.Billboard or not data.Billboard.Parent then
						return
					end
					local fadeOutDamage = TweenService:Create(
						data.DamageBar,
						TweenInfo.new(Config.FadeOutTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ Size = UDim2.fromScale(0, 1) }
					)
					fadeOutDamage:Play()
					local fadeOut = TweenService:Create(
						container,
						TweenInfo.new(Config.FadeOutTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
						{ BackgroundTransparency = 1 }
					)
					fadeOut:Play()
					task.delay(Config.FadeOutTime, function()
						EnemyHealthBar:RemoveHealthBar(enemy)
					end)
				end)
			end
		end)
		table.insert(data.Connections, diedConn)
	elseif humanoid then
		-- Legacy Humanoid-based path (training dummies, etc)
		local healthConn = humanoid.HealthChanged:Connect(function(newHealth)
			local oldHealth = data.CurrentHealth
			data.CurrentHealth = newHealth

			local healthPercent = math.max(0, newHealth / data.MaxHealth)
			data.FillBar.Size = UDim2.fromScale(healthPercent, 1)
			data.FillBar.BackgroundColor3 = getHealthColor(healthPercent)

			if newHealth < oldHealth then
				data.LastDamageTime = os.clock()
				flashEnemyModel(data)
				flashHealthBar(data.FillBar)
			end

			if newHealth > oldHealth then
				data.DelayedHealth = newHealth
			end
		end)
		table.insert(data.Connections, healthConn)

		local diedConn = humanoid.Died:Connect(function()
			data.CurrentHealth = 0
			data.FillBar.Size = UDim2.fromScale(0, 1)
			if data.Highlight then
				data.Highlight.FillTransparency = 1
				data.Highlight.OutlineTransparency = 1
				data.IsInRange = false
				data.IsFlashing = false
			end
			task.delay(0.5, function()
				if not data.Billboard or not data.Billboard.Parent then
					return
				end
				local fadeOutDamage = TweenService:Create(
					data.DamageBar,
					TweenInfo.new(Config.FadeOutTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ Size = UDim2.fromScale(0, 1) }
				)
				fadeOutDamage:Play()
				local fadeOut = TweenService:Create(
					container,
					TweenInfo.new(Config.FadeOutTime, Enum.EasingStyle.Quad, Enum.EasingDirection.Out),
					{ BackgroundTransparency = 1 }
				)
				fadeOut:Play()
				task.delay(Config.FadeOutTime, function()
					EnemyHealthBar:RemoveHealthBar(enemy)
				end)
			end)
		end)
		table.insert(data.Connections, diedConn)
	end

	return data
end

--[[
	Predict damage locally for instant feedback
]]
function EnemyHealthBar:PredictDamage(enemy: Model, damage: number)
	local data = activeHealthBars[enemy]
	if not data then
		return
	end

	-- Update health
	local newHealth = math.max(0, data.CurrentHealth - damage)
	data.CurrentHealth = newHealth

	-- Update visuals immediately
	local healthPercent = newHealth / data.MaxHealth
	data.FillBar.Size = UDim2.fromScale(healthPercent, 1)
	data.FillBar.BackgroundColor3 = getHealthColor(healthPercent)

	-- Trigger flash effects
	data.LastDamageTime = os.clock()
	flashEnemyModel(data)
	flashHealthBar(data.FillBar)
end

--[[
	Update a single health bar
]]
local function updateHealthBar(data: HealthBarData, deltaTime: number)
	-- Validate the enemy model still exists
	if not data.Enemy or not data.Enemy.Parent then
		return
	end

	-- Always update distance-based visibility first (even for dead/invalid enemies)
	-- This ensures billboards show up for enemies that spawn out of range
	local character = LocalPlayer.Character
	local distance = math.huge -- Default to far away

	if character then
		local playerRoot = character:FindFirstChild("HumanoidRootPart")
		local enemyRoot = data.Enemy:FindFirstChild("HumanoidRootPart") or data.Enemy.PrimaryPart

		if playerRoot and enemyRoot then
			distance = (playerRoot.Position - enemyRoot.Position).Magnitude

			-- Update in-range highlight
			updateInRangeHighlight(data, distance)
		end
	end

	-- Calculate transparency based on distance
	local transparency = 0
	if distance > Config.FadeStartDistance then
		transparency = (distance - Config.FadeStartDistance) / (Config.MaxDistance - Config.FadeStartDistance)
		transparency = math.clamp(transparency, 0, 1)
	end

	-- Apply billboard visibility (always do this)
	data.Billboard.Enabled = transparency < 1

	-- Validate Adornee is still valid
	if data.Billboard.Enabled and not data.Billboard.Adornee then
		local head = data.Enemy:FindFirstChild("Head")
		local enemyRoot = data.Enemy:FindFirstChild("HumanoidRootPart") or data.Enemy.PrimaryPart
		local attachPart = head or enemyRoot
		if attachPart then
			data.Billboard.Adornee = attachPart
		end
	end

	-- Try to re-acquire health data if humanoid became invalid
	local currentHP = EnemyLib:GetHealth(data.Enemy)
	local maxHP = EnemyLib:GetMaxHealth(data.Enemy)

	if maxHP > 0 then
		data.CurrentHealth = currentHP
		data.MaxHealth = maxHP
	else
		-- No valid health source found
		return
	end

	-- Skip health bar updates if dead
	if currentHP <= 0 then
		return
	end

	local now = os.clock()
	local healthPercent = data.CurrentHealth / data.MaxHealth

	-- Update fill bar size and color
	data.FillBar.Size = UDim2.fromScale(math.max(0, healthPercent), 1)
	data.FillBar.BackgroundColor3 = getHealthColor(healthPercent)

	-- Update delayed damage bar
	if now - data.LastDamageTime > Config.DamageDelayTime then
		-- Lerp delayed health toward current health
		data.DelayedHealth = data.DelayedHealth
			+ (data.CurrentHealth - data.DelayedHealth) * deltaTime * Config.DamageLerpSpeed
		data.DelayedHealth = math.max(data.DelayedHealth, data.CurrentHealth)
	end

	local delayedPercent = data.DelayedHealth / data.MaxHealth
	data.DamageBar.Size = UDim2.fromScale(math.max(0, delayedPercent), 1)

	-- Hide when at full health (optional)
	if Config.ShowWhenFullHealth == false and healthPercent >= 1 then
		data.Billboard.Enabled = false
	end

	-- Apply transparency to UI elements when billboard is enabled
	if data.Billboard.Enabled then
		local container = data.Billboard:FindFirstChild("Container")
		if container then
			for _, child in container:GetDescendants() do
				if child:IsA("Frame") and child.Name ~= "Shine" then
					child.BackgroundTransparency = transparency * 0.7
				elseif child:IsA("TextLabel") then
					child.TextTransparency = transparency
					child.TextStrokeTransparency = 0.5 + transparency * 0.5
				elseif child:IsA("UIStroke") then
					child.Transparency = 0.5 + transparency * 0.5
				end
			end
		end
	end
end

--[[
	Create health bar for an enemy
]]
function EnemyHealthBar:CreateHealthBar(enemy: Model)
	-- Don't create duplicate
	if activeHealthBars[enemy] then
		return
	end

	-- Support both attribute-based enemies and Humanoid-based entities
	local humanoid = enemy:FindFirstChildOfClass("Humanoid")
	if not enemy:GetAttribute("IsEnemy") and not humanoid then
		return -- Neither attribute-based nor Humanoid-based
	end

	local data = createHealthBar(enemy, humanoid)
	if data then
		activeHealthBars[enemy] = data
	end
end

--[[
	Remove health bar for an enemy
]]
function EnemyHealthBar:RemoveHealthBar(enemy: Model)
	local data = activeHealthBars[enemy]
	if not data then
		return
	end

	-- Disconnect all connections
	for _, conn in data.Connections do
		conn:Disconnect()
	end

	-- Destroy billboard
	if data.Billboard and data.Billboard.Parent then
		data.Billboard:Destroy()
	end

	-- Destroy highlight and decrement counter
	if data.Highlight then
		if data.Highlight.Parent then
			data.Highlight:Destroy()
		end
		totalHighlights = math.max(0, totalHighlights - 1)
	end

	activeHealthBars[enemy] = nil
end

--[[
	Initialize - find existing enemies and set up listeners
]]
function EnemyHealthBar:Init()
	-- Initialize attack range based on current class (if any)
	updateCachedAttackRange()

	-- Listen for class changes to update attack range
	LocalPlayer:GetAttributeChangedSignal("Class"):Connect(function()
		updateCachedAttackRange()
		-- Force update all highlights immediately
		local character = LocalPlayer.Character
		if character then
			local playerRoot = character:FindFirstChild("HumanoidRootPart")
			if playerRoot then
				for _, data in activeHealthBars do
					local enemyRoot = data.Enemy:FindFirstChild("HumanoidRootPart") or data.Enemy.PrimaryPart
					if enemyRoot then
						local distance = (playerRoot.Position - enemyRoot.Position).Magnitude
						-- Reset in-range state to force a refresh
						data.IsInRange = false
						if data.Highlight then
							data.Highlight.FillTransparency = 1
							data.Highlight.OutlineTransparency = 1
						end
						updateInRangeHighlight(data, distance)
					end
				end
			end
		end
	end)

	-- Function to handle any model that should have a health bar
	local function onPotentialEnemy(enemy)
		if enemy:IsA("Model") then
			task.defer(function()
				self:CreateHealthBar(enemy)
			end)
		end
	end

	-- Listen for both 'Enemy' and 'TrainingDummy'
	local tags = { CombatConfig.Targeting.TargetTag, "TrainingDummy" }

	for _, tag in tags do
		-- Existing
		for _, enemy in CollectionService:GetTagged(tag) do
			onPotentialEnemy(enemy)
		end

		-- New (tag added)
		CollectionService:GetInstanceAddedSignal(tag):Connect(onPotentialEnemy)

		-- Removed
		CollectionService:GetInstanceRemovedSignal(tag):Connect(function(enemy)
			self:RemoveHealthBar(enemy)
		end)
	end

	-- ADDITIONAL: Watch for models being added to workspace
	-- This catches both Humanoid and attribute-based enemies
	local function checkForEnemy(instance)
		if not instance:IsA("Model") then
			return
		end

		-- Wait a short moment for tags/attributes to replicate
		task.delay(0.1, function()
			if not instance.Parent then
				return -- Already removed
			end

			-- Check for IsEnemy attribute (humanoid-free) or Humanoid
			local hasIdentifier = instance:GetAttribute("IsEnemy") or instance:FindFirstChildOfClass("Humanoid")
			if not hasIdentifier then
				return
			end

			-- Check if tagged as enemy or training dummy
			local isEnemy = CollectionService:HasTag(instance, CombatConfig.Targeting.TargetTag)
			local isDummy = CollectionService:HasTag(instance, "TrainingDummy")

			if isEnemy or isDummy then
				onPotentialEnemy(instance)
			end
		end)
	end

	-- Listen for descendants added to workspace (catches spawning enemies)
	workspace.DescendantAdded:Connect(checkForEnemy)

	-- Also scan workspace now for any models that might have been missed
	task.defer(function()
		for _, instance in workspace:GetDescendants() do
			if instance:IsA("Model") then
				local hasIdentifier = instance:GetAttribute("IsEnemy") or instance:FindFirstChildOfClass("Humanoid")
				if hasIdentifier then
					local isEnemy = CollectionService:HasTag(instance, CombatConfig.Targeting.TargetTag)
					local isDummy = CollectionService:HasTag(instance, "TrainingDummy")
					if isEnemy or isDummy then
						onPotentialEnemy(instance)
					end
				end
			end
		end
	end)

	-- Update loop
	RunService.Heartbeat:Connect(function(deltaTime)
		for _, data in activeHealthBars do
			updateHealthBar(data, deltaTime)
		end
	end)

	print("[EnemyHealthBar] Initialized!")
end

return EnemyHealthBar
