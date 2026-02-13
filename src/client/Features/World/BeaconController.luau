--[[
    BeaconController.luau
    Client-side objective visualization.
    Handles progress bars and visual feedback for beacons.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TweenService = game:GetService("TweenService")

-- Wait for shared modules
local Shared = ReplicatedStorage:WaitForChild("Shared")
local Remotes = require(Shared:WaitForChild("Remotes"))
local WorldConfig = require(Shared:WaitForChild("Config"):WaitForChild("WorldConfig"))

local BeaconController = {
	Name = "BeaconController",
}

-- UI Constants
local BAR_WIDTH = 6
local BAR_HEIGHT = 0.6

-- Tracked UI elements
-- { [Instance]: { Billboard: BillboardGui, FillBar: Frame, Label: TextLabel } }
local beaconUIs = {}

--[[
    Create progress UI for a beacon
]]
local function createBeaconUI(instance: Instance)
	if not instance then
		return
	end
	if beaconUIs[instance] then
		return
	end

	local posPart = (instance:IsA("BasePart") and instance)
		or (instance:IsA("Model") and (instance.PrimaryPart or instance:FindFirstChildWhichIsA("BasePart")))
	if not posPart then
		return
	end

	-- Create Billboard
	local billboard = Instance.new("BillboardGui")
	billboard.Name = "BeaconProgressUI"
	billboard.Size = UDim2.fromScale(BAR_WIDTH, BAR_HEIGHT)
	billboard.StudsOffset = Vector3.new(0, 5, 0)
	billboard.AlwaysOnTop = true
	billboard.LightInfluence = 0
	billboard.Adornee = posPart
	billboard.Parent = posPart

	-- Background
	local bg = Instance.new("Frame")
	bg.Name = "Background"
	bg.Size = UDim2.fromScale(1, 1)
	bg.BackgroundColor3 = Color3.fromRGB(20, 20, 25)
	bg.BackgroundTransparency = 0.3
	bg.Parent = billboard

	local bgCorner = Instance.new("UICorner")
	bgCorner.CornerRadius = UDim.new(0, 4)
	bgCorner.Parent = bg

	-- Fill Bar
	local fill = Instance.new("Frame")
	fill.Name = "Fill"
	fill.Size = UDim2.fromScale(0, 1)
	fill.BackgroundColor3 = WorldConfig.Beacon.ActiveColor
	fill.BorderSizePixel = 0
	fill.Parent = bg

	local fillCorner = Instance.new("UICorner")
	fillCorner.CornerRadius = UDim.new(0, 4)
	fillCorner.Parent = fill

	-- Label
	local label = Instance.new("TextLabel")
	label.Name = "PercentLabel"
	label.Size = UDim2.fromScale(1, 1)
	label.BackgroundTransparency = 1
	label.Text = "BEACON READY"
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextSize = 14
	label.Font = Enum.Font.GothamBold
	label.TextStrokeTransparency = 0.5
	label.Parent = bg

	beaconUIs[instance] = {
		Billboard = billboard,
		FillBar = fill,
		Label = label,
	}
end

--[[
    Update progress visually
]]
local function onProgressUpdated(instance: Instance, progress: number)
	local ui = beaconUIs[instance]
	if not ui then
		createBeaconUI(instance)
		ui = beaconUIs[instance]
	end
	if not ui then
		return
	end

	-- Tween the fill bar
	TweenService:Create(ui.FillBar, TweenInfo.new(0.3), {
		Size = UDim2.fromScale(progress / 100, 1),
	}):Play()

	ui.Label.Text = string.format("CHARGING: %d%%", math.floor(progress))

	-- Update color based on charging state
	if progress > 0 and progress < 100 then
		ui.FillBar.BackgroundColor3 = WorldConfig.Beacon.ChargingColor
	end
end

--[[
    Update state visually
]]
local function onStateChanged(instance: Instance, newState: string)
	local ui = beaconUIs[instance]
	if not ui then
		return
	end

	if newState == "Completed" then
		ui.Label.Text = "BEACON DEFENDED"
		ui.FillBar.BackgroundColor3 = WorldConfig.Beacon.CompletedColor

		-- Brief completion pop effect
		TweenService:Create(ui.Billboard, TweenInfo.new(0.5, Enum.EasingStyle.Back), {
			Size = UDim2.fromScale(BAR_WIDTH * 1.2, BAR_HEIGHT * 1.2),
		}):Play()

		task.delay(5, function()
			if ui.Billboard then
				ui.Billboard.Enabled = false
			end
		end)
	elseif newState == "Inactive" then
		ui.Label.Text = "DEFEND BEACON"
		ui.FillBar.BackgroundColor3 = WorldConfig.Beacon.ActiveColor
	end
end

function BeaconController:Init()
	print("[BeaconController] Initializing...")
end

function BeaconController:Start()
	-- Listen for server events
	local progressRemote = Remotes:GetEvent("BeaconProgressUpdated")
	if progressRemote then
		progressRemote.OnClientEvent:Connect(onProgressUpdated)
	end

	local stateRemote = Remotes:GetEvent("BeaconStateChanged")
	if stateRemote then
		stateRemote.OnClientEvent:Connect(onStateChanged)
	end

	print("[BeaconController] Started")
end

return BeaconController
