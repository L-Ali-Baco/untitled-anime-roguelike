return function()
	local CharacterLib = require(script.Parent.CharacterLib)

	describe("CharacterLib", function()
		describe("GetRootPart", function()
			it("should return nil if model is nil", function()
				expect(CharacterLib:GetRootPart(nil)).to.equal(nil)
			end)

			it("should return HumanoidRootPart if present", function()
				local model = Instance.new("Model")
				local hrp = Instance.new("Part")
				hrp.Name = "HumanoidRootPart"
				hrp.Parent = model

				expect(CharacterLib:GetRootPart(model)).to.equal(hrp)
			end)

			it("should return Root if HumanoidRootPart is missing", function()
				local model = Instance.new("Model")
				local root = Instance.new("Part")
				root.Name = "Root"
				root.Parent = model

				expect(CharacterLib:GetRootPart(model)).to.equal(root)
			end)

			it("should prioritize HumanoidRootPart over Root", function()
				local model = Instance.new("Model")

				local hrp = Instance.new("Part")
				hrp.Name = "HumanoidRootPart"
				hrp.Parent = model

				local root = Instance.new("Part")
				root.Name = "Root"
				root.Parent = model

				expect(CharacterLib:GetRootPart(model)).to.equal(hrp)
			end)

			it("should return PrimaryPart if no common root names are found", function()
				local model = Instance.new("Model")
				local pp = Instance.new("Part")
				pp.Name = "ArbitraryName"
				pp.Parent = model
				model.PrimaryPart = pp

				expect(CharacterLib:GetRootPart(model)).to.equal(pp)
			end)

			it("should find an arbitrary BasePart if no root names or PrimaryPart", function()
				local model = Instance.new("Model")
				local part = Instance.new("Part")
				part.Name = "SomePart"
				part.Parent = model

				expect(CharacterLib:GetRootPart(model)).to.equal(part)
			end)

			it("should skip non-BasePart children with root names", function()
				local model = Instance.new("Model")

				local fakeRoot = Instance.new("Folder")
				fakeRoot.Name = "HumanoidRootPart"
				fakeRoot.Parent = model

				local realRoot = Instance.new("Part")
				realRoot.Name = "Root"
				realRoot.Parent = model

				expect(CharacterLib:GetRootPart(model)).to.equal(realRoot)
			end)

			it("should check other root part names (LowerTorso, Torso, UpperTorso)", function()
				-- Test LowerTorso
				local m1 = Instance.new("Model")
				local lt = Instance.new("Part")
				lt.Name = "LowerTorso"
				lt.Parent = m1
				expect(CharacterLib:GetRootPart(m1)).to.equal(lt)

				-- Test Torso
				local m2 = Instance.new("Model")
				local t = Instance.new("Part")
				t.Name = "Torso"
				t.Parent = m2
				expect(CharacterLib:GetRootPart(m2)).to.equal(t)

				-- Test UpperTorso
				local m3 = Instance.new("Model")
				local ut = Instance.new("Part")
				ut.Name = "UpperTorso"
				ut.Parent = m3
				expect(CharacterLib:GetRootPart(m3)).to.equal(ut)
			end)
		end)

		describe("IsCustomRig", function()
			it("should return true if IsCustomRig attribute is true", function()
				local model = Instance.new("Model")
				model:SetAttribute("IsCustomRig", true)
				expect(CharacterLib:IsCustomRig(model)).to.equal(true)
			end)

			it("should return false if IsCustomRig attribute is missing or false", function()
				local model = Instance.new("Model")
				expect(CharacterLib:IsCustomRig(model)).to.equal(false)

				model:SetAttribute("IsCustomRig", false)
				expect(CharacterLib:IsCustomRig(model)).to.equal(false)
			end)
		end)
	end)
end
