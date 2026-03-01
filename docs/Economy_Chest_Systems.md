# Economy & Chest Systems — Architecture Reference

> Covers: `EconomyService`, `ChestService`, `ChestVFXController`, and the `GoldOrb` pool.
> Last updated: 2026-03-01

---

## 1. System Overview

```
SERVER                                            CLIENT
──────────────────────────────────────────────    ──────────────────────────
EnemyService.fireEnemyDied()
  └─► EconomyService:OnEnemyDied(payload)
        └─► _spawnOrbs(deathPos, goldAmount)
              └─► ObjectPool:GetPart() × 3
                    └─► fountain velocity applied

Heartbeat loop (every frame):
  for each activeOrb:
    if dist to nearest player ≤ ORB_COLLECT_RADIUS
      └─► AddGold(player, value)               ──► GoldChanged ──► HUD updates gold display
          ReturnPart(orb)                       ──► GoldPickup  ──► pickup sound/VFX
    elif dist ≤ ORB_MAGNET_RADIUS
      └─► orb.AssemblyLinearVelocity = dir × 35

ChestService:SpawnChest(pos, stage)
  └─► makeChestModel()
      └─► ProximityPrompt (cost = floor(25 × 1.15^(stage-1)))

ProximityPrompt.Triggered
  └─► EconomyService:SpendGold(player, cost) → bool
      └─► LootManager.RollItem(stage) → (itemKey, rarity)
          └─► ItemService:GrantItem(player, itemKey)
              └─► ChestOpened:FireAllClients(...)   ──► ChestVFXController
                                                          ├─► tweenLidOpen()
                                                          └─► spawnItemPreview()
```

---

## 2. File Index

| File | Side | Purpose |
|---|---|---|
| `src/server/Services/EconomyService.luau` | Server | Gold tracking, orb pool, magnet loop |
| `src/server/Services/ChestService.luau` | Server | Chest spawning, prompt, unlock sequence |
| `src/client/Features/ChestVFXController.luau` | Client | Lid tween + floating item preview |

---

## 3. EconomyService — Public API

```lua
EconomyService:GetGold(player)           → number
EconomyService:AddGold(player, amount)   → void
EconomyService:SpendGold(player, amount) → boolean   -- false = insufficient funds
EconomyService:OnEnemyDied(payload)      → void       -- called by EnemyService, not externally
```

**Gold storage:** `player:GetAttribute("Gold")` — lives on the `Player` Instance (not `Character`) so it persists through respawns. Automatically replicates to that player's client via Roblox attribute replication.

**Access from other services:**
```lua
local EconomyService = _G.EconomyService   -- available after EconomyService:Start()
-- or
local EconomyService = require(script.Parent.EconomyService)
```

---

## 4. ChestService — Public API

```lua
ChestService:SpawnChest(position, stageNumber) → Model   -- creates + parents chest to workspace
ChestService:GetCost(stageNumber)              → number  -- preview cost without spawning
```

**Access from other services:**
```lua
local ChestService = _G.ChestService   -- available after ChestService:Start()
```

**Typical usage from a level/director script:**
```lua
-- Spawn a chest near the beacon at the current stage number
local beaconPos = beacon.PrimaryPart.Position
ChestService:SpawnChest(beaconPos + Vector3.new(10, 0, 0), DirectorService:GetStage())
```

---

## 5. Stage-Scaled Cost Formula

```
cost = floor( BASE_CHEST_COST × STAGE_COST_MULT ^ (stageNumber - 1) )

BASE_CHEST_COST  = 25
STAGE_COST_MULT  = 1.15  (15% per stage)
```

| Stage | Cost | Notes |
|---|---|---|
| 1 | 25g | Baseline; exponent = 0 so multiplier = 1.0 |
| 2 | 28g | +15% |
| 3 | 32g | |
| 5 | 44g | |
| 10 | 88g | |
| 15 | 177g | |
| 20 | 409g | Forces stockpiling |

Both constants are at the top of `ChestService.luau` — adjust there to rebalance.

---

## 6. Enemy Gold Drop Table

Defined in `EconomyService.luau` as `GOLD_DROP_TABLE`:

| Enemy | Gold | Rationale |
|---|---|---|
| Minion | 2g | Fodder; high volume compensates |
| Shooter | 8g | Mid-tier ranged |
| MossFrog | 8g | Mid-tier melee |
| Brute | 15g | Rare heavy hitter |
| Keg | 5g | Suicide runner; danger is the real cost |
| Shaman | 20g | Assassination target reward |
| Drone | 10g | Future enemy (placeholder) |

`GOLD_DROP_DEFAULT = 3` is used for any enemy type not in the table.
To add a new enemy, insert its type key into `GOLD_DROP_TABLE` in `EconomyService.luau`.

---

## 7. GoldOrb ObjectPool

The orb pool is **server-side** (not in `VFXPool`, which is client-only).
Template construction and pool registration pattern:

```lua
-- In EconomyService:Start()
local template = makeOrbTemplate()    -- Part, Ball shape, Neon gold, CanCollide=false
template.Parent = workspace           -- must be parented before ObjectPool clones it
orbPool = ObjectPool.new(template, 30, 10)   -- 30 pre-warmed, expand by 10
template:Destroy()                    -- pool owns the clones; template no longer needed
```

**Spawn sequence (order matters):**
```lua
local part = orbPool:GetPart()         -- returns Anchored=true, Transparency=1
part.CFrame = CFrame.new(spawnPos)     -- position while still anchored
part.Transparency = 0                  -- make visible
part.Anchored = false                  -- MUST unanchor BEFORE applying velocity
part.AssemblyLinearVelocity = velocity -- fountain kick
```

**Tuning constants** (top of `EconomyService.luau`):

| Constant | Default | Effect |
|---|---|---|
| `ORB_COUNT` | 3 | Orbs spawned per kill |
| `ORB_UPWARD_MIN/MAX` | 20–35 | Fountain arc height |
| `ORB_RADIAL_MIN/MAX` | 5–15 | Scatter radius |
| `ORB_MAGNET_DELAY` | 0.5s | Physics-free window before homing |
| `ORB_MAGNET_RADIUS` | 20 studs | Pull activates within this range |
| `ORB_PULL_SPEED` | 35 studs/s | Constant pull velocity |
| `ORB_COLLECT_RADIUS` | 3 studs | Snap-to-collect distance |
| `ORB_LIFETIME` | 15s | Despawn if uncollected |

---

## 8. Magnet Math (Reference)

```
Each Heartbeat, per active orb:

  1. distSq = (playerRoot.Position - orbPos).Magnitude ^ 2
     -- squaring avoids sqrt during the nearest-player scan (O(p) players)

  2. dist = math.sqrt(distSq)
     -- one sqrt per orb per frame, reused for both checks

  3. Collect:  dist ≤ ORB_COLLECT_RADIUS  →  AddGold, ReturnPart

  4. Magnet:   dist ≤ ORB_MAGNET_RADIUS
       direction = (playerPos - orbPos) / dist
       -- division by dist == .Unit without a second magnitude call

       part.AssemblyLinearVelocity = direction × ORB_PULL_SPEED
       -- ASSIGNMENT not +=: prevents per-frame speed accumulation
```

---

## 9. Remotes

| Remote | Direction | Payload | Consumer |
|---|---|---|---|
| `GoldChanged` | Server → Client (owner) | `newTotal: number` | Gold HUD display |
| `GoldPickup` | Server → Client (collector) | `amount: number` | Pickup sound / floating number |
| `ChestOpened` | Server → AllClients | `{ ChestModel, ItemKey, Rarity }` | `ChestVFXController` |

---

## 10. ChestVFXController — Lid Tween

The `Lid` BasePart's CFrame is rotated **in object space** around the local X axis:
```lua
local targetCFrame = lid.CFrame * CFrame.Angles(math.rad(-90), 0, 0)
-- CFrame.Angles in object space (right-multiplied) = rotate around lid's own X = hinge axis
-- Negative angle = swings back and up (away from player facing front)
```
`EasingStyle.Back, Out` — overshoots slightly for a physical "thud" feel.

For custom chest models: name the hinge piece `"Lid"`. If absent, the function silently skips — the item is still granted.

---

## 11. Rarity Colours (ChestVFXController)

Used for the floating item preview sphere. Mirror these in any UI that displays rarity.

| Rarity | RGB | Hex |
|---|---|---|
| Common | (200, 200, 200) | `#C8C8C8` grey |
| Uncommon | (100, 220, 100) | `#64DC64` green |
| Rare | (80, 140, 220) | `#508CDC` blue |
| Epic | (160, 80, 220) | `#A050DC` purple |
| Legendary | (255, 190, 0) | `#FFBE00` gold |

---

## 12. Key Gotchas

**LootManager returns two values.** Always capture both:
```lua
local itemKey, rarity = LootManager.RollItem(stageNumber)
-- NOT: local itemKey = LootManager.RollItem(stageNumber)  ← loses rarity silently
```

**`itemKey` can be nil.** `RollItem` returns nil if the rarity table has no items for that stage. `ChestService` handles this with a consolation gold grant; callers of `LootManager.RollItem` elsewhere should also guard.

**Unanchor before velocity.** `AssemblyLinearVelocity` is silently ignored on anchored parts. Always set `Anchored = false` first.

**ObjectPool template must be parented.** Calling `ObjectPool.new(template, n)` on an unparented Part fails in some executor contexts. Parent to workspace, create pool, then `template:Destroy()`.

**EconomyService must Start before EnemyService calls OnEnemyDied.** Both are auto-discovered services; bootstrap order follows alphabetical name discovery. If order becomes a concern, EnemyService caches `EconomyServiceRef` in `Start()` (after all services are started), so it's always safe.

**Gold lives on Player, not Character.** Never read `character:GetAttribute("Gold")`. The attribute is on the `Player` Instance.

---

## 13. Adding a Chest to a Map

```lua
-- In any server Script or Service Start():
local ChestService = _G.ChestService or require(game.ServerScriptService.Server.Services.ChestService)

-- Place a chest at a fixed world position for Stage 3
ChestService:SpawnChest(Vector3.new(100, 5, 200), 3)

-- Or: spawn at a tagged anchor point in the map
for _, anchor in CollectionService:GetTagged("ChestSpawnPoint") do
    ChestService:SpawnChest(anchor.Position, currentStage)
end
```

Chest models look for `ReplicatedStorage.Shared.Assets.Chests.GoldChest`. If absent, a procedural wooden box with a gold trim strip is used instead. The procedural model is fully functional — add the real asset later without code changes.
