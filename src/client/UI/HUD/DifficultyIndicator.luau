--[[
    DifficultyIndicator.luau
    Displays current run difficulty, tier, and timer.
    Uses Fusion 0.3 for reactive UI updates.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Fusion = require(ReplicatedStorage.Packages.Fusion)
local DirectorConfig = require(ReplicatedStorage.Shared.Config.DirectorConfig)

-- Fusion 0.3 API
local scoped = Fusion.scoped
local Children = Fusion.Children
local Computed = Fusion.Computed
local OnEvent = Fusion.OnEvent

-- Types
type Scope = Fusion.Scope<typeof(Fusion)>

local DifficultyIndicator = {}

--[[
    Format seconds into MM:SS
]]
local function formatTime(seconds: number): string
	local m = math.floor(seconds / 60)
	local s = math.floor(seconds % 60)
	return string.format("%02d:%02d", m, s)
end

--[[
    Create the DifficultyIndicator component
    Returns: cleanup function
]]
function DifficultyIndicator.new(stormController: any): () -> ()
	-- Create scope for memory management
	local scope = scoped(Fusion)

	-- State
	local currentDifficulty = scope:Value(DirectorConfig.BaseDifficulty)
	local currentTierName = scope:Value("Drizzle")
	local currentTierColor = scope:Value(Color3.fromRGB(100, 200, 255))
	local runTime = scope:Value(0)

	-- Timer loop
	local lastTime = os.clock()
	local timerConnection = RunService.Heartbeat:Connect(function()
		local now = os.clock()
		local dt = now - lastTime
		lastTime = now

		-- We interpolate time locally between server updates for smoothness
		-- But for now, we just rely on server updates for the "real" time
		-- Or we could run a local timer if IsRunning is true.
		-- Let's just stick to server updates + local interpolation if needed later.
	end)

	-- Listen to difficulty updates from StormController
	-- We need to access the underlying signal or event from StormController
	-- Since StormController receives updates via remote, we can add a signal there or listen to the remote here.
	-- Better practice: StormController exposes a Signal or we listen to the remote directly if StormController doesn't.
	-- Looking at StormController.luau, it doesn't expose a Signal for UI updates yet.
	-- I should probably add a Signal to StormController or just listen to the remote here too.
	-- Or, better, modify StormController to expose 'OnDifficultyChanged'.

	-- For now, let's look at how we can get the data.
	-- StormController listens to `DirectorConfig.Remotes.DifficultyUpdate`.
	-- I can also listen to that remote here.

	local remotesFolder = ReplicatedStorage:WaitForChild("Remotes")
	local difficultyRemote = remotesFolder:WaitForChild(DirectorConfig.Remotes.DifficultyUpdate)

	local remoteConnection = difficultyRemote.OnClientEvent:Connect(function(data)
		currentDifficulty:set(data.Difficulty)
		currentTierName:set(data.TierName)
		currentTierColor:set(data.TierColor)
		runTime:set(data.RunTime)
	end)

	-- Helper to format difficulty multiplier
	local difficultyText = Computed(scope, function(use)
		local diff = use(currentDifficulty)
		return string.format("%.1fx", diff)
	end)

	-- Helper to format time
	local timeText = Computed(scope, function(use)
		return formatTime(use(runTime))
	end)

	-- Create UI
	local LocalPlayer = Players.LocalPlayer
	local playerGui = LocalPlayer:WaitForChild("PlayerGui")

	local screenGui = scope:New("ScreenGui")({
		Name = "DifficultyIndicatorGui",
		Parent = playerGui,
		ResetOnSpawn = false,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		DisplayOrder = 5,

		[Children] = {
			-- Main Container (Top Right)
			scope:New("Frame")({
				Name = "Container",
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -20, 0, 10), -- Top right padding
				Size = UDim2.new(0, 200, 0, 60),
				BackgroundTransparency = 1,

				[Children] = {
					-- Timer (Top)
					scope:New("TextLabel")({
						Name = "Timer",
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.new(1, 0, 0, 0),
						Size = UDim2.new(1, 0, 0, 30),
						BackgroundTransparency = 1,
						Text = timeText,
						TextColor3 = Color3.fromRGB(220, 220, 220),
						TextSize = 24,
						Font = Enum.Font.GothamBold,
						TextXAlignment = Enum.TextXAlignment.Right,

						[Children] = {
							scope:New("UIStroke")({
								Color = Color3.new(0, 0, 0),
								Thickness = 2,
								Transparency = 0.5,
							}),
						},
					}),

					-- Difficulty Bar/Info (Below Timer)
					scope:New("Frame")({
						Name = "DifficultyInfo",
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.new(1, 0, 0, 35),
						Size = UDim2.new(1, 0, 0, 25),
						BackgroundTransparency = 1,

						[Children] = {
							-- Multiplier (Rightmost)
							scope:New("TextLabel")({
								Name = "Multiplier",
								AnchorPoint = Vector2.new(1, 0.5),
								Position = UDim2.new(1, 0, 0.5, 0),
								Size = UDim2.new(0, 60, 1, 0),
								BackgroundTransparency = 1,
								Text = difficultyText,
								TextColor3 = Color3.fromRGB(200, 200, 200),
								TextSize = 18,
								Font = Enum.Font.GothamBold,
								TextXAlignment = Enum.TextXAlignment.Right,
								[Children] = {
									scope:New("UIStroke")({
										Color = Color3.new(0, 0, 0),
										Thickness = 1.5,
										Transparency = 0.5,
									}),
								},
							}),

							-- Tier Name (Left of Multiplier)
							scope:New("TextLabel")({
								Name = "TierName",
								AnchorPoint = Vector2.new(1, 0.5),
								Position = UDim2.new(1, -65, 0.5, 0),
								Size = UDim2.new(1, -70, 1, 0),
								BackgroundTransparency = 1,
								Text = currentTierName,
								TextColor3 = currentTierColor,
								TextSize = 16,
								Font = Enum.Font.GothamBlack,
								TextXAlignment = Enum.TextXAlignment.Right,
								[Children] = {
									scope:New("UIStroke")({
										Color = Color3.new(0, 0, 0),
										Thickness = 1.5,
										Transparency = 0.5,
									}),
								},
							}),
						},
					}),

					-- Difficulty Progress Bar (Optional visual flare)
					scope:New("Frame")({
						Name = "ProgressBarContainer",
						AnchorPoint = Vector2.new(1, 0),
						Position = UDim2.new(1, 0, 1, 5),
						Size = UDim2.new(1, 0, 0, 4),
						BackgroundColor3 = Color3.new(0, 0, 0),
						BackgroundTransparency = 0.5,
						BorderSizePixel = 0,

						[Children] = {
							scope:New("UICorner")({ CornerRadius = UDim.new(0, 2) }),

							scope:New("Frame")({
								Name = "Fill",
								Size = Computed(scope, function(use)
									-- Calculate progress to next tier?
									-- Or just show total difficulty progress relative to max
									local d = use(currentDifficulty)
									local max = DirectorConfig.MaxDifficulty
									local min = DirectorConfig.BaseDifficulty
									local p = math.clamp((d - min) / (max - min), 0, 1)
									return UDim2.new(p, 0, 1, 0)
								end),
								BackgroundColor3 = currentTierColor,
								BorderSizePixel = 0,
								[Children] = {
									scope:New("UICorner")({ CornerRadius = UDim.new(0, 2) }),
								},
							}),
						},
					}),
				},
			}),
		},
	})

	-- Return cleanup function
	return function()
		timerConnection:Disconnect()
		remoteConnection:Disconnect()
		Fusion.doCleanup(scope)
	end
end

return DifficultyIndicator
