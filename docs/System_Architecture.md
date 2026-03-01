# Enemy AI & Spawn Director — System Architecture

> **Maintainer's Note:** This document describes the complete architecture for the rogue-lite enemy AI and spawn director. It's written for developers who are new to the codebase. Read every section before modifying any service.

---

## 1. High-Level Architecture

```
┌─────────────────────────────────────────────────────────────┐
│                         SERVER                              │
│                                                             │
│  ┌────────────────┐    credits / spawn call                 │
│  │ DirectorService│──────────────────────┐                  │
│  │ (Credit Budget │                      ▼                  │
│  │  State Machine)│          ┌───────────────────────┐      │
│  └────────────────┘          │     EnemyService       │      │
│                              │ (State Machine + Boids)│      │
│  ┌────────────────┐          │                       │      │
│  │ SpawnerService │──spawn───►  activeEnemies table  │      │
│  │ (Map Spawners) │          │                       │      │
│  └────────────────┘          └───────────┬───────────┘      │
│                                          │                  │
│  ┌────────────────┐    FireAllClients     │                  │
│  │ PhysicsService │    (EnemyAttack,      │                  │
│  │ (Collision     │     EnemyHit, etc.)   │                  │
│  │  Groups)       │                       │                  │
│  └────────────────┘                       │                  │
└──────────────────────────────────────────┼──────────────────┘
                                           │ RemoteEvents
┌──────────────────────────────────────────▼──────────────────┐
│                         CLIENT                              │
│                                                             │
│  ┌────────────────────────────────────────────────────┐     │
│  │  EnemyClient (future) / ClientVFX                  │     │
│  │  • Receives enemy model references from server      │     │
│  │  • Renders VFX for attacks (Slam, Swing, Leap)      │     │
│  │  • Plays animations on AnimationController          │     │
│  │  • Enemy models are owned by Workspace, replicated  │     │
│  └────────────────────────────────────────────────────┘     │
└─────────────────────────────────────────────────────────────┘
```

The architecture is **Server-Authoritative / Client-Visual**:

- All game logic (health, damage, positioning, AI state) runs entirely on the **server**.
- Clients receive lightweight events and render visuals only. They never trust client-side positions for hit detection.

---

## 2. Service Responsibilities

| Service           | Owns                                                                   | Does NOT Own                          |
| ----------------- | ---------------------------------------------------------------------- | ------------------------------------- |
| `DirectorService` | Credit budget, pacing state, difficulty curve, elite/horde events      | Spawning logic internals, enemy stats |
| `EnemyService`    | AI state machines, movement, attack execution, boids separation, death | Director pacing, spawn locations      |
| `SpawnerService`  | Map-tagged spawn-point cooldowns, calling `EnemyService:SpawnEnemy()`  | Enemy AI, credit math                 |
| `PhysicsService`  | Collision group registration, group assignment on spawn/dash           | Movement, damage                      |
| `EnemyConfig`     | Enemy stat tables, attack tables, boids parameters                     | Runtime state                         |
| `DirectorConfig`  | Credit growth rates, pacing thresholds, event configs                  | Runtime state                         |

---

## 3. The Server-Authoritative / Client-Visual Rendering Loop

### What the server does every frame

```
RunService.Heartbeat fires (every ~1/60 s)
    │
    ├─ DirectorService: throttled to UpdateInterval (1.0 s)
    │       ├─ Compute currentDifficulty (linear time curve)
    │       ├─ Earn credits (BaseGrowthRate + difficulty scaling)
    │       ├─ Transition Lull ↔ Ramp pacing state
    │       └─ In Ramp: SpawnEnemy() on SpawnTickInterval cadence
    │
    └─ EnemyService: throttled to AI.UpdateRate (0.05 s = 20 Hz)
            ├─ For each active enemy, run State Machine:
            │       Idle → detect player → Chase
            │       Chase → moveTowardTarget() + faceTarget()
            │       Attack → performAttack() (windup then hitbox check)
            │       LeapAttack → performLeapAttack() (4-phase coroutine)
            │       ChargeAttack → performChargeAttack() (3-phase)
            │       Hitstun → wait HitstunDuration
            │       Dead → cleanup
            │
            └─ updateSeparation(dt): boids nudge on staggered subset
```

### What the server sends to clients

All communication is via `RemoteEvent:FireAllClients()`:

| Event Name                 | Payload                                                     | Client Action                       |
| -------------------------- | ----------------------------------------------------------- | ----------------------------------- |
| `EnemyAttack`              | `{ Enemy, Target, HitPosition, Damage, AttackType }`        | Spawn VFX at HitPosition            |
| `EnemyHit`                 | `{ Enemy, Damage, Position }`                               | Flash hit effect on enemy model     |
| `EnemyDied`                | `{ Enemy, Position }`                                       | Play death VFX, dissolve model      |
| `DirectorDifficultyUpdate` | `{ Difficulty, TierName, TierColor, Multipliers, RunTime }` | Sky/fog transitions, UI update      |
| `DirectorEventTriggered`   | `{ EventType, Position, ... }`                              | Screen flash, sound for elite/horde |
| `DirectorHordeWarning`     | `{ Position, EnemyCount, Delay }`                           | Warning UI, danger indicator        |

### Why no Humanoid on enemies

Roblox `Humanoid` objects carry a **significant CPU cost**: they run motor6D IK, physics weight, character animations, and network serialization logic. At 50+ enemies on a mobile device (typically running at 10–25% of a PC's single-core performance), this becomes unacceptable.

Instead, enemies use:

- **Attribute-based health** (`MaxHealth`, `Health` as Instance attributes)
- **`LinearVelocity` constraint** for movement (hardware-accelerated, not Lua)
- **`AlignOrientation` constraint** for facing (no CFrame writes from Lua every frame)
- **`AnimationController` + `Animator`** instead of `Humanoid.Animator`

---

## 4. The Director Credit System

### Formula

```
creditsEarned/sec = BaseGrowthRate + (difficulty - 1.0) × ScalingGrowthRate

where:
  BaseGrowthRate   = 4.0
  ScalingGrowthRate = 2.5
  difficulty       = 1.0 + (minutesElapsed × DifficultyPerMinute)
                   = capped at MaxDifficulty (5.0)
```

At minute 0: `4.0 credits/sec`  
At minute 10 (difficulty 2.0): `4.0 + 1.0 × 2.5 = 6.5 credits/sec`  
At minute 40 (difficulty 5.0, capped): `4.0 + 4.0 × 2.5 = 14.0 credits/sec`

### Pacing State Machine

```
Initial state: Lull
  LullEndTime = now + LullDuration

╔══════════════════════════════════════════════════╗
║  LULL                                           ║
║  Credits accumulate. No spawning.               ║
║  Transition → RAMP when:                        ║
║    credits >= SpendThreshold (30)               ║
║    AND now >= lullEndTime                       ║
╚══════════════════════════════════════════════════╝
                    │
                    ▼
╔══════════════════════════════════════════════════╗
║  RAMP                                           ║
║  Every SpawnTickInterval (0.75s):               ║
║    • Roll elite chance = clamp((diff-2)×0.2,    ║
║                                0, 0.35)         ║
║    • If elite roll passes AND credits >= 5:     ║
║        Spawn Brute, cost 5 credits              ║
║    • Else: spawn random grunt, cost 1 credit    ║
║  Transition → LULL when:                        ║
║    credits <= LullThreshold (8)                 ║
║    Set lullEndTime = now + LullDuration (6s)    ║
╚══════════════════════════════════════════════════╝
```

### Why Credit Budgets (not fixed-timer spawning)?

Fixed-timer spawns create boring, predictable rhythms. Credit budgets allow the Director to:

1. **Save up** over the lull, then spend aggressively — creating a rush-of-enemies feel.
2. **Naturally cap** enemy density (spending more credits faster at high difficulty also depletes the budget faster).
3. **Mix enemy types** organically by their credit cost rather than rigid wave templates.
4. **Allow elite escalation** by making elites cost 5× more, naturally limiting their frequency.

This is the same core philosophy as Risk of Rain 2's Director.

---

## 5. Enemy AI State Machine

Each enemy's entire runtime state is stored in a **`EnemyData` table** in the `activeEnemies` dictionary:

```lua
type EnemyData = {
    Model: Model,
    RootPart: BasePart,
    LinearVelocity: LinearVelocity?,   -- horizontal movement
    AlignOrientation: AlignOrientation?, -- facing
    Animator: Animator?,
    WalkTrack: AnimationTrack?,
    EnemyType: string,
    Config: any,                        -- pointer into EnemyConfig.Types[type]
    State: string,                      -- current AI state
    Target: Player?,
    LastAttackTime: number,
    LastSpecialTimes: { [string]: number },
    -- ... (see EnemyService.luau for full definition)
}
```

### State Transitions

```
         ┌───────────────────────────────────────────┐
         │                 IDLE                      │
         │ No target. Wanders or stands still.       │
         └────────────────┬──────────────────────────┘
                          │ Player within AggroRange
                          ▼
         ┌───────────────────────────────────────────┐
         │                CHASE                      │
         │ moveTowardTarget() + faceTarget()          │
         │ Unstuck impulse if stuck for > 1s         │
         └──┬─────────────────────────────┬──────────┘
            │ dist < AttackRange          │ dist > ChaseRange × 1.2
            ▼                             ▼
         ┌───────────┐              ┌──────────┐
         │  ATTACK   │              │   IDLE   │
         │ windup →  │              │          │
         │ hit check │              └──────────┘
         └─┬─────────┘
           │ if attack type == Leap
           ▼
    ┌────────────────┐
    │  LEAP ATTACK   │
    │ 4-phase async  │
    │ coroutine      │
    └────────────────┘
           │ if attack type == Charge
           ▼
    ┌────────────────┐
    │ CHARGE ATTACK  │
    │ 3-phase        │
    └────────────────┘
           │ enemy takes damage
           ▼
    ┌──────────┐
    │ HITSTUN  │──────────────────────────────► CHASE
    └──────────┘  after HitstunDuration
           │ health <= 0
           ▼
    ┌──────┐
    │ DEAD │ → cleanup, pool return (future)
    └──────┘
```

---

## 6. Object Pool Pattern (Current & Future)

**Current state:** Every `SpawnEnemy()` call clones a model from `ReplicatedStorage`. Every death destroys the model.

**Future pool pattern** (not yet implemented, but architecture is ready):

1. Pre-spawn 10–15 of each enemy type on game load, parent to a hidden folder.
2. `SpawnEnemy()` takes from the pool and sets `Model.Parent = workspace`.
3. `DespawnEnemy()` resets all attributes/constraints and returns model to pool.

The `EnemyData` table structure is already designed with this in mind — all runtime state is in the table, not on the model itself.

---

## 7. Boids-Style Separation (Mathematical, Not Physical)

### The Problem

Without enemy-to-enemy collisions, all enemies that chase the player converge on the same point — they "stack" into one mesh. With physics collisions enabled, Roblox solves hundreds of collision manifolds per frame — way too expensive at 50+ enemies on mobile.

### The Solution: Staggered CFrame Nudge

Every `Heartbeat`, we process **1/4 of all enemies** (staggered round-robin). For each processed enemy, we check all other enemies for proximity. If two are within `Separation.Radius` (3.5 studs) of each other, we compute an inverse-distance repulsion vector and apply it as a **direct CFrame offset** — no physics involved.

```
push_vector = Σ(  (posA - posB).normalized × (radius - dist) / radius  )
              for all B within radius of A

nudge = push_vector.normalized × min(Strength × dt, 0.15)
rootPart.CFrame = CFrame.new(rootPart.Position + nudge) × (rotation only)
```

### Performance Profile

At 100 active enemies with StaggerDivisor = 4:

- 25 enemies processed per frame
- Each does up to 99 neighbor distance checks
- = ~2,475 distance checks at 20Hz = ~49,500 checks/sec
- Each check: 2 subtractions + 2 multiplications + 1 compare = ~5 float ops
- Total: ~250,000 float ops/sec → negligible on even mobile GPUs

At 50 enemies (the cap): ~12,350 checks/sec. Extremely cheap.

### Visual Result

Instead of a blob, enemies form a **dynamic ring** around the player. The ring shape emerges naturally from the combination of:

1. All enemies chasing the player (centripetal force)
2. Enemies pushing each other apart (centrifugal force)

---

## 8. Collision Groups Reference

| Group            | Collides With    | Used For                               |
| ---------------- | ---------------- | -------------------------------------- |
| `Default`        | Everything       | Environment, map geometry              |
| `Players`        | Default, Enemies | Player characters (normal state)       |
| `DashingPlayers` | Default only     | Player characters during dash I-frames |
| `Enemies`        | Default, Players | Enemy parts (NOT each other)           |

The key rule: **`Enemies` does NOT collide with `Enemies`**. This is set in `PhysicsService:Init()`:

```lua
PhysicsService:CollisionGroupSetCollidable("Enemies", "Enemies", false)
```

---

## 9. Adding a New Enemy Type — Step-by-Step Guide

This is the most common developer task. Follow these steps exactly.

### Step 1 — Create an entry in `EnemyConfig.luau`

Open `src/shared/Config/EnemyConfig.luau`. Add a new key inside `Types`:

```lua
Types = {
    -- ... existing types above ...

    --[[
        Golem - Slow armored tank
        Design: Very tanky, charges at far targets. Breaks apart on death.
        Behavior: Chase, hammer slam up close, charge from distance
    ]]
    Golem = {
        Health = 250,
        WalkSpeed = 5,
        Damage = 20,

        AggroRange = 55,
        AttackRange = 12,
        AttackCooldown = 3.0,
        AttackWindup = 0.6,
        AttackDuration = 1.2,

        -- Optional: model's forward vector doesn't match Roblox forward
        -- Measure in Studio and set FacingOffset in degrees
        FacingOffset = 0,

        -- Multi-attack system (optional — can use single attack fallback)
        Attacks = {
            {
                Name = "HammerSlam",
                AnimationId = "rbxassetid://XXXXXXXXXXXXXXX", -- replace with real ID
                Windup = 0.6,
                Duration = 1.2,
                Damage = 20,
                ForwardDist = 8,
                HitRadius = 14,
                VFXType = "Slam",
                Weight = 2,
            },
            {
                Name = "GroundCharge",
                Type = "Charge",    -- triggers performChargeAttack()
                Windup = 0.3,
                Duration = 0.8,
                ChargeSpeed = 45,
                Damage = 18,
                HitRadius = 7,
                VFXType = "Swing",
                Weight = 1,
                MinRange = 18,
                MaxRange = 60,
                Cooldown = 20,
                Chance = 0.5,
            },
        },

        WalkAnimationId = "rbxassetid://XXXXXXXXXXXXXXX",
        WalkAnimationSpeed = 0.4,

        ChaseSpeedMultiplier = 1.0,
        StopDistanceFromTarget = 6,

        HitstunDuration = 0.05,  -- Very hard to stagger
        KnockbackResistance = 0.8,

        XPValue = 30,
        DropChance = 0.3,

        HealthBarOffset = Vector3.new(0, 10, 0),
        NameDisplayed = true,
    },
}
```

**Required fields:** `Health`, `WalkSpeed`, `Damage`, `AggroRange`, `AttackRange`, `AttackCooldown`, `AttackWindup`, `AttackDuration`  
**Optional fields:** `FacingOffset`, `Attacks` (table), `WalkAnimationId`, `WalkAnimationSpeed`, `ChaseSpeedMultiplier`, `StopDistanceFromTarget`, `HitstunDuration`, `KnockbackResistance`

### Step 2 — Add the enemy model to ReplicatedStorage

1. Import your rigged model into Roblox Studio.
2. Name it **exactly** matching the key in `EnemyConfig.Types` (case-sensitive). Example: `Golem`.
3. Ensure the model has a part named `HumanoidRootPart` as its PrimaryPart.
4. Remove any `Humanoid` — the system uses `AnimationController` instead.
5. Add an `AnimationController` + `Animator` inside the model.
6. Place the model inside: `ReplicatedStorage > Shared > Assets > Enemies`

### Step 3 — Verify spawn works

In the Studio Server console, call:

```
game.ReplicatedStorage.Shared.Services.EnemyService:SpawnEnemy("Golem", Vector3.new(0, 5, 20))
```

(Or use the `/horde` chat command on a test place that references your type.)

### Step 4 — Add credit cost to DirectorConfig

If this enemy counts as an elite (costs more credits), add it to the cost check in `DirectorService`. For standard grunts, just add the enemy name to the `grunts` array inside `updateCreditDirector()`:

```lua
local grunts = { "Minion", "Minion", "Minion", "MossFrog", "Shooter", "Golem" }
```

If it's an elite-tier enemy, increase the `eliteChance` threshold for it in the Director or add it as a special case.

### Step 5 — Add VFX handlers on the client (if needed)

If the enemy has a new `VFXType` (e.g., `"GroundSlam"`), open the client handler for `EnemyAttack` remote events and add a case for it, similar to how `"Slam"` and `"Swing"` are handled.

---

## 10. Design Patterns Used

| Pattern                        | Where                                             | Why                                                                                    |
| ------------------------------ | ------------------------------------------------- | -------------------------------------------------------------------------------------- |
| **Finite State Machine (FSM)** | `EnemyService` — per-enemy `State` string         | Simple, predictable, easy to debug; no complex behavior trees needed for swarm enemies |
| **Data-Driven Config**         | `EnemyConfig.Types`, `DirectorConfig`             | Balance tweaks without touching code; all numbers in one place                         |
| **Object Pool** (planned)      | `EnemyService:SpawnEnemy/DespawnEnemy`            | Avoid GC pressure from constant model creation/destruction at 50+ enemies              |
| **Staggered Updates**          | `updateSeparation()` boids, `aiUpdateAccumulator` | Spread expensive work across multiple frames; avoids frame spikes                      |
| **Server-Authoritative**       | All game logic                                    | Prevents cheating; client only renders visuals                                         |
| **Component/Data Table**       | `EnemyData` type                                  | Avoids OOP class instantiation overhead; plain Luau tables are faster                  |
| **Credit Budget FSM**          | `DirectorService` — Lull/Ramp states              | Creates organic pacing (intense bursts + recovery) vs. boring fixed timers             |
| **Constraint-Based Physics**   | `LinearVelocity`, `AlignOrientation`              | Hardware-accelerated movement without Humanoid overhead                                |
| **Collision Group Bypass**     | `PhysicsService` — Enemies/Enemies = false        | Eliminates hundreds of physics manifold solves per frame at 50+ enemies                |

---

## 11. Performance Budget Reference

Target: **stable 30 FPS on a mid-tier 2021 Android phone** (Snapdragon 720G equivalent).

| System                        | Cost Model                         | Mobile Budget                                         |
| ----------------------------- | ---------------------------------- | ----------------------------------------------------- |
| AI State Machine              | O(n) enemies × 20Hz                | ≤ 50 enemies max                                      |
| Boids Separation              | O(n²/4) per 20Hz                   | < 0.3ms at 50 enemies                                 |
| LinearVelocity physics        | Hardware-accelerated               | ~0 Lua overhead                                       |
| RemoteEvent fire (attack VFX) | ~1 event per enemy attack          | Sparse; not per-frame                                 |
| Model replication             | Server-owned models auto-replicate | 50 enemies × ~10 parts = 500 network-serialized parts |

The **50 enemy cap** (`EnemyConfig.AI.MaxActiveEnemies`) is the critical safety valve. The Director's credit depletion naturally limits active enemy count, but the hard cap ensures we never exceed the mobile physics budget regardless of configuration.

---

_Document generated: 2026-02-25. Maintainer: update this document whenever adding new enemy types, Director events, or changing network topology._
