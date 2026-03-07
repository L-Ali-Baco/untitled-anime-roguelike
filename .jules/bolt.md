## 2024-05-22 - [Combat Scheduler Overhead]
**Learning:** Using `task.delay` for high-frequency short-lived tasks (like hit tracking cleanup per attack) creates significant scheduler overhead. A simple FIFO queue processed on `Heartbeat` is more efficient even if it slightly delays cleanup for mixed durations.
**Action:** Replace `task.delay` with centralized update loops for high-frequency game logic (e.g. projectiles, buffs, cooldowns).

## 2024-05-23 - [VFXHelpers RaycastParams Allocation]
**Learning:** Re-instantiating `RaycastParams` and rebuilding `FilterDescendantsInstances` with `CollectionService:GetTagged` inside high-frequency functions (like `findGroundPos` for VFX) creates significant O(N) allocation overhead per call.
**Action:** Cache the `RaycastParams` object globally within the module and throttle the reconstruction of the exclusion list to a fixed interval (e.g., 1s) using `os.clock()`. Initialize the timer tracker to `-math.huge` to guarantee an immediate update on the first call.
