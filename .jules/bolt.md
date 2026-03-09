## 2024-05-22 - [Combat Scheduler Overhead]
**Learning:** Using `task.delay` for high-frequency short-lived tasks (like hit tracking cleanup per attack) creates significant scheduler overhead. A simple FIFO queue processed on `Heartbeat` is more efficient even if it slightly delays cleanup for mixed durations.
**Action:** Replace `task.delay` with centralized update loops for high-frequency game logic (e.g. projectiles, buffs, cooldowns).

## 2024-05-23 - [VFX Instance Pooling]
**Learning:** `DamageNumbers.luau` historically used `Instance.new` for `BillboardGui`, `TextLabel`, `UIStroke`, and an anchor `Part` for every floating number. In combat-heavy scenarios, this causes significant GC pressure. Using `ObjectPool.new()` internally eliminates these spikes by caching the composite UI hierarchy.
**Action:** Always prefer caching generic composite UI elements using `ObjectPool` or custom pools instead of constantly destroying and recreating them via `Instance.new`.
