--[[
	FlameTest.client.luau
	Drop-in test script to preview the Biker King flamethrower VFX.
	Press F to toggle the flame stream on/off.
	Delete this file when done testing.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")
local Debris = game:GetService("Debris")

local FlamethrowerVFX = require(script.Parent.FlamethrowerVFX)

local player = Players.LocalPlayer
local active = false

local function toggle()
	local char = player.Character
	if not char then
		return
	end
	local root = char:FindFirstChild("HumanoidRootPart")
	if not root then
		return
	end

	if active then
		FlamethrowerVFX:StopStream()
		active = false
		print("[FlameTest] OFF")
	else
		FlamethrowerVFX:StartStream(root)
		active = true
		print("[FlameTest] ON — press F to toggle")
	end
end

UserInputService.InputBegan:Connect(function(input, processed)
	if processed then
		return
	end
	if input.KeyCode == Enum.KeyCode.F then
		toggle()
	end
end)

print("[FlameTest] Ready — press F to toggle flame stream")
