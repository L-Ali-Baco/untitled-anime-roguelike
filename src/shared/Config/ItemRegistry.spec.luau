return function()
	local ItemRegistry = require(script.Parent.ItemRegistry)

	describe("ItemRegistry", function()
		describe("GetItem", function()
			it("should return the correct item for a valid key", function()
				local item = ItemRegistry.GetItem("StaticFilament")
				expect(item).to.be.ok()
				expect(item.Name).to.equal("Static Filament")
				expect(item.Rarity).to.equal("Common")
			end)

			it("should return nil for an invalid key", function()
				local item = ItemRegistry.GetItem("NonExistentItem")
				expect(item).to.equal(nil)
			end)
		end)

		describe("GetItemsByRarity", function()
			it("should return only items of the specified rarity", function()
				local commonItems = ItemRegistry.GetItemsByRarity("Common")
				expect(#commonItems).to.be.at.least(1)
				for _, item in commonItems do
					expect(item.Rarity).to.equal("Common")
				end
			end)

			it("should return an empty table for a rarity with no items", function()
				local items = ItemRegistry.GetItemsByRarity("NonExistentRarity")
				expect(type(items)).to.equal("table")
				expect(#items).to.equal(0)
			end)
		end)

		describe("GetRandomItemKey", function()
			it("should return a valid key from the pool", function()
				local key = ItemRegistry.GetRandomItemKey()
				expect(ItemRegistry.Pool[key]).to.be.ok()
			end)
		end)
	end)
end
