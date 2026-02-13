--[[
    SkillBar.luau
    Displays skill icons and cooldowns.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local SkillConfig = require(ReplicatedStorage.Shared.Config.SkillConfig)
local Remotes = require(ReplicatedStorage.Shared.Remotes)

local scoped = Fusion.scoped
local Children = Fusion.Children
local Computed = Fusion.Computed
local Value = Fusion.Value

-- Peek polyfill for older Fusion versions
local peek = Fusion.peek
	or function(state)
		if typeof(state) == "table" and state.get then
			return state:get(false)
		end
		return state
	end

local SkillBar = {}

local function Tooltip(scope, props)
	return scope:New("Frame")({
		Name = "Tooltip",
		ZIndex = 10,
		Position = UDim2.new(0.5, 0, 0, -10),
		AnchorPoint = Vector2.new(0.5, 1),
		Size = UDim2.new(0, 200, 0, 0), -- Auto size Y
		AutomaticSize = Enum.AutomaticSize.Y,
		BackgroundColor3 = Color3.fromRGB(20, 20, 20),
		BackgroundTransparency = 0.1,
		Visible = props.Visible,

		[Children] = {
			scope:New("UICorner")({ CornerRadius = UDim.new(0, 4) }),
			scope:New("UIStroke")({ Color = Color3.fromRGB(150, 150, 150), Thickness = 1 }),
			scope:New("UIPadding")({
				PaddingTop = UDim.new(0, 8),
				PaddingBottom = UDim.new(0, 8),
				PaddingLeft = UDim.new(0, 8),
				PaddingRight = UDim.new(0, 8),
			}),

			scope:New("UIListLayout")({
				SortOrder = Enum.SortOrder.LayoutOrder,
				Padding = UDim.new(0, 4),
			}),

			-- Name
			scope:New("TextLabel")({
				LayoutOrder = 1,
				Text = props.Name,
				TextColor3 = Color3.new(1, 1, 1),
				Font = Enum.Font.GothamBold,
				TextSize = 14,
				TextXAlignment = Enum.TextXAlignment.Left,
				AutomaticSize = Enum.AutomaticSize.XY,
				BackgroundTransparency = 1,
			}),

			-- Description
			scope:New("TextLabel")({
				LayoutOrder = 2,
				Text = props.Description,
				TextColor3 = Color3.fromRGB(200, 200, 200),
				Font = Enum.Font.Gotham,
				TextSize = 12,
				TextWrapped = true,
				TextXAlignment = Enum.TextXAlignment.Left,
				Size = UDim2.new(1, 0, 0, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				BackgroundTransparency = 1,
			}),

			-- Stats
			scope:New("TextLabel")({
				LayoutOrder = 3,
				Text = Computed(scope, function(use)
					local cd = use(props.Cooldown) or 0
					return string.format("Cooldown: %.1fs", cd)
				end),
				TextColor3 = Color3.fromRGB(100, 200, 255),
				Font = Enum.Font.GothamBold,
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Left,
				AutomaticSize = Enum.AutomaticSize.XY,
				BackgroundTransparency = 1,
			}),
		},
	})
end

local function SkillSlot(scope, props)
	local LocalPlayer = Players.LocalPlayer

	-- Props
	local skillName = props.SkillName
	local keybind = props.Keybind
	local icon = props.Icon
	local cooldownDuration = props.Cooldown
	local description = props.Description

	-- State
	local cooldownEnd = scope:Value(0)
	local now = scope:Value(tick())
	local isHovered = scope:Value(false)

	-- Listen for skill usage
	local conn = Remotes:GetEvent("SkillUsed").OnClientEvent:Connect(function(player, slot, data)
		if player == LocalPlayer then
			-- Unwrap computed props
			local currentName = peek(skillName)
			local currentDuration = peek(cooldownDuration)

			if data.Name == currentName then
				print("[SkillBar] Starting Cooldown for:", currentName, currentDuration)
				cooldownEnd:set(tick() + currentDuration)
			end
		end
	end)
	table.insert(scope, conn)

	-- Cooldown Sync
	local conn2 = Remotes:GetEvent("SkillCooldown").OnClientEvent:Connect(function(slot, remaining)
		if props.Slot == slot then
			cooldownEnd:set(tick() + remaining)
		end
	end)
	table.insert(scope, conn2)

	-- Update timer
	local hb = RunService.Heartbeat:Connect(function()
		now:set(tick())
	end)
	table.insert(scope, hb)

	-- Computed Progress
	local progress = Computed(scope, function(use)
		local duration = use(cooldownDuration)
		local remaining = math.max(0, use(cooldownEnd) - use(now))
		if remaining <= 0 or not duration or duration == 0 then
			return 0
		end
		return remaining / duration
	end)

	local textTime = Computed(scope, function(use)
		local remaining = math.max(0, use(cooldownEnd) - use(now))
		if remaining <= 0 then
			return ""
		end
		return string.format("%.1f", remaining)
	end)

	return scope:New("Frame")({
		Size = UDim2.new(0, 50, 0, 50),
		BackgroundColor3 = Color3.fromRGB(30, 30, 30),
		BackgroundTransparency = 0.3,

		[Fusion.OnEvent("MouseEnter")] = function()
			isHovered:set(true)
		end,
		[Fusion.OnEvent("MouseLeave")] = function()
			isHovered:set(false)
		end,

		[Children] = {
			scope:New("UICorner")({ CornerRadius = UDim.new(0, 6) }),
			scope:New("UIStroke")({ Color = Color3.fromRGB(100, 100, 100), Thickness = 2 }),

			-- Tooltip
			Tooltip(scope, {
				Visible = isHovered,
				Name = skillName,
				Description = description,
				Cooldown = cooldownDuration,
			}),

			-- Icon
			scope:New("ImageLabel")({
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Image = icon,
			}),

			-- Cooldown Overlay (Darkens icon)
			scope:New("Frame")({
				Size = Computed(scope, function(use)
					return UDim2.fromScale(1, use(progress))
				end),
				Position = UDim2.fromScale(0, 1),
				AnchorPoint = Vector2.new(0, 1),
				BackgroundColor3 = Color3.new(0, 0, 0),
				BackgroundTransparency = 0.5,
				BorderSizePixel = 0,
			}),

			-- Timer Text
			scope:New("TextLabel")({
				Size = UDim2.fromScale(1, 1),
				BackgroundTransparency = 1,
				Text = textTime,
				TextColor3 = Color3.new(1, 1, 1),
				Font = Enum.Font.GothamBold,
				TextSize = 18,
				TextStrokeTransparency = 0,
			}),

			-- Keybind Label
			scope:New("TextLabel")({
				Size = UDim2.new(1, 0, 0, 15),
				Position = UDim2.new(0, 0, 1, -2),
				AnchorPoint = Vector2.new(0, 1),
				BackgroundTransparency = 1,
				Text = keybind,
				TextColor3 = Color3.fromRGB(255, 255, 0),
				Font = Enum.Font.GothamBold,
				TextSize = 12,
				TextStrokeTransparency = 0,
			}),
		},
	})
end

function SkillBar.new(classController): () -> ()
	local scope = scoped(Fusion)
	local LocalPlayer = Players.LocalPlayer
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	-- Reactive Class State
	local currentClassName = scope:Value("Vanguard")

	-- Listen for class changes
	if classController then
		if classController:IsClassSelected() then
			local cls = classController:GetCurrentClass()
			if cls == "Warrior" then
				currentClassName:set("Vanguard")
			end
			if cls == "Gunner" then
				currentClassName:set("Gunslinger")
			end
		end

		local conn = classController.OnClassSelected:Connect(function(cls)
			print("[SkillBar] Class Changed:", cls)
			if cls == "Warrior" then
				currentClassName:set("Vanguard")
			end
			if cls == "Gunner" then
				currentClassName:set("Gunslinger")
			end
		end)
		table.insert(scope, conn)
	end

	-- Computed Skills Data
	local skillsData = Computed(scope, function(use)
		local name = use(currentClassName)
		return SkillConfig[name]
	end)

	-- Helper to get reactive prop for a slot
	local function getSkillProp(slot, prop)
		return Computed(scope, function(use)
			local data = use(skillsData)
			if not data or not data[slot] then
				return nil
			end
			return data[slot][prop]
		end)
	end

	local screenGui = scope:New("ScreenGui")({
		Name = "SkillBarGui",
		Parent = playerGui,
		ResetOnSpawn = false,

		[Children] = {
			scope:New("Frame")({
				Name = "Container",
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 1, -120), -- Above health bar
				Size = UDim2.new(0, 200, 0, 60),
				BackgroundTransparency = 1,

				[Children] = {
					scope:New("UIListLayout")({
						FillDirection = Enum.FillDirection.Horizontal,
						Padding = UDim.new(0, 10),
						HorizontalAlignment = Enum.HorizontalAlignment.Center,
					}),

					-- M2 (Secondary)
					SkillSlot(scope, {
						Slot = "Secondary",
						SkillName = getSkillProp("Secondary", "Name"),
						Icon = getSkillProp("Secondary", "Icon"),
						Cooldown = getSkillProp("Secondary", "Cooldown"),
						Description = getSkillProp("Secondary", "Description"),
						Keybind = "M2",
					}),

					-- E (Skill1)
					SkillSlot(scope, {
						Slot = "Skill1",
						SkillName = getSkillProp("Skill1", "Name"),
						Icon = getSkillProp("Skill1", "Icon"),
						Cooldown = getSkillProp("Skill1", "Cooldown"),
						Description = getSkillProp("Skill1", "Description"),
						Keybind = "E",
					}),

					-- R (Skill2)
					SkillSlot(scope, {
						Slot = "Skill2",
						SkillName = getSkillProp("Skill2", "Name"),
						Icon = getSkillProp("Skill2", "Icon"),
						Cooldown = getSkillProp("Skill2", "Cooldown"),
						Description = getSkillProp("Skill2", "Description"),
						Keybind = "R",
					}),
				},
			}),
		},
	})

	return function()
		Fusion.doCleanup(scope)
	end
end

return SkillBar
