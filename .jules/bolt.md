## 2024-05-22 - [Combat Scheduler Overhead]
**Learning:** Using `task.delay` for high-frequency short-lived tasks (like hit tracking cleanup per attack) creates significant scheduler overhead. A simple FIFO queue processed on `Heartbeat` is more efficient even if it slightly delays cleanup for mixed durations.
**Action:** Replace `task.delay` with centralized update loops for high-frequency game logic (e.g. projectiles, buffs, cooldowns).
