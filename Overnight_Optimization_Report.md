# Overnight Optimization Report

**Date:** 2024-05-22
**Author:** Optimization Agent (Jules)
**Status:** Diagnostic Complete, Staging Ready

## Executive Summary
This report identifies critical performance bottlenecks primarily affecting low-end mobile devices. The core issues stem from excessive object allocation (GC pressure), unoptimized loops in `RunService`, and inefficient network replication.

---

## 1. CombatController.luau (Client)
**Location:** `src/client/Core/CombatController.luau`

### Bottleneck: Flamethrower Logic in Heartbeat
- **Issue:** The `handleFlamethrowerTick` function runs every frame while attacking. It creates ~6 `Part` instances, `TweenService` tweens, and `OverlapParams` *per frame*.
- **Impact:** Massive GC churn (creating/destroying ~360 parts/sec at 60fps), causing frame drops and stuttering on mobile.
- **Line:** ~545 (`handleFlamethrowerTick`)

### Bottleneck: Instance.new inside Loop
- **Issue:** `getPartFromPool` creates new parts if pool is empty, but `returnPartToPool` logic is basic. `TweenService:Create` is called inside the loop for every particle.
- **Impact:** `TweenService` overhead is significant. Manual CFrame updates are faster for simple linear projectiles.

### Proposed Solution
- **Voxel Pool:** Implement a strict, pre-allocated circular buffer for flame voxels.
- **Manual Simulation:** Replace `TweenService` with a single loop in `Heartbeat` that updates CFrame of all active flame voxels. This removes Tween overhead entirely.
- **Cached Params:** create `OverlapParams` once at module level and reuse it.

---

## 2. CombatEffects.luau (Client)
**Location:** `src/client/VFX/CombatEffects.luau`

### Bottleneck: Lack of Object Pooling
- **Issue:** Every `SpawnHitSpark`, `SpawnSlashTrail`, and `SpawnFireHitEffect` call creates new `Attachment`, `ParticleEmitter`, and `Part` instances, then destroys them with `Debris`.
- **Impact:** High-frequency combat creates thousands of short-lived instances, triggering aggressive Lua Garbage Collection pauses.
- **Line:** ~35 (`SpawnSlashTrail`), ~75 (`SpawnHitSpark`)

### Proposed Solution
- **PartCache:** Implement a robust `PartCache` module (or local table pooling) for these temporary visual effects.
- **Particle Cache:** Pool `Attachment` + `ParticleEmitter` combinations. Enable/Disable `Enabled` property instead of destroying.

---

## 3. EnemyVFXController.luau (Client)
**Location:** `src/client/Core/EnemyVFXController.luau`

### Bottleneck: Highlight Spam
- **Issue:** `createAttackIndicator` creates a `Highlight` instance for every enemy attack. Roblox has a hard limit of 31 active Highlights. Exceeding this causes rendering glitches or crashes on mobile.
- **Impact:** Visual artifacts and potential crashes.
- **Line:** ~50 (`createAttackIndicator`)

### Bottleneck: Unpooled Debris
- **Issue:** Similar to `CombatEffects`, it uses `Debris:AddItem` for particles and indicators.

### Proposed Solution
- **Highlight Manager:** Use a single shared `Highlight` or a small pool. Better yet, for mobile, fallback to a `BillboardGui` or `SelectionBox` if performance is critical.
- **Pooling:** Integrate with the caching system proposed for `CombatEffects`.

---

## 4. CombatService.luau (Server)
**Location:** `src/server/Services/CombatService.luau`

### Bottleneck: O(N) Queue Cleanup
- **Issue:** The `activeAttacks` cleanup loop uses `table.remove(t, 1)` inside a `while` loop.
- **Impact:** `table.remove` shifts all elements down. Doing this repeatedly is O(N^2) behavior in worst cases, causing server lag spikes during large battles.
- **Line:** ~395 (`RunService.Heartbeat`)

### Bottleneck: Global Replication
- **Issue:** `HitConfirmed` and `RangedHitConfirmed` events are fired to `AllClients`.
- **Impact:** A player attacking in Zone A sends data to a player in Zone B, wasting bandwidth.

### Proposed Solution
- **Queue Optimization:** Use a pointer-based queue or `table.move` to bulk remove expired items.
- **Spatial Replication:** Filter clients by distance before firing remote events (e.g., only clients within 100 studs of the event).

---

## 5. EnemyService.luau (Server)
**Location:** `src/server/Services/EnemyService.luau`

### Bottleneck: O(E*P) AI Loop
- **Issue:** `getNearestPlayer` iterates through all players for *every* enemy update. It also calls `FindFirstChild` repeatedly.
- **Impact:** As enemy count (E) and player count (P) grow, the CPU cost scales quadratically. 50 enemies * 10 players = 500 checks per tick.
- **Line:** ~75 (`getNearestPlayer`)

### Proposed Solution
- **Spatial Hash / Cache:** Maintain a cached list of valid player RootParts (updated on CharacterAdded/Removing).
- **Tagging:** Use `CollectionService` or a simple distance check optimization (only check nearest if last check was > X seconds ago, or use a spatial partition).
- **Throttling:** Stagger AI updates so not all enemies update on the same frame.

---

## Next Steps
Proceeding to create `Optimization_Drafts/` and implementing these fixes.
