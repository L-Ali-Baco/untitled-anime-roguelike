# Humanoid-Free Enemy System Design

## Problem

Each enemy currently uses a **Humanoid** instance for health, movement, and death detection. Humanoids are the most expensive object in Roblox — they run internal state machines, clothing deformation, animation evaluation, and physics integration every frame. For a Risk of Rain-style game targeting 30-50+ simultaneous enemies, this tanks performance especially on mobile (70% of players).

## Solution: Attribute Health + AnimationController + LinearVelocity

Replace enemy Humanoids with three lightweight primitives:

| Humanoid Feature       | Replacement                                                                    |
| ---------------------- | ------------------------------------------------------------------------------ |
| `Health` / `MaxHealth` | Attributes on the Model                                                        |
| `TakeDamage()`         | Custom `EnemyLib:TakeDamage()` function                                        |
| `Died` event           | `AttributeChanged("Health")` → fires when Health ≤ 0                           |
| `MoveTo()`             | `LinearVelocity` constraint on root part (same pattern as player ClassService) |
| `WalkSpeed`            | Attribute + manual velocity calculation                                        |
| Animator               | `AnimationController` + `Animator` (no Humanoid needed)                        |

---

## Architecture

### 1. `EnemyLib` — Shared Helper Module (NEW)

A shared library in `src/shared/Lib/EnemyLib.luau` that **all files use** instead of touching Humanoid directly:

```luau
-- Core API
EnemyLib:IsEnemy(model) → boolean        -- checks "IsEnemy" attribute
EnemyLib:IsAlive(model) → boolean        -- checks Health > 0
EnemyLib:GetHealth(model) → number       -- reads Health attribute
EnemyLib:GetMaxHealth(model) → number    -- reads MaxHealth attribute
EnemyLib:GetRootPart(model) → BasePart?  -- finds root part
EnemyLib:TakeDamage(model, amount)       -- reduces Health, fires death if ≤ 0
EnemyLib:SetHealth(model, value)         -- directly sets health
```

This creates a single abstraction layer so the 20+ files referencing Humanoid **only need to swap to EnemyLib calls** instead of each reimplementing the logic.

### 2. Enemy Model Structure (Changed)

Before (current):

```
EnemyModel (Model)
├── Humanoid           ← REMOVED
├── HumanoidRootPart
├── Head
└── Weld
```

After:

```
EnemyModel (Model)
├── AnimationController  ← NEW (for rigged models)
│   └── Animator
├── HumanoidRootPart     (renamed to "Root" or kept for compat)
├── Head
├── Weld
├── LinearVelocity       ← NEW (movement constraint)
└── Attributes:
    ├── IsEnemy = true
    ├── Health = 30
    ├── MaxHealth = 30
    ├── WalkSpeed = 14
    └── IsDead = false
```

### 3. Movement System (Changed)

Replace `Humanoid:MoveTo(targetPos)` with a velocity-based approach:

```luau
-- In EnemyService AI update:
local direction = (targetPos - currentPos).Unit
local speed = model:GetAttribute("WalkSpeed") or 14

-- Set LinearVelocity (server-owned constraint on root part)
linearVelocity.VectorVelocity = direction * speed
```

For stopping:

```luau
linearVelocity.VectorVelocity = Vector3.zero
```

This is the **same pattern** already used in `ClassService.luau` for player characters (lines 249-265), so it's proven in this codebase.

### 4. Animation System (Changed)

Rigged models (like Brute) get `AnimationController` + `Animator` instead of relying on a Humanoid for animation:

```luau
-- On spawn (server or client):
local animController = Instance.new("AnimationController")
local animator = Instance.new("Animator")
animator.Parent = animController
animController.Parent = enemyModel

-- Playing an animation:
local animTrack = animator:LoadAnimation(animationObject)
animTrack:Play()
```

This supports your `Brute_Ground_Attack` animation and any future walk/idle cycles.

### 5. Death System (Changed)

Replace `Humanoid.Died`:

```luau
-- In EnemyLib:TakeDamage():
model:SetAttribute("Health", newHealth)
if newHealth <= 0 then
    model:SetAttribute("IsDead", true)
    -- Server-side cleanup triggers
end

-- Listeners use:
model:GetAttributeChangedSignal("IsDead"):Connect(function()
    -- death logic
end)
```

### 6. `CharacterLib` Update

Update `CharacterLib` to support both players (Humanoid) and enemies (attributes):

```luau
function CharacterLib:IsAlive(model): boolean
    -- Check attribute-based enemies first
    if model:GetAttribute("IsEnemy") then
        local health = model:GetAttribute("Health") or 0
        return health > 0
    end
    -- Fall back to Humanoid for players
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    return humanoid ~= nil and humanoid.Health > 0
end
```

---

## Files Affected

### Server

| File                        | Change                                                                                                                           |
| --------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `EnemyService.luau`         | **Major rewrite** — remove Humanoid creation, use LinearVelocity for movement, attribute-based health, AnimationController setup |
| `CombatService.luau`        | Update `getTargetHumanoid()` → use `EnemyLib:IsAlive()` and `EnemyLib:TakeDamage()`                                              |
| `DirectorService.luau`      | Update elite spawn to set attributes instead of Humanoid stats                                                                   |
| `ProcService.luau`          | Update 3 functions that reference enemy Humanoid for damage                                                                      |
| `SkillService.luau`         | Minor — if it references enemy Humanoid                                                                                          |
| `TrainingDummyService.luau` | Update to use attribute-based health OR keep Humanoid (training dummies are few)                                                 |
| `BikerKingSkills.luau`      | Update 5 `FindFirstChildOfClass("Humanoid")` calls                                                                               |
| `VanguardSkills.luau`       | Update 4 Humanoid references                                                                                                     |
| `GunslingerSkills.luau`     | Update 2 Humanoid references                                                                                                     |

### Shared

| File                | Change                                                                    |
| ------------------- | ------------------------------------------------------------------------- |
| `EnemyLib.luau`     | **NEW** — shared helper for enemy health/alive checks                     |
| `CharacterLib.luau` | Update `IsAlive()` and `GetHumanoid()` to support attribute-based enemies |

### Client

| File                       | Change                                                                                                                                |
| -------------------------- | ------------------------------------------------------------------------------------------------------------------------------------- |
| `TargetingController.luau` | Update `getValidTargets()` and `onHeartbeat()` — use `EnemyLib:IsAlive()` instead of `Humanoid.Health`                                |
| `EnemyHealthBar.luau`      | Update `createHealthBar()` to use attribute-based health — listen to `AttributeChanged("Health")` instead of `Humanoid.HealthChanged` |
| `HitstopController.luau`   | Update enemy Humanoid WalkSpeed freeze — use attribute or just skip (enemies don't need walk speed freeze for hitstop)                |
| `EnemyVFXController.luau`  | Minimal changes — mostly uses Model references already                                                                                |
| `CombatController.luau`    | Update hitbox validation (`hitModel:FindFirstChildOfClass("Humanoid")`) → use `EnemyLib:IsAlive()`                                    |

---

## What We're NOT Changing

- **Player characters** keep their Humanoid — players are few (4 max) and need Humanoid for the Roblox character system
- **Training dummies** — optional to convert, they're few and isolated
- **Client VFX** — mostly works with Models already, minimal changes
- **Remotes** — no changes needed, they pass Model references

---

## Verification Plan

Since there are no automated tests for gameplay systems, verification will be done in Roblox Studio:

### Manual Testing (in Roblox Studio via `rojo serve`)

1. **Enemy Spawning** — Spawn enemies via Director or SpawnerService, verify they appear with correct health attributes and no Humanoid
2. **Enemy Movement** — Verify enemies chase the player using LinearVelocity, stop at correct range, and don't jitter
3. **Damage & Death** — Attack enemies, verify:
   - Health attribute decreases
   - Health bar UI updates correctly
   - Enemy dies and dissolves when health reaches 0
   - Damage numbers appear
4. **Animations** — Verify Brute plays `Brute_Ground_Attack` animation via AnimationController
5. **Targeting** — Verify TargetingController finds enemies (soft-lock & auto-aim still work)
6. **Skills** — Test Vanguard, Gunslinger, and BikerKing skills against new enemies
7. **Director System** — Run for 3+ minutes, verify difficulty scaling applies correctly to attributes
8. **Performance** — Spawn 30+ enemies, verify FPS is improved vs before (use Roblox MicroProfiler)

### Lint Check

```bash
selene src/
```
