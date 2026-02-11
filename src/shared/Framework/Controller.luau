--[[
    Controller.luau
    Base class for client-side controllers.
    
    Usage:
        local MyController = {}
        MyController.Name = "MyController"
        
        function MyController:Init()
            -- Setup, can reference other controllers
        end
        
        function MyController:Start()
            -- All controllers ready, safe to use them
        end
        
        function MyController:Destroy()
            -- Cleanup
        end
        
        return MyController
]]

export type Controller = {
	Name: string,
	Init: (self: Controller) -> (),
	Start: (self: Controller) -> (),
	Destroy: (self: Controller) -> (),
}

return {}
