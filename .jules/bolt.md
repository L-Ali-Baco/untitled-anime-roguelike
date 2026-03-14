## 2024-05-22 - [Combat Scheduler Overhead]
**Learning:** Using `task.delay` for high-frequency short-lived tasks (like hit tracking cleanup per attack) creates significant scheduler overhead. A simple FIFO queue processed on `Heartbeat` is more efficient even if it slightly delays cleanup for mixed durations.
**Action:** Replace `task.delay` with centralized update loops for high-frequency game logic (e.g. projectiles, buffs, cooldowns).

## 2024-05-23 - [Throttling High-Frequency Raycast Exclusions]
**Learning:** In `VFXHelpers.findGroundPos`, rebuilding the Raycast exclusion list inside the O(N) players loop on every call is a major bottleneck during high-frequency raycasting.
**Action:** Throttle exclusion list updates by caching `RaycastParams` and using `os.clock()` to rebuild the list at a fixed interval (e.g., 1.0s). This converts O(N) setup overhead to O(1) for most calls.
