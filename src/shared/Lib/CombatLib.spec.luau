-- src/shared/Lib/CombatLib.spec.luau

-- Mock Globals
if not _G.OverlapParams then
    _G.OverlapParams = {
        new = function()
            return { FilterDescendantsInstances = {}, FilterType = nil, _isMock = true }
        end
    }
end

if not _G.Enum then
    _G.Enum = {
        RaycastFilterType = { Exclude = 1, Include = 2 }
    }
end

local CombatLib = require(script.Parent.CombatLib)

return function(context)
    local describe = context.describe
    local it = context.it
    local expect = context.expect
    local Instance = context.Instance

    -- Mock CollectionService
    local CollectionService = game:GetService("CollectionService")
    function CollectionService:HasTag(instance, tag)
        if instance and instance:GetAttribute("HasTag_" .. tag) then
            return true
        end
        return false
    end

    describe("CombatLib", function()
        describe("getEnemiesInRadius", function()
            it("should return enemies with correct tags", function()
                -- setup test scene
                local enemy = Instance.new("Model")
                enemy:SetAttribute("HasTag_Enemy", true)
                local hum = Instance.new("Humanoid")
                hum.Health = 100
                hum.Parent = enemy

                local part = Instance.new("Part")
                part.Parent = enemy

                -- Mock GetPartBoundsInRadius
                workspace.GetPartBoundsInRadius = function(self, pos, rad, params)
                    -- Verify params
                    if params then
                         expect(params._isMock).to.equal(true)
                    end
                    return { part }
                end

                local result = CombatLib.getEnemiesInRadius(Vector3.new(0,0,0), 10)
                expect(#result).to.equal(1)
                expect(result[1]).to.equal(enemy)
            end)

            it("should filter out dead enemies", function()
                 -- setup test scene
                local enemy = Instance.new("Model")
                enemy:SetAttribute("HasTag_Enemy", true)
                local hum = Instance.new("Humanoid")
                hum.Health = 0 -- Dead
                hum.Parent = enemy

                local part = Instance.new("Part")
                part.Parent = enemy

                -- Mock GetPartBoundsInRadius
                workspace.GetPartBoundsInRadius = function(self, pos, rad, params)
                    return { part }
                end

                local result = CombatLib.getEnemiesInRadius(Vector3.new(0,0,0), 10)
                expect(#result).to.equal(0)
            end)

            it("should use OverlapParams correctly", function()
                 local enemy = Instance.new("Model")
                 enemy:SetAttribute("HasTag_Enemy", true)
                 local hum = Instance.new("Humanoid")
                 hum.Health = 100
                 hum.Parent = enemy
                 local part = Instance.new("Part")
                 part.Parent = enemy

                 local capturedParams
                 workspace.GetPartBoundsInRadius = function(self, pos, rad, params)
                     capturedParams = params
                     return { part }
                 end

                 CombatLib.getEnemiesInRadius(Vector3.new(0,0,0), 10)
                 expect(capturedParams).to.be.ok()
                 expect(capturedParams.FilterType).to.equal(Enum.RaycastFilterType.Exclude)
            end)
        end)
    end)
end
