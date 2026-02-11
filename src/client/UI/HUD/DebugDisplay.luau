--[[
    DebugDisplay.luau
    Shows debug information on screen for testing.
    Automatically prints logs to Output every 5 seconds.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local HttpService = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer
local PlayerGui = LocalPlayer:WaitForChild("PlayerGui")

local DebugDisplay = {}

-- State
local screenGui: ScreenGui? = nil
local debugLabel: TextLabel? = nil
local debugLines: { string } = {}
local allLogs: { { time: number, source: string, message: string } } = {}
local MAX_LINES = 25
local connections: { RBXScriptConnection } = {}
local lastPrintTime = 0

--[[
    Add a debug line (will be displayed on screen)
]]
function DebugDisplay:Log(message: string, source: string?)
	local src = source or "CLIENT"
	local timeStr = os.date("%H:%M:%S")

	-- Store for export
	table.insert(allLogs, {
		time = os.clock(),
		timestamp = timeStr,
		source = src,
		message = message,
	})

	-- Keep max 100 logs
	while #allLogs > 100 do
		table.remove(allLogs, 1)
	end

	-- Format for display
	local displayLine = timeStr .. " [" .. src .. "] " .. message
	table.insert(debugLines, displayLine)

	-- Trim display to max lines
	while #debugLines > MAX_LINES do
		table.remove(debugLines, 1)
	end

	-- Update display
	if debugLabel then
		debugLabel.Text = table.concat(debugLines, "\n")
	end

	-- Also print to output
	print("[DEBUG][" .. src .. "]", message)
end

--[[
    Print all logs as JSON to Output
]]
function DebugDisplay:PrintLogsToOutput()
	local exportData = {
		exportTime = os.date("%Y-%m-%d %H:%M:%S"),
		playerName = LocalPlayer.Name,
		totalLogs = #allLogs,
		logs = allLogs,
	}

	local success, json = pcall(function()
		return HttpService:JSONEncode(exportData)
	end)

	if success then
		print("=== DEBUG LOGS JSON ===")
		print(json)
		print("=== END JSON ===")
	end
end

--[[
    Clear all debug lines
]]
function DebugDisplay:Clear()
	table.clear(debugLines)
	table.clear(allLogs)
	if debugLabel then
		debugLabel.Text = ""
	end
end

--[[
    Create the debug UI
]]
function DebugDisplay.new()
	-- Create ScreenGui
	screenGui = Instance.new("ScreenGui")
	screenGui.Name = "DebugDisplay"
	screenGui.ResetOnSpawn = false
	screenGui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	screenGui.Parent = PlayerGui

	-- Create background frame
	local frame = Instance.new("Frame")
	frame.Name = "DebugFrame"
	frame.Size = UDim2.new(0, 450, 0, 350)
	frame.Position = UDim2.new(0, 10, 0, 10)
	frame.BackgroundColor3 = Color3.fromRGB(20, 20, 20)
	frame.BackgroundTransparency = 0.2
	frame.BorderSizePixel = 2
	frame.BorderColor3 = Color3.fromRGB(0, 255, 0)
	frame.Parent = screenGui

	-- Create title
	local title = Instance.new("TextLabel")
	title.Name = "Title"
	title.Size = UDim2.new(1, 0, 0, 25)
	title.Position = UDim2.new(0, 0, 0, 0)
	title.BackgroundColor3 = Color3.fromRGB(0, 100, 0)
	title.BackgroundTransparency = 0.3
	title.Text = "DEBUG - Logs print to F9 console every 10s"
	title.TextColor3 = Color3.fromRGB(255, 255, 0)
	title.TextSize = 13
	title.Font = Enum.Font.SourceSansBold
	title.Parent = frame

	-- Create text label for debug output
	debugLabel = Instance.new("TextLabel")
	debugLabel.Name = "DebugText"
	debugLabel.Size = UDim2.new(1, -10, 1, -30)
	debugLabel.Position = UDim2.new(0, 5, 0, 28)
	debugLabel.BackgroundTransparency = 1
	debugLabel.Text = ""
	debugLabel.TextColor3 = Color3.fromRGB(0, 255, 0)
	debugLabel.TextSize = 11
	debugLabel.Font = Enum.Font.Code
	debugLabel.TextXAlignment = Enum.TextXAlignment.Left
	debugLabel.TextYAlignment = Enum.TextYAlignment.Top
	debugLabel.TextWrapped = true
	debugLabel.Parent = frame

	DebugDisplay:Log("Debug started", "SYSTEM")
	DebugDisplay:Log("Check F9 console for full logs", "SYSTEM")

	-- Auto-print logs every 10 seconds
	task.spawn(function()
		while screenGui and screenGui.Parent do
			task.wait(10)
			if #allLogs > 0 then
				DebugDisplay:PrintLogsToOutput()
			end
		end
	end)

	-- Listen for server debug messages
	task.spawn(function()
		local remotesFolder = ReplicatedStorage:WaitForChild("Remotes", 10)
		if remotesFolder then
			local debugRemote = remotesFolder:WaitForChild("DebugMessage", 5)
			if debugRemote then
				table.insert(
					connections,
					debugRemote.OnClientEvent:Connect(function(message)
						DebugDisplay:Log(message, "SERVER")
					end)
				)
				DebugDisplay:Log("Server debug connected", "SYSTEM")
			else
				DebugDisplay:Log("No server debug remote", "WARN")
			end
		end
	end)

	return function()
		if screenGui then
			screenGui:Destroy()
			screenGui = nil
		end
		for _, conn in connections do
			conn:Disconnect()
		end
		table.clear(connections)
	end
end

return DebugDisplay
