--[[
    InputTypes.luau
    Type definitions for input system.
]]

export type InputDevice = "Mobile" | "PC" | "Gamepad"

export type MoveInput = {
	direction: Vector3, -- Normalized world-space movement direction
	magnitude: number, -- 0-1, how far joystick is pushed / if key is held
}

export type InputState = {
	device: InputDevice,
	move: MoveInput,
	look: Vector2, -- Camera rotation delta
	isAttackHeld: boolean,
	isAttackPressed: boolean,
	isDashPressed: boolean,
	isJumpPressed: boolean,
	isInteractPressed: boolean,
}

-- For mobile joystick
export type JoystickInput = {
	direction: Vector2, -- Raw 2D direction from joystick
	magnitude: number, -- 0-1
	isActive: boolean, -- Is the joystick currently being touched
}

return {}
