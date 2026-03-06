## 2024-05-22 - [Combat Scheduler Overhead]
**Learning:** Using `task.delay` for high-frequency short-lived tasks (like hit tracking cleanup per attack) creates significant scheduler overhead. A simple FIFO queue processed on `Heartbeat` is more efficient even if it slightly delays cleanup for mixed durations.
**Action:** Replace `task.delay` with centralized update loops for high-frequency game logic (e.g. projectiles, buffs, cooldowns).

## 2024-11-20 - [Failed SpatialGrid Reuse for AoE]
**Learning:** Attempting to reuse a specialized `SpatialGrid` (e.g., from `MovementService` tuned for small boids separation) for generic AoE queries in `CombatLib` fails because: 1) The grid sync is conditionally disabled if separation is off, leading to stale data. 2) The cell size is too small for large explosion radii, silently missing targets. 3) It only tracks registered enemies, making destructibles and PvP targets invulnerable to AoE.
**Action:** Do not reuse state-dependent, narrowly-tuned spatial grids for general-purpose physics queries. O(N) `GetPartBoundsInRadius` is safer when the target types and query radii vary wildly unless a dedicated, globally-updated combat grid is implemented.
