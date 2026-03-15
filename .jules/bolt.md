## 2025-03-15 - Redundant List Rebuild in Hot Paths
**Learning:** O(N) cache rebuilds (`rebuildIgnoreList`) were accidentally manually invoked during specific high-frequency combat events (Scrapper Dash, Shred Shot), neutralizing the O(1) performance gain of caching `OverlapParams`. Because the cache is correctly synchronized with Roblox server events (`PlayerAdded`, `CharacterAdded`), calling the sync method inline was unnecessary and caused performance degradation on every hit.
**Action:** When an optimization involves caching parameters bound to global events, ensure those parameter caches are only consumed and not incorrectly manually rebuilt from inside the hot path.

## 2025-03-15 - Redundant List Rebuild in Hot Paths
**Learning:** O(N) cache rebuilds (`rebuildIgnoreList`) were accidentally manually invoked during specific high-frequency combat events (Scrapper Dash, Shred Shot), neutralizing the O(1) performance gain of caching `OverlapParams`. Because the cache is correctly synchronized with Roblox server events (`PlayerAdded`, `CharacterAdded`), calling the sync method inline was unnecessary and caused performance degradation on every hit.
**Action:** When an optimization involves caching parameters bound to global events, ensure those parameter caches are only consumed and not incorrectly manually rebuilt from inside the hot path.
