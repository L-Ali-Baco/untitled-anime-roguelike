--[[
    test_vfx.spec.luau
    Tests for VFXPool and VFXSystem.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local StarterPlayer = game:GetService("StarterPlayer")
local Client = StarterPlayer.StarterPlayerScripts.Client

local VFXPool = require(Client.VFX.VFXPool)
local VFXSystem = require(Client.VFX.VFXSystem)

return function()
	describe("VFXPool", function()
		it("should recycle instances", function()
			local template = Instance.new("Part")
			template.Name = "TestPart"
			template.Transparency = 0.5

			-- Get new instance
			local p1 = VFXPool:Get("TestPool", template)
			expect(p1).to.be.ok()
			expect(p1.Name).to.equal("TestPool")
			expect(p1.Transparency).to.equal(0) -- Should be reset to 0 by Get (BasePart default in pool)

			-- Return to pool
			VFXPool:Return(p1, "TestPool")
			expect(p1.Parent).to.equal(nil)

			-- Reuse instance
			local p2 = VFXPool:Get("TestPool", template)
			expect(p2).to.equal(p1) -- Should reuse the same instance (table equality)
		end)

		it("should handle different types", function()
			local template = Instance.new("Attachment")
			local a1 = VFXPool:Get("AttPool", template)
			expect(a1:IsA("Attachment")).to.equal(true)
			VFXPool:Return(a1, "AttPool")
		end)
	end)

	describe("VFXSystem", function()
		it("should add effects without error", function()
			local part = Instance.new("Part")
			-- Add effect
			VFXSystem:Add(part, 1, { Transparency = 1 })

			-- Verify update loop runs safely
			-- We can't verify logic deeply without mocking os.clock, but we check for crashes
			VFXSystem._update(0.1)
		end)

		it("should handle callbacks", function()
			local part = Instance.new("Part")
			local called = false
			VFXSystem:Play(part, 1, function(inst, alpha)
				called = true
				expect(inst).to.equal(part)
			end)
			VFXSystem._update(0.1)
			expect(called).to.equal(true)
		end)
	end)
end
