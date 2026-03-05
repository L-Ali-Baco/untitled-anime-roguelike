## 2024-05-22 - [Combat Scheduler Overhead]
**Learning:** Using `task.delay` for high-frequency short-lived tasks (like hit tracking cleanup per attack) creates significant scheduler overhead. A simple FIFO queue processed on `Heartbeat` is more efficient even if it slightly delays cleanup for mixed durations.
**Action:** Replace `task.delay` with centralized update loops for high-frequency game logic (e.g. projectiles, buffs, cooldowns).

## 2025-03-05 - [O(k) Spatial Grid lookup for AoE Procs]
**Learning:** `CombatLib.getEnemiesInRadius` was using O(N) naive workspace queries via `GetPartBoundsInRadius`, causing severe performance degradation for high-frequency effects like `ChainLightning` and `Explosion`.
**Action:** Expose `enemyGrid` from `MovementService` and pass it to `CombatLib` to use `QueryRadiusPrecise` when calculating AoE effects on the server, leveraging the O(k) spatial hash for scaling with high enemy count.
