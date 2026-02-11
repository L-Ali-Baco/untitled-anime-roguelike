--[[
    Service.luau
    Base class for server-side services.
    
    Usage:
        local MyService = {}
        MyService.Name = "MyService"
        
        function MyService:Init()
            -- Setup, can reference other services but not call them
        end
        
        function MyService:Start()
            -- All services ready, safe to call other services
        end
        
        function MyService:Destroy()
            -- Cleanup
        end
        
        return MyService
]]

export type Service = {
	Name: string,
	Init: (self: Service) -> (),
	Start: (self: Service) -> (),
	Destroy: (self: Service) -> (),
}

return {}
