## 2024-05-24 - [Avoid Spatial Queries for Targeting]
**Learning:** Roblox's physics engine spatial queries (like `workspace:GetPartBoundsInRadius`) are exceptionally slow for dense levels or high part counts because they traverse BVH trees to find intersecting parts.
**Action:** Replace `GetPartBoundsInRadius` with `CollectionService:GetTagged()` and $O(N)$ magnitude distance checks. Ensure that instances are deduplicated (as one instance could have multiple tags) and always check from the `RootPart` or `PrimaryPart` to match intended gameplay logic.

## 2024-05-24 - [Safe Modding of Core Libs]
**Learning:** Adding new module `require` statements into low-level shared libraries (like `CombatLib`) without rigorous testing of the dependency chain can cause silent failures or infinite yields in consuming services.
**Action:** When optimizing, stick to native Roblox properties (`model:FindFirstChild`, `model.PrimaryPart`) instead of introducing helper modules (`EnemyLib`) unless you are 100% certain of the module's presence and stability.
