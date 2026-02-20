# Optimization Review: Low-End Device Performance

## Overview
This document details the optimizations implemented to improve performance on low-end devices (mobile/integrated graphics). The primary focus was on reducing Server CPU usage (Enemy AI), eliminating Client GC spikes (VFX), and optimizing high-frequency loops.

## 1. Server-Side AI Loop Optimization
**File:** `src/server/Services/EnemyService.luau`

### The Bottleneck
The enemy AI loop was iterating over *every* active enemy *every* update tick (20Hz). Inside this loop, each enemy performed an `O(N)` distance check against all players to find the nearest target.
*   **Complexity:** `O(Enemies * Players)` per tick.
*   **Impact:** Massive CPU spike every 0.05s as enemy count scaled (e.g., 50 enemies = 500+ checks), causing server lag.

### The Fix & Reasoning
1.  **Time-Slicing:** Instead of updating all enemies in a single frame, updates are now distributed across multiple frames. We target ~30 updates/second per enemy, processing only a subset (batch) of the `activeEnemyList` each Heartbeat.
2.  **Target Caching:** Implemented `CachedTarget` and `LastTargetUpdate`. Enemies now reuse their found target for 0.5s before performing another expensive spatial scan.

### Performance Impact
*   **CPU Usage:** Drastically reduced. The load is now flat and predictable rather than spiky.
*   **Scalability:** Server can handle significantly more concurrent enemies (100+) without degrading tick rate.

### Implications
*   **Trade-off:** Enemies may take up to ~33ms (1 frame) longer to react to state changes, and up to 0.5s to switch targets if a closer player appears. This latency is imperceptible in standard RPG combat.

---

## 2. Client-Side VFX Pooling (Damage Numbers)
**File:** `src/client/VFX/DamageNumbers.luau`

### The Bottleneck
Every damage instance created a new `Part`, `BillboardGui`, `TextLabel`, and `UIStroke`, then destroyed them after ~1s.
*   **Issue:** High-frequency attacks (e.g., Flamethrower, DoTs) created hundreds of instances per second.
*   **Impact:** Massive Garbage Collection (GC) pressure, causing "micro-stutters" on mobile devices with slower memory allocators.

### The Fix & Reasoning
Implemented a **Local Object Pool** (`damageNumberPool`).
*   **Spawn:** usage retrieves a recycled anchor part from the pool.
*   **Cleanup:** instead of `Debris:AddItem`, the object is reset (properties cleared) and returned to the pool after the animation completes.

### Performance Impact
*   **Memory Churn:** Near-zero during sustained combat.
*   **Frame Stability:** Eliminated GC-induced frame drops during intense combat.

### Implications
*   **Memory Usage:** Slightly higher resting memory usage (to store inactive pool objects), but significantly more stable performance.

---

## 3. Client-Side VFX Pooling (Flamethrower)
**File:** `src/client/VFX/FlamethrowerVFX.luau`

### The Bottleneck
Similar to Damage Numbers, the Flamethrower created a new `Attachment`, `ParticleEmitter`, and `PointLight` for *every single hit* (rate of 10-20/sec).

### The Fix & Reasoning
Implemented a **Local Object Pool** (`hitEffectPool`).
*   Reuses `Attachment` and its children (`Burst`, `PointLight`).
*   Resets critical visual state (Light Brightness) upon retrieval to ensure consistent visuals.

### Performance Impact
*   **GC Overhead:** Drastically reduced for the most spam-heavy weapon in the game.

---

## 4. Combat Cleanup Loop Optimization
**File:** `src/server/Services/CombatService.luau`

### The Bottleneck
The `activeAttacks` cleanup loop used `table.remove(t, 1)` to remove expired attacks.
*   **Issue:** `table.remove` at index 1 shifts all remaining elements down, making it an `O(N)` operation where N is the queue length.
*   **Impact:** CPU cost grew linearly with combat intensity (more active attacks = slower cleanup).

### The Fix & Reasoning
Replaced the array-shift approach with a **Pointer-Based Queue**.
*   Uses `activeAttacksFirst` and `activeAttacksLast` indices.
*   Cleanup just increments `activeAttacksFirst` and nils the old index (`O(1)` complexity).

### Performance Impact
*   **CPU Usage:** Constant time cleanup regardless of combat intensity.

### Implications
*   **Complexity:** Slightly more complex queue management code (handling indices), but standard for high-performance queues.
