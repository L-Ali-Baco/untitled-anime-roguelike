# Performance Audit Plan — Late-Game Stability
**Date:** 2026-02-26
**Engineer:** Senior Roblox Performance Optimizer
**Target:** 50+ enemies, 4 players, heavy VFX + proc chains without frame drops or server ping spikes

---

## Audit Report

### 🟢 Already Good — Do Not Touch
| Area | Status |
|---|---|
| EnemyService AI accumulator throttle (20 Hz gate) | ✓ Correct |
| MovementService staggered Boids (1/4 per frame) | ✓ Correct |
| Lazy enemy class loading (`loadedClasses` cache) | ✓ Correct |
| SlashVFX `RenderStepped` guarded by `alive` flag + `part.Parent` | ✓ Correct |
| `Debris:AddItem` for VFX cleanup | ✓ Correct |
| CombatService centralized `activeAttacks` FIFO queue | ✓ Correct |
| Server never replicates raw CFrame / position data | ✓ Correct |
| Per-attack hit deduplication (`attackHitTargets`) | ✓ Correct |

---

## 🔴 Critical Bottlenecks

### TASK 1 — AI Tick: pcall closure allocation (EnemyService.luau)
**File:** `src/server/Services/EnemyService.luau` line 545
**Problem:** `pcall(function() enemy:Tick(dt) end)` creates a brand-new function
closure on **every tick for every enemy**. At 50 enemies × 20 Hz = **1,000 function
allocations/second** hitting the Luau GC continuously.

```lua
-- BEFORE (bad)
pcall(function()
    enemy:Tick(dt)
end)

-- AFTER (zero allocation)
pcall(enemy.Tick, enemy, dt)
```

---

### TASK 2 — canAttack O(n²) linear scan (EnemyService.luau)
**File:** `src/server/Services/EnemyService.luau` — `buildServicesBag` `canAttack`
**Problem:** Every enemy calling `canAttack` iterates the entire `activeEnemies`
table to count attackers. With 50 enemies and 10 simultaneously requesting attack
at 20 Hz → **10 × 50 = 500 full-table scans per second**. Scales quadratically.

**Fix:** Maintain a `{ [Player]: number }` counter table. Increment when an enemy
enters Attack/LeapAttack/ChargeAttack; decrement when they leave. `canAttack` is
then an O(1) lookup. BaseEnemy must call `notifyAttackStart(player)` /
`notifyAttackEnd(player)` via the services bag when transitioning state.

---

### TASK 3 — EnemyStateChanged spamming FireAllClients (EnemyService.luau)
**File:** `src/server/Services/EnemyService.luau` — `fireEnemyStateChanged`
**Problem:** `FireAllClients(model, state)` fires on **every single AI state
transition** with no rate-limit or deduplication. At 50 enemies, transitions like
Idle→Chase happen constantly. Each call sends to all 4 clients.
At worst: 50 enemies × 3 transitions/second × 4 clients = **600 remote deliveries/second**.

**Fix:** Inside `fireEnemyStateChanged`, only fire if the state actually changed
(track last-sent state per model). Additionally cap to max 1 fire per enemy per
0.1 seconds.

---

### TASK 4 — OverlapParams.new() inside hot paths (CombatService.luau)
**File:** `src/server/Services/CombatService.luau`
**Problem:** `onRequestRangedHit` (Scrapper: 8 shots/sec × 4 players = 32/sec) and
`onRequestDashHit` both call `OverlapParams.new()` and allocate a fresh
`ignoreList = {}` + `Players:GetPlayers()` loop on **every invocation**.

**Fix:** Cache one `OverlapParams` object at module level. Maintain a cached
`ignoreList` that is rebuilt only when `Players.PlayerAdded` or
`Players.PlayerRemoving` fires.

---

## 🟡 Moderate Bottlenecks

### TASK 5 — ShowDamageNumber per-hit FireAllClients
**Files:** `src/server/Skills/ScrapperSkills.luau`, `src/server/Services/ProcService.luau`
**Problem:** `ShowDamageNumber` fires one `FireAllClients` per enemy hit. When
ChainLightning procs on 10 enemies simultaneously, that is **10 separate network
packets** sent to all clients in the same frame.

**Fix:** Accumulate hits into a batch table within the attack/proc scope, then fire
a single `ShowDamageNumbers` (plural) remote with an array payload. One packet
replaces N.

---

### TASK 6 — CombatService cleanup Heartbeat runs every frame
**File:** `src/server/Services/CombatService.luau` line 815
**Problem:** The `activeAttacks` cleanup Heartbeat connection runs at 60 Hz even
when `activeAttacks` is completely empty (i.e., between fights).

**Fix:** Add `if #activeAttacks == 0 then return end` as the first line of the
cleanup closure.

---

### TASK 7 — O(n) enemy count loops (EnemyService.luau)
**File:** `src/server/Services/EnemyService.luau`
**Problem:** `GetEnemyCount()` and the cap check in `SpawnEnemy` both do
`for _ in activeEnemies do count += 1 end`. Called every spawn attempt.

**Fix:** Maintain a `local activeEnemyCount = 0` integer, increment on register,
decrement on death/unregister.

---

## Execution Order (one task at a time)

| # | Task | File | Severity | Effort |
|---|---|---|---|---|
| 1 | Fix pcall closure allocation | EnemyService | 🔴 | 1 line |
| 2 | Fix canAttack O(n²) → O(1) | EnemyService | 🔴 | ~40 lines |
| 3 | Rate-limit EnemyStateChanged | EnemyService | 🔴 | ~20 lines |
| 4 | Cache OverlapParams in CombatService | CombatService | 🔴 | ~25 lines |
| 5 | Batch ShowDamageNumber | ScrapperSkills + ProcService | 🟡 | ~30 lines |
| 6 | Guard empty Heartbeat | CombatService | 🟡 | 1 line |
| 7 | Running enemy count | EnemyService | 🟡 | ~10 lines |

---

## Status
- [x] Task 1 — pcall fix (`EnemyService.luau` line 545)
- [x] Task 2 — canAttack O(1) (`EnemyService.luau` + `BaseEnemy.luau`)
- [x] Task 3 — EnemyStateChanged rate-limit (`EnemyService.luau`)
- [x] Task 4 — OverlapParams cache (`CombatService.luau`)
- [x] Task 5 — ShowDamageNumber batch (`ScrapperSkills.luau` + `CombatController.luau` + `Remotes.luau`)
- [x] Task 6 — Heartbeat guard (`CombatService.luau`)
- [x] Task 7 — Running enemy count (`EnemyService.luau`)
