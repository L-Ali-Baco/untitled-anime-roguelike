--[[
	ASSET SANITIZER — Studio Command Bar Script
	============================================
	Paste this entire block into the Studio Command Bar and press Enter.

	What it does:
	  1. Finds every BasePart inside the "Enemies" folder in workspace.
	  2. Sets Material = SmoothPlastic on every part (kills light-reactive surfaces).
	  3. Sets Reflectance = 0 (eliminates plastic sheen).
	  4. Deletes any Texture or SurfaceAppearance child instances (removes baked
	     normal maps, roughness maps, etc. that fight the flat-colour base).
	  5. Prints a summary of how many parts and surfaces were modified.

	Run it ONCE after importing or replacing your enemy models.
	It is safe to re-run — it is fully idempotent.

	TARGET: Change this path if your enemies live somewhere other than
	        workspace.Enemies.
]]

local TARGET_ROOT = workspace:FindFirstChild("Enemies")

if not TARGET_ROOT then
	warn("[AssetSanitizer] No 'Enemies' folder found in workspace. Change TARGET_ROOT.")
	return
end

local partCount = 0
local surfaceCount = 0

for _, desc in TARGET_ROOT:GetDescendants() do
	-- ── Sanitize every BasePart ───────────────────────────────────────────
	if desc:IsA("BasePart") then
		desc.Material = Enum.Material.SmoothPlastic
		desc.Reflectance = 0
		desc.CastShadow = false   -- Optional: disable per-part shadows for perf.
		                          -- Remove this line if you want self-shadowing.
		partCount += 1

		-- ── Destroy Texture and SurfaceAppearance children ────────────────
		for _, child in desc:GetChildren() do
			if child:IsA("Texture") or child:IsA("SurfaceAppearance") then
				child:Destroy()
				surfaceCount += 1
			end
		end
	end

	-- ── Also destroy any top-level SurfaceAppearances under Models ────────
	-- (Roblox sometimes nests them directly under a Model, not a Part.)
	if desc:IsA("SurfaceAppearance") then
		desc:Destroy()
		surfaceCount += 1
	end
end

print(string.format(
	"[AssetSanitizer] Done. %d parts sanitised, %d surface assets removed.",
	partCount,
	surfaceCount
))
