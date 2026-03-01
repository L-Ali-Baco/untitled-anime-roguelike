--!strict
--[[
	NetSerializer.luau
	==================
	Binary serialization/deserialization of game data for network transmission.
	Replaces bloated Roblox default types (Vector3, CFrame) sent over RemoteEvents
	with compact buffer-encoded binary payloads.

	═══════════════════════════════════════════════════════════════════════════════
	WHY SERIALIZE AT ALL?
	═══════════════════════════════════════════════════════════════════════════════

	When you fire a RemoteEvent with a Vector3 value, Roblox serialises it using
	its internal network protocol. The exact wire format is not documented, but
	Vector3 is transmitted as three IEEE 754 float32 values = 12 bytes, PLUS
	Roblox's packet framing, type tags, and compression headers. In practice,
	each Vector3 adds ~16–20 bytes to the packet.

	A CFrame is 12 floats (position XYZ + rotation matrix 3×3) = 48 bytes raw,
	~56–64 bytes on the wire.

	For high-frequency events like ShowDamageNumbers (fires every hit at 60 Hz
	with up to 10 simultaneous players hitting enemies) or chain-lightning VFX
	(20 bounces per cast), this accumulates quickly:
	  20 bounces × 64 bytes/CFrame × 4 players = 5,120 bytes/cast
	  At 3 chain-lightning casts/second = 15,360 bytes/s = 15 KB/s per client.
	Roblox's soft client bandwidth cap is ~50 KB/s. Chain-lightning alone could
	consume 30% of bandwidth without serialization.

	BUFFER API (Roblox, introduced 2023):
	  buffer.create(size)           → allocate N bytes
	  buffer.writei16(b, offset, v) → write signed 16-bit int at byte offset
	  buffer.readi16(b, offset)     → read signed 16-bit int
	  buffer.writeu8(b, offset, v)  → write unsigned 8-bit int
	  buffer.readu8(b, offset)      → read unsigned 8-bit int
	  buffer.writef32(b, offset, v) → write IEEE 754 float (4 bytes, full precision)
	  buffer.readf32(b, offset)     → read IEEE 754 float
	  buffer.tostring(b)            → convert to Lua string for RemoteEvent
	  buffer.fromstring(s)          → convert string back to buffer

	ENCODING STRATEGIES USED HERE:

	  Position (Vector3) → int16 × 3  (6 bytes)
	    World positions are clamped to ±4096 studs (more than enough for a
	    roguelike arena). We scale by POSITION_SCALE (8) to preserve sub-stud
	    precision: stored value = floor(worldPos * 8), decoded = stored / 8.
	    Range: ±4096 studs at 0.125-stud precision. Size: 6 bytes vs 12 raw.
	    Saving: 50%.

	  Damage Number → u16 + u8 flags  (3 bytes)
	    Damage value clamped to 0–65535. Flag byte encodes: isCrit (bit 0),
	    isKill (bit 1), damageType enum (bits 2–4). Size: 3 bytes vs a table.

	  Compact CFrame → int16 × 3 (position) + u8 × 3 (Euler angles) = 9 bytes
	    For VFX CFrames that don't need full matrix precision (e.g. slash
	    direction, explosion facing): encode position as int16, encode pitch/yaw/
	    roll as u8 mapped to [0, 2π] → [0, 255]. Size: 9 bytes vs 48 raw.
	    Saving: 81%.

	  Chain-Lightning Bounce → 6-byte position + 1-byte target index = 7 bytes
	    Encodes one bounce as a packed position plus an 8-bit enemy ID index.

	USAGE EXAMPLE:
	  -- Server:
	  local packed = NetSerializer.PackDamageEvent(hitPos, damage, isCrit, isKill)
	  DamageNumbersRemote:FireAllClients(packed)

	  -- Client:
	  DamageNumbersRemote.OnClientEvent:Connect(function(packed)
	      local pos, damage, isCrit, isKill = NetSerializer.UnpackDamageEvent(packed)
	      -- spawn damage number VFX at pos
	  end)
]]

-- ── Module Declaration ──────────────────────────────────────────────────────

local NetSerializer = {}

-- ── Constants ───────────────────────────────────────────────────────────────

-- Position scale factor. Multiply world position by this before converting
-- to int16. Divide by this when decoding.
-- Scale = 8 → 0.125-stud precision, ±4096 studs range.
-- (int16 max = 32767; 32767 / 8 = 4095.875 studs max in any axis)
local POSITION_SCALE: number = 8

-- Reciprocal pre-computed for decode division → multiply instead.
local INV_POSITION_SCALE: number = 1 / POSITION_SCALE

-- Angle encoding: map [0, 2π] → [0, 255] for u8 storage.
-- Scale = 255 / (2π) ≈ 40.584
local ANGLE_ENCODE_SCALE: number = 255 / (2 * math.pi)
local ANGLE_DECODE_SCALE: number = (2 * math.pi) / 255

-- Compact angle encoding for u8: maps [-π, π] → [0, 255].
-- Offset = 128 (bias to make negative angles representable as u8).
local ANGLE_BIAS: number = 128

-- Damage flag bit positions (within the u8 flag byte).
local FLAG_IS_CRIT: number = 0 -- bit 0
local FLAG_IS_KILL: number = 1 -- bit 1
-- bits 2–4: damage type (0=physical, 1=fire, 2=electric, 3=poison, 4=heal)
local FLAG_DAMAGE_TYPE_SHIFT: number = 2
local FLAG_DAMAGE_TYPE_MASK: number = 0b00011100

-- Packet type codes (1 byte header for self-describing packets).
local PACKET_DAMAGE: number = 0x01
local PACKET_CHAIN_BOUNCE: number = 0x02
local PACKET_COMPACT_CFRAME: number = 0x03
local PACKET_POSITION_ONLY: number = 0x04

-- ── Type Declarations ─────────────────────────────────────────────────────────

export type DamageType = "Physical" | "Fire" | "Electric" | "Poison" | "Heal"

local DAMAGE_TYPE_TO_ID: { [DamageType]: number } = {
	Physical = 0,
	Fire = 1,
	Electric = 2,
	Poison = 3,
	Heal = 4,
}

local DAMAGE_TYPE_FROM_ID: { [number]: DamageType } = {
	[0] = "Physical",
	[1] = "Fire",
	[2] = "Electric",
	[3] = "Poison",
	[4] = "Heal",
}

-- ── Private: Position Encoding ────────────────────────────────────────────────

--[[
	_encodePosition(buf, offset, position) -> nextOffset

	Writes a Vector3 position as three int16 values (6 bytes) into `buf`
	starting at byte `offset`. Returns the next write offset.

	ENCODING:
	  stored = clamp(round(worldPos.Axis * POSITION_SCALE), -32768, 32767)
	  Decoded = stored * INV_POSITION_SCALE

	PRECISION: 0.125 studs (1/8 stud)
	RANGE:     ±4095.875 studs per axis

	@param buf     buffer   Target buffer (must have ≥ offset+6 bytes allocated).
	@param offset  number   Byte offset to start writing at.
	@param pos     Vector3  World position to encode.
	@return        number   Next byte offset after this write (offset + 6).
]]
local function _encodePosition(buf: buffer, offset: number, pos: Vector3): number
	-- Clamp before converting to int16 to prevent wrap-around on out-of-range positions.
	-- math.clamp + math.round in one expression:
	local function encodeAxis(v: number): number
		return math.clamp(math.round(v * POSITION_SCALE), -32768, 32767)
	end

	buffer.writei16(buf, offset, encodeAxis(pos.X))
	buffer.writei16(buf, offset + 2, encodeAxis(pos.Y))
	buffer.writei16(buf, offset + 4, encodeAxis(pos.Z))
	return offset + 6
end

--[[
	_decodePosition(buf, offset) -> (Vector3, nextOffset)

	Reads a Vector3 position from three int16 values (6 bytes) in `buf`.
	Returns the decoded Vector3 and the next read offset.
]]
local function _decodePosition(buf: buffer, offset: number): (Vector3, number)
	local x = buffer.readi16(buf, offset) * INV_POSITION_SCALE
	local y = buffer.readi16(buf, offset + 2) * INV_POSITION_SCALE
	local z = buffer.readi16(buf, offset + 4) * INV_POSITION_SCALE
	return Vector3.new(x, y, z), offset + 6
end

--[[
	_encodeAngle(radians) -> u8

	Encodes a radian angle in the range [-π, π] into a u8 (0–255).
	Uses a bias of 128 so that 0 radians maps to 128.

	PRECISION: 2π / 256 ≈ 0.0245 radians ≈ 1.4 degrees.
	Sufficient for VFX orientations (slash direction, explosion facing).
	NOT suitable for fine-grained physics or aiming — use float32 for that.
]]
local function _encodeAngle(radians: number): number
	-- Normalise to [-π, π] in case of drift.
	local norm = radians % (2 * math.pi)
	if norm > math.pi then
		norm = norm - 2 * math.pi
	end
	-- Map [-π, π] → [0, 255] with bias 128.
	local encoded = math.round(norm * ANGLE_ENCODE_SCALE + ANGLE_BIAS)
	return math.clamp(encoded, 0, 255)
end

local function _decodeAngle(encoded: number): number
	-- Reverse the bias and scale.
	return (encoded - ANGLE_BIAS) * ANGLE_DECODE_SCALE
end

-- ── Public: Pack/Unpack Position ─────────────────────────────────────────────

--[[
	NetSerializer.PackPosition(position) -> string

	Encodes a single Vector3 into a 7-byte string (1-byte type header + 6 bytes).
	Use for events that only need to communicate a world position
	(e.g. VFX spawn location with no rotation).

	@param position  Vector3  World position to encode.
	@return          string   Binary string suitable for RemoteEvent transmission.
]]
function NetSerializer.PackPosition(position: Vector3): string
	-- 7 bytes: 1 (type header) + 6 (position int16×3)
	local buf = buffer.create(7)
	buffer.writeu8(buf, 0, PACKET_POSITION_ONLY)
	_encodePosition(buf, 1, position)
	return buffer.tostring(buf)
end

--[[
	NetSerializer.UnpackPosition(data) -> Vector3

	Decodes a position string produced by PackPosition.

	@param data  string  Binary string from RemoteEvent.
	@return      Vector3
]]
function NetSerializer.UnpackPosition(data: string): Vector3
	local buf = buffer.fromstring(data)
	-- Skip byte 0 (type header); position starts at byte 1.
	local pos, _ = _decodePosition(buf, 1)
	return pos
end

-- ── Public: Pack/Unpack Damage Event ─────────────────────────────────────────

--[[
	NetSerializer.PackDamageEvent(position, damage, isCrit, isKill, damageType?) -> string

	Encodes a damage number event into a 10-byte string:
	  Byte 0:   type header (PACKET_DAMAGE = 0x01)
	  Bytes 1–6: position int16×3 (6 bytes)
	  Bytes 7–8: damage value uint16 (2 bytes, max 65535)
	  Byte 9:   flag byte (isCrit | isKill | damageType)

	Total: 10 bytes vs a Lua table with 4+ fields (~100–150 bytes on the wire).
	Compression ratio: ~15×.

	FLAG BYTE LAYOUT:
	  bit 0     → isCrit
	  bit 1     → isKill
	  bits 2–4  → DamageType enum (0–4)
	  bits 5–7  → reserved (0)

	@param position    Vector3      Hit position in world space.
	@param damage      number       Damage amount (clamped to 0–65535).
	@param isCrit      boolean      Whether this hit was a critical strike.
	@param isKill      boolean      Whether this hit killed the target.
	@param damageType  DamageType?  Defaults to "Physical".
	@return            string       Binary payload for RemoteEvent.
]]
function NetSerializer.PackDamageEvent(
	position: Vector3,
	damage: number,
	isCrit: boolean,
	isKill: boolean,
	damageType: DamageType?
): string
	local buf = buffer.create(10)

	-- Byte 0: packet type.
	buffer.writeu8(buf, 0, PACKET_DAMAGE)

	-- Bytes 1–6: position.
	_encodePosition(buf, 1, position)

	-- Bytes 7–8: damage value (uint16).
	-- Clamp to [0, 65535] to prevent wrap-around.
	local clampedDamage = math.clamp(math.round(damage), 0, 65535)
	-- uint16 encoding: high byte then low byte (big-endian within the buffer).
	-- buffer.writeu16 is not in Roblox's API (only i8/u8/i16/u16/i32/u32/f32/f64).
	-- We use the available writei16 and treat the damage as an unsigned value.
	-- Damage fits in u16 (0–65535); int16 range is –32768..32767 so for damage
	-- > 32767 we need to mask. We encode both bytes manually via u8 writes.
	buffer.writeu8(buf, 7, math.floor(clampedDamage / 256)) -- high byte
	buffer.writeu8(buf, 8, clampedDamage % 256) -- low byte

	-- Byte 9: flag byte.
	local flags = 0
	if isCrit then
		flags = bit32.bor(flags, bit32.lshift(1, FLAG_IS_CRIT))
	end
	if isKill then
		flags = bit32.bor(flags, bit32.lshift(1, FLAG_IS_KILL))
	end
	local typeId = DAMAGE_TYPE_TO_ID[damageType or "Physical"] or 0
	flags = bit32.bor(flags, bit32.lshift(typeId, FLAG_DAMAGE_TYPE_SHIFT))
	buffer.writeu8(buf, 9, flags)

	return buffer.tostring(buf)
end

--[[
	NetSerializer.UnpackDamageEvent(data) -> (Vector3, number, boolean, boolean, DamageType)

	Decodes a damage event string produced by PackDamageEvent.

	@param data  string  Binary payload from RemoteEvent.
	@return      Vector3     Hit position.
	@return      number      Damage amount.
	@return      boolean     isCrit.
	@return      boolean     isKill.
	@return      DamageType  Damage type.
]]
function NetSerializer.UnpackDamageEvent(
	data: string
): (Vector3, number, boolean, boolean, DamageType)
	local buf = buffer.fromstring(data)

	-- Decode position (bytes 1–6).
	local pos, _ = _decodePosition(buf, 1)

	-- Decode damage (bytes 7–8, big-endian u16).
	local highByte = buffer.readu8(buf, 7)
	local lowByte = buffer.readu8(buf, 8)
	local damage = highByte * 256 + lowByte

	-- Decode flags (byte 9).
	local flags = buffer.readu8(buf, 9)
	local isCrit = bit32.band(bit32.rshift(flags, FLAG_IS_CRIT), 1) == 1
	local isKill = bit32.band(bit32.rshift(flags, FLAG_IS_KILL), 1) == 1
	local typeId = bit32.band(bit32.rshift(flags, FLAG_DAMAGE_TYPE_SHIFT), 0b111)
	local damageType: DamageType = DAMAGE_TYPE_FROM_ID[typeId] or "Physical"

	return pos, damage, isCrit, isKill, damageType
end

-- ── Public: Pack/Unpack Compact CFrame ───────────────────────────────────────

--[[
	NetSerializer.PackCompactCFrame(cf) -> string

	Encodes a CFrame into 10 bytes:
	  Byte 0:   type header (PACKET_COMPACT_CFRAME = 0x03)
	  Bytes 1–6: position int16×3  (6 bytes, 0.125-stud precision)
	  Bytes 7–9: Euler angles u8×3 (3 bytes, 1.4-degree precision)

	Total: 10 bytes vs 48 bytes raw = 79% reduction.

	USE CASES:
	  ✓ VFX CFrames (slash direction, explosion orientation, beam start/end)
	  ✓ Projectile spawn CFrames
	  ✗ Precise physical simulation (use full CFrame)
	  ✗ Camera CFrames (too much precision loss)

	EULER ANGLE ORDER: XYZ (pitch, yaw, roll) extracted via CFrame:ToEulerAnglesXYZ().

	@param cf   CFrame  The CFrame to encode.
	@return     string  10-byte binary string.
]]
function NetSerializer.PackCompactCFrame(cf: CFrame): string
	local buf = buffer.create(10)

	-- Byte 0: packet type.
	buffer.writeu8(buf, 0, PACKET_COMPACT_CFRAME)

	-- Bytes 1–6: position.
	_encodePosition(buf, 1, cf.Position)

	-- Bytes 7–9: rotation as Euler angles XYZ.
	local rx, ry, rz = cf:ToEulerAnglesXYZ()
	buffer.writeu8(buf, 7, _encodeAngle(rx)) -- pitch (u8)
	buffer.writeu8(buf, 8, _encodeAngle(ry)) -- yaw   (u8)
	buffer.writeu8(buf, 9, _encodeAngle(rz)) -- roll  (u8)

	return buffer.tostring(buf)
end

--[[
	NetSerializer.UnpackCompactCFrame(data) -> CFrame

	Decodes a compact CFrame string produced by PackCompactCFrame.

	@param data  string  Binary payload from RemoteEvent.
	@return      CFrame  Decoded CFrame (position ±0.125 stud, angle ±1.4°).
]]
function NetSerializer.UnpackCompactCFrame(data: string): CFrame
	local buf = buffer.fromstring(data)

	-- Decode position (bytes 1–6).
	local pos, _ = _decodePosition(buf, 1)

	-- Decode Euler angles (bytes 7–9).
	local rx = _decodeAngle(buffer.readu8(buf, 7))
	local ry = _decodeAngle(buffer.readu8(buf, 8))
	local rz = _decodeAngle(buffer.readu8(buf, 9))

	-- Reconstruct CFrame from position and Euler angles.
	return CFrame.new(pos) * CFrame.fromEulerAnglesXYZ(rx, ry, rz)
end

-- ── Public: Pack/Unpack Chain Lightning Bounce ────────────────────────────────

--[[
	NetSerializer.PackChainBounce(fromPos, toPos, bounceIndex, totalBounces) -> string

	Encodes one chain-lightning bounce into 14 bytes:
	  Byte 0:    type header (PACKET_CHAIN_BOUNCE = 0x02)
	  Bytes 1–6:  fromPos int16×3  (6 bytes)
	  Bytes 7–12: toPos   int16×3  (6 bytes)
	  Byte 13:   packed u8: high 4 bits = bounceIndex, low 4 bits = totalBounces
	             (supports up to 15 bounces, which covers all planned chain items)

	Total: 14 bytes vs two Vector3s (24 bytes) + two numbers (~32 bytes table).
	The client fires this remote 20 times per chain-lightning cast.
	Saving: ~18 bytes × 20 bounces = 360 bytes per cast vs raw.

	@param fromPos       Vector3  Start position of this bounce.
	@param toPos         Vector3  End position (next target) of this bounce.
	@param bounceIndex   number   Which bounce this is (1-based, max 15).
	@param totalBounces  number   Total number of bounces in this chain (max 15).
	@return              string   14-byte binary payload.
]]
function NetSerializer.PackChainBounce(
	fromPos: Vector3,
	toPos: Vector3,
	bounceIndex: number,
	totalBounces: number
): string
	local buf = buffer.create(14)

	-- Byte 0: packet type.
	buffer.writeu8(buf, 0, PACKET_CHAIN_BOUNCE)

	-- Bytes 1–6: fromPos.
	_encodePosition(buf, 1, fromPos)

	-- Bytes 7–12: toPos.
	_encodePosition(buf, 7, toPos)

	-- Byte 13: packed bounce metadata.
	-- high nibble (bits 4–7) = bounceIndex (clamped to 0–15)
	-- low  nibble (bits 0–3) = totalBounces (clamped to 0–15)
	local bi = math.clamp(bounceIndex, 0, 15)
	local tb = math.clamp(totalBounces, 0, 15)
	buffer.writeu8(buf, 13, bit32.bor(bit32.lshift(bi, 4), tb))

	return buffer.tostring(buf)
end

--[[
	NetSerializer.UnpackChainBounce(data) -> (Vector3, Vector3, number, number)

	Decodes a chain bounce string produced by PackChainBounce.

	@param data  string  Binary payload from RemoteEvent.
	@return      Vector3  fromPos.
	@return      Vector3  toPos.
	@return      number   bounceIndex (1-based).
	@return      number   totalBounces.
]]
function NetSerializer.UnpackChainBounce(data: string): (Vector3, Vector3, number, number)
	local buf = buffer.fromstring(data)

	local fromPos, nextOffset = _decodePosition(buf, 1)
	local toPos, _ = _decodePosition(buf, nextOffset)

	local packed = buffer.readu8(buf, 13)
	local bounceIndex = bit32.rshift(packed, 4) -- high nibble
	local totalBounces = bit32.band(packed, 0x0F) -- low nibble

	return fromPos, toPos, bounceIndex, totalBounces
end

-- ── Public: Pack/Unpack Batch Damage Events ───────────────────────────────────

--[[
	NetSerializer.PackDamageBatch(events) -> string

	Encodes multiple damage events into a single binary string, reducing the
	number of RemoteEvent calls. Sending N events as one 10N-byte string is
	significantly cheaper than N separate RemoteEvent firings (each of which
	incurs packet framing overhead).

	Each event in the batch occupies 9 bytes (no type header per event;
	the batch header covers the entire payload):
	  Byte 0: packet type (PACKET_DAMAGE)
	  Byte 1: event count (u8, max 255 events per batch)
	  Bytes 2..end: 9 bytes per event (position + damage + flags, no per-event header)

	@param events  {{position: Vector3, damage: number, isCrit: boolean, isKill: boolean, damageType: DamageType?}}
	@return        string  Binary batch payload.
]]
function NetSerializer.PackDamageBatch(
	events: {
		{
			position: Vector3,
			damage: number,
			isCrit: boolean,
			isKill: boolean,
			damageType: DamageType?,
		}
	}
): string
	local count = math.min(#events, 255) -- u8 max
	-- 2-byte header + 9 bytes per event (6 pos + 2 damage + 1 flags).
	local buf = buffer.create(2 + count * 9)

	buffer.writeu8(buf, 0, PACKET_DAMAGE) -- batch type
	buffer.writeu8(buf, 1, count) -- event count

	local writeOffset = 2
	for i = 1, count do
		local ev = events[i]

		-- Position (6 bytes).
		writeOffset = _encodePosition(buf, writeOffset, ev.position)

		-- Damage (2 bytes, big-endian u16).
		local clampedDamage = math.clamp(math.round(ev.damage), 0, 65535)
		buffer.writeu8(buf, writeOffset, math.floor(clampedDamage / 256))
		buffer.writeu8(buf, writeOffset + 1, clampedDamage % 256)
		writeOffset += 2

		-- Flags (1 byte).
		local flags = 0
		if ev.isCrit then
			flags = bit32.bor(flags, bit32.lshift(1, FLAG_IS_CRIT))
		end
		if ev.isKill then
			flags = bit32.bor(flags, bit32.lshift(1, FLAG_IS_KILL))
		end
		local typeId = DAMAGE_TYPE_TO_ID[ev.damageType or "Physical"] or 0
		flags = bit32.bor(flags, bit32.lshift(typeId, FLAG_DAMAGE_TYPE_SHIFT))
		buffer.writeu8(buf, writeOffset, flags)
		writeOffset += 1
	end

	return buffer.tostring(buf)
end

--[[
	NetSerializer.UnpackDamageBatch(data) -> {{position, damage, isCrit, isKill, damageType}}

	Decodes a batch payload produced by PackDamageBatch.

	@param data  string  Binary batch payload.
	@return      array of decoded event tables.
]]
function NetSerializer.UnpackDamageBatch(data: string): {
	{
		position: Vector3,
		damage: number,
		isCrit: boolean,
		isKill: boolean,
		damageType: DamageType,
	}
}
	local buf = buffer.fromstring(data)
	local count = buffer.readu8(buf, 1)
	local results = table.create(count)

	local readOffset = 2
	for i = 1, count do
		-- Position.
		local pos, nextOff = _decodePosition(buf, readOffset)
		readOffset = nextOff

		-- Damage (big-endian u16).
		local highByte = buffer.readu8(buf, readOffset)
		local lowByte = buffer.readu8(buf, readOffset + 1)
		local damage = highByte * 256 + lowByte
		readOffset += 2

		-- Flags.
		local flags = buffer.readu8(buf, readOffset)
		readOffset += 1

		local isCrit = bit32.band(bit32.rshift(flags, FLAG_IS_CRIT), 1) == 1
		local isKill = bit32.band(bit32.rshift(flags, FLAG_IS_KILL), 1) == 1
		local typeId = bit32.band(bit32.rshift(flags, FLAG_DAMAGE_TYPE_SHIFT), 0b111)

		results[i] = {
			position = pos,
			damage = damage,
			isCrit = isCrit,
			isKill = isKill,
			damageType = DAMAGE_TYPE_FROM_ID[typeId] or "Physical",
		}
	end

	return results
end

-- ── Public: Diagnostics ───────────────────────────────────────────────────────

--[[
	NetSerializer.GetCompressionRatio(packedString, originalBytes) -> number

	Utility for measuring and logging compression effectiveness.
	Call this during development to verify encoding is as compact as expected.

	@param packedString   string  The encoded binary string.
	@param originalBytes  number  The estimated raw byte count before encoding.
	@return               number  Compression ratio (e.g. 0.21 = 79% reduction).
]]
function NetSerializer.GetCompressionRatio(packedString: string, originalBytes: number): number
	return #packedString / originalBytes
end

-- ── Return ────────────────────────────────────────────────────────────────────

return NetSerializer
