--[[
    ItemDiscoveryScreen.luau
    Anime-style pop-up when gaining a new item.
    Shows name, icon, description, and rarity color.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local ItemRegistry = require(ReplicatedStorage.Shared.Config.ItemRegistry)

-- Fusion 0.3 API
local scoped = Fusion.scoped
local Children = Fusion.Children
local Computed = Fusion.Computed
local OnEvent = Fusion.OnEvent

-- Types
type Scope = Fusion.Scope<typeof(Fusion)>
type UsedAs<T> = Fusion.UsedAs<T>
type Value<T> = Fusion.Value<T>

local ItemDiscoveryScreen = {}

--[[
    Components
]]

local function RarityBar(scope: Scope, props: {
	RarityColor: UsedAs<Color3>,
	Transparency: UsedAs<number>,
}): Instance
	return scope:New("Frame")({
		Name = "RarityBar",
		Size = UDim2.new(1, 0, 0, 2),
		Position = UDim2.new(0, 0, 1, 0),
		BackgroundColor3 = props.RarityColor,
		BackgroundTransparency = props.Transparency,
	})
end

local function ItemNameLabel(scope: Scope, props: {
	ItemData: UsedAs<any>,
	Transparency: UsedAs<number>,
}): Instance
	return scope:New("TextLabel")({
		Name = "ItemName",
		Size = UDim2.new(1, 0, 0, 40),
		Position = UDim2.new(0, 0, 0, 10),
		BackgroundTransparency = 1,
		Text = Computed(scope, function(use)
			local data = use(props.ItemData)
			return data and data.Name:upper() or ""
		end),
		TextColor3 = Color3.new(1, 1, 1),
		TextTransparency = props.Transparency,
		Font = Enum.Font.GothamBlack,
		TextSize = 32,
		TextStrokeTransparency = Computed(scope, function(use)
			return 0.5 + (use(props.Transparency) * 0.5)
		end),
	})
end

local function RarityLabel(scope: Scope, props: {
	ItemData: UsedAs<any>,
	RarityColor: UsedAs<Color3>,
	Transparency: UsedAs<number>,
}): Instance
	return scope:New("TextLabel")({
		Name = "RarityLabel",
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.new(0, 0, 0, 45),
		BackgroundTransparency = 1,
		Text = Computed(scope, function(use)
			local data = use(props.ItemData)
			return data and data.Rarity:upper() or ""
		end),
		TextColor3 = props.RarityColor,
		TextTransparency = props.Transparency,
		Font = Enum.Font.GothamBold,
		TextSize = 14,
	})
end

local function DescriptionLabel(scope: Scope, props: {
	ItemData: UsedAs<any>,
	Transparency: UsedAs<number>,
}): Instance
	return scope:New("TextLabel")({
		Name = "Description",
		Size = UDim2.new(1, 0, 0, 20),
		Position = UDim2.new(0, 0, 0, 65),
		BackgroundTransparency = 1,
		Text = Computed(scope, function(use)
			local data = use(props.ItemData)
			return data and data.Description or ""
		end),
		TextColor3 = Color3.fromRGB(200, 200, 200),
		TextTransparency = props.Transparency,
		Font = Enum.Font.Gotham,
		TextSize = 16,
	})
end

local function NotificationFrame(scope: Scope, props: {
	ItemData: UsedAs<any>,
	RarityColor: UsedAs<Color3>,
	Transparency: UsedAs<number>,
}): Instance
	return scope:New("Frame")({
		Name = "NotificationFrame",
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.new(0.5, 0, 0.3, 0), -- Upper middle
		Size = UDim2.new(0, 400, 0, 100),
		BackgroundTransparency = 1,

		[Children] = {
			RarityBar(scope, {
				RarityColor = props.RarityColor,
				Transparency = props.Transparency,
			}),
			ItemNameLabel(scope, {
				ItemData = props.ItemData,
				Transparency = props.Transparency,
			}),
			RarityLabel(scope, {
				ItemData = props.ItemData,
				RarityColor = props.RarityColor,
				Transparency = props.Transparency,
			}),
			DescriptionLabel(scope, {
				ItemData = props.ItemData,
				Transparency = props.Transparency,
			}),
		},
	})
end

--[[
    Create the Item Discovery UI
]]
function ItemDiscoveryScreen.new(): { show: (itemKey: string) -> (), destroy: () -> () }
	local scope = scoped(Fusion)

	-- State
	local isVisible = scope:Value(false)
	local currentItemKey = scope:Value("")
	local transparency = scope:Value(1)

	-- Computed data
	local itemData = Computed(scope, function(use)
		local key = use(currentItemKey)
		return ItemRegistry.GetItem(key)
	end)

	local rarityColor = Computed(scope, function(use)
		local data = use(itemData)
		if not data then
			return Color3.new(1, 1, 1)
		end
		return ItemRegistry.Rarities[data.Rarity] or Color3.new(1, 1, 1)
	end)

	-- Component
	local notificationFrame = NotificationFrame(scope, {
		ItemData = itemData,
		RarityColor = rarityColor,
		Transparency = transparency,
	})

	-- UI
	local LocalPlayer = Players.LocalPlayer
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = scope:New("ScreenGui")({
		Name = "ItemDiscoveryGui",
		Parent = playerGui,
		IgnoreGuiInset = true,
		DisplayOrder = 200, -- Top priority
		Enabled = isVisible,

		[Children] = {
			notificationFrame,
		},
	})

	local api = {
		show = function(itemKey: string)
			currentItemKey:set(itemKey)
			isVisible:set(true)
			transparency:set(1)

			-- Animate in
			local tweenIn = TweenService:Create(
				notificationFrame,
				TweenInfo.new(0.5, Enum.EasingStyle.Back, Enum.EasingDirection.Out),
				{ Position = UDim2.new(0.5, 0, 0.35, 0) }
			)

			-- Fade in state
			task.spawn(function()
				local start = tick()
				while tick() - start < 0.5 do
					transparency:set(1 - ((tick() - start) / 0.5))
					task.wait()
				end
				transparency:set(0)
			end)

			notificationFrame.Position = UDim2.new(0.5, 0, 0.25, 0)
			tweenIn:Play()

			-- Wait then fade out
			task.delay(2.5, function()
				local start = tick()
				while tick() - start < 0.5 do
					transparency:set((tick() - start) / 0.5)
					task.wait()
				end
				transparency:set(1)
				isVisible:set(false)
			end)
		end,

		destroy = function()
			Fusion.doCleanup(scope)
		end,
	}

	return api
end

return ItemDiscoveryScreen
