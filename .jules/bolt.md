## 2024-05-22 - [Combat Scheduler Overhead]
**Learning:** Using `task.delay` for high-frequency short-lived tasks (like hit tracking cleanup per attack) creates significant scheduler overhead. A simple FIFO queue processed on `Heartbeat` is more efficient even if it slightly delays cleanup for mixed durations.
**Action:** Replace `task.delay` with centralized update loops for high-frequency game logic (e.g. projectiles, buffs, cooldowns).
## 2024-05-28 - ParallelTargetingService O(N) Array Allocation Elimination
**Learning:** `Players:GetPlayers()` allocates a new array on every call in Luau. Calling this inside hot paths like an AI tick (e.g. `ParallelTargetingService:GetTarget` called for every enemy every frame) causes significant garbage collection overhead.
**Action:** Always cache the actual `Player` instance in target registries/caches instead of index numbers to allow O(1) retrieval. Update caches via `PlayerAdded`/`PlayerRemoving` or when regenerating targeting maps, and validate the instance inline (`player.Parent` and `player.Character`) before use.
