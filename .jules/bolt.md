## 2024-05-22 - [Combat Scheduler Overhead]
**Learning:** Using `task.delay` for high-frequency short-lived tasks (like hit tracking cleanup per attack) creates significant scheduler overhead. A simple FIFO queue processed on `Heartbeat` is more efficient even if it slightly delays cleanup for mixed durations.
**Action:** Replace `task.delay` with centralized update loops for high-frequency game logic (e.g. projectiles, buffs, cooldowns).

## 2024-05-23 - [AOE Attack ID Memory Leak]
**Learning:** Generating unique `attackId` strings *inside* a target loop for AOE attacks creates a new entry in `attackHitTargets` for each enemy hit, bypassing duplicate checks and defeating the cleanup mechanism (which registers only the loop's `attackId` - or in this case, none). This causes a permanent memory leak.
**Action:** Always hoist `attackId` generation outside target loops for AOE attacks and register that single ID for cleanup.
