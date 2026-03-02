# Lighting Presets

Two standalone modes. Apply only one at a time — they are mutually exclusive.

---

## Mode 1 — Cel-Shaded (Flat & Vibrant)

Goal: flat, painted look with moderate shadows, popping colour. Safe for mobile.

### Lighting Service

| Property | Value | Reason |
|---|---|---|
| `Technology` | `ShadowMap` | Hard-edged directional shadows. Future is too PBR; Voxel too low-res. |
| `Ambient` | `[80, 80, 80]` | Neutral grey lift — no pitch-black craters under models. |
| `OutdoorAmbient` | `[100, 100, 120]` | Slight cool fill from the sky side. |
| `Brightness` | `2.5` | Punchy directional without overexposing. |
| `ColorShift_Top` | `[255, 255, 240]` | Warm lit-face tint. |
| `ColorShift_Bottom` | `[40, 40, 60]` | Cool shadow tint reads as "cel shadow". |
| `FogEnd` | `2000` | Disables fog; haze fights the flat look. |
| `EnvironmentDiffuseScale` | `0` | Kills PBR bounce — biggest realism driver. |
| `EnvironmentSpecularScale` | `0` | Kills environment specular. |

### Post-Processing

**ColorCorrectionEffect**

| Property | Value |
|---|---|
| `Saturation` | `0.6` |
| `Contrast` | `0.15` |
| `Brightness` | `0` |

**BloomEffect**

| Property | Value |
|---|---|
| `Intensity` | `0.4` |
| `Size` | `24` |
| `Threshold` | `0.95` |

> No Atmosphere. No SunRaysEffect. No DepthOfField.

---

## Mode 2 — Spider-Verse / Extreme Comic Contrast

Goal: pitch-black shadows, violent colour separation, deep ink. Works best paired with
`ComicShaderController` (crosshatch injection) and `OutlineController` (bold outlines).

> **Mobile warning:** `Bloom.Intensity = 1.5` is expensive. On mobile consider reducing to `0.5` or disabling. Contrasted shadows at ambient [0,0,0] can also hide gameplay-critical elements — test with real players.

### Lighting Service

| Property | Value | Reason |
|---|---|---|
| `Technology` | `ShadowMap` | Hard-edged directional shadows. Future adds too much ambient GI which softens the blacks. |
| `Ambient` | `[0, 0, 0]` | **Pure black shadows.** No fill light — shadow side of any model is absolute black. |
| `OutdoorAmbient` | `[0, 0, 0]` | Ensures sky-lit indirect fill is also zero. |
| `Brightness` | `4.0` | Violent directional punch. Lit areas are overexposed relative to the black shadows. |
| `ColorShift_Top` | `[255, 248, 220]` | Warm cream on lit faces — mimics halftone paper stock. |
| `ColorShift_Bottom` | `[0, 0, 0]` | Keeps the shadow-side contribution zero even with rounding. |
| `FogEnd` | `3000` | Disabled. Fog destroys ink-black depth. |
| `EnvironmentDiffuseScale` | `0` | Must be zero or ambient bounce will lift the blacks. |
| `EnvironmentSpecularScale` | `0` | Same. |

### Post-Processing

**ColorCorrectionEffect** — the contrast is the primary tool for the Spider-Verse look:

| Property | Value | Notes |
|---|---|---|
| `Saturation` | `1.2` | Pushes colours past natural saturation into "comic ink" vibrancy. Cap at `1.5` before it looks neon. |
| `Contrast` | `0.6` | Crushes midtones toward either black or white. This is the biggest single lever. Start here, increase toward `0.8` for more extreme results. |
| `Brightness` | `0.05` | Slight lift to prevent the very darkest UI areas from clipping to solid black on OLED displays. |
| `TintColor` | `[255, 252, 240]` | Very slight warm cream tint — mimics yellowed comic paper. Use `[255, 255, 255]` for neutral. |

**BloomEffect** — targets Neon parts only at this threshold:

| Property | Value | Notes |
|---|---|---|
| `Intensity` | `1.5` | Aggressive bloom on Neon VFX so attacks and skills punch through the dark aesthetic. |
| `Size` | `28` | Wider bloom radius for a more graphic "halation" look around glowing elements. |
| `Threshold` | `0.9` | Slightly lower than Mode 1 so near-white faces also get a subtle halation. |

**No** DepthOfField. **No** Atmosphere. **No** SunRaysEffect.

### Hardening shadow edges (command bar, run once)

```lua
-- Roblox's default sun has ShadowSoftness = 0.14; force it to 0 for ink-hard edges.
local sun = game.Lighting:FindFirstChildOfClass("Sun")
if sun then sun.ShadowSoftness = 0 end
```

### Per-asset discipline for Mode 2

The black shadow only reads as "ink" if the geometry material has zero reflectance.
The `AssetSanitizer_CommandBar.lua` script handles enemies. For environment geometry:

| Surface | Material | Reflectance | CastShadow |
|---|---|---|---|
| Enemy bodies | `SmoothPlastic` | `0` | `false` |
| Environment floors/walls | `SmoothPlastic` | `0` | `true` |
| Neon VFX | `Neon` | — | `false` |
| Ink-line outlines (Highlights) | — | — | — |

Avoid `Glass`, `Metal`, `Diamond`, `Foil` — they all introduce specular reflection that breaks the flat comic reads.

### Quick test checklist

- [ ] An enemy standing in direct sunlight: lit face is overexposed warm white, shadow side is **absolute black**. No grey midtone band between them — just a hard line.
- [ ] The same enemy seen from behind: the entire body is black silhouette. Only the Highlight outline (from `OutlineController`) shows the form.
- [ ] Neon VFX (hit sparks, beacon glow) have a visible bloom halo that pops against the black void.
- [ ] `Saturation` is high enough that the enemy's colour tones look painted, not photographed.
- [ ] The crosshatch texture (from `ComicShaderController`) is visible on lit faces and disappears into the black on shadow faces — this is correct.

---

## Common to both modes

```lua
-- The sun shadow edge — run once in command bar for both modes
local sun = game.Lighting:FindFirstChildOfClass("Sun")
if sun then sun.ShadowSoftness = 0 end
```

Do not add:
- `Atmosphere` — physical haze
- `SunRaysEffect` — photorealistic god rays
- `DepthOfFieldEffect` — bokeh blur
