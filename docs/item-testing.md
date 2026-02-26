# Item Testing Playbook
**Game:** RobloxDevStack roguelike
**Date:** 2026-02-26
**Tester:** QA (solo, local Studio session)

---

## Quick Command Reference

All commands are typed in the in-game chat.

| Command | What it does |
|---|---|
| `/give <itemKey>` | Grants 1 stack of an item (partial name match) |
| `/enemy <type>` | Spawns an enemy in front of you (`Minion`, `Brute`, `Shooter`, `MossFrog`) |
| `/chest` | Spawns a W1_Chest at your feet |
| `/scrap <amount>` | Adds scrap currency (default 25 if no amount given) |
| `/nospawn` | Disables background enemy spawning (keeps arena clean for testing) |
| `/spawn` | Re-enables spawning |

**Recommended session setup before any test:**
```
/nospawn
```
Then spawn enemies manually with `/enemy` as needed.

---

## Damage Number Reference (No Items)

These are the raw floor values with zero item stacks. Use them as your baseline.

| Attack | Base Damage |
|---|---|
| Vanguard M1 Hit 1 | 18 |
| Vanguard M1 Hit 2 | 28 |
| Vanguard M1 Hit 3 (Finisher) | 48 |
| Aerial Slash (M2) | ~2.2 × wave calc |
| Proc base (Chain Lightning / Explosion) | 10 |

---

## TEST 1 — SwiftBoots
**Item key:** `SwiftBoots`
**Type:** Passive stat (WalkSpeed +15% per stack, Multiplier)

### Setup
```
/nospawn
/give SwiftBoots
```

### What to test

| Stacks | Command | Expected Output |
|---|---|---|
| Baseline | *(no item, just walk around)* | Normal movement speed |
| 1 stack | `/give SwiftBoots` | Visibly ~15% faster. Should feel snappier but not dramatic |
| 5 stacks | `/give SwiftBoots` × 5 | 1.75× base speed. Noticeably fast, still controllable |
| 10 stacks | `/give SwiftBoots` × 10 | 2.5× base speed. Very fast, should still be able to navigate normally |
| 20 stacks | `/give SwiftBoots` × 20 | 4.0× base speed. Extremely fast but no crash — capped at 100 studs/sec by StatLib |

### Pass Criteria
- Movement speed increases after each `/give`
- No errors in output window
- At 20 stacks the speed feels wild but the character does not clip through walls or error out
- **Fail:** Character stops moving / speed goes backwards / errors in console

---

## TEST 2 — WindWalker
**Item key:** `WindWalker`
**Type:** Passive stat (AirJumps +1 per stack, Additive)

### Setup
```
/nospawn
/give WindWalker
```

### What to test

| Stacks | Command | Expected Output |
|---|---|---|
| Baseline | *(no item, jump and try to double jump)* | Single jump only (no air jump) |
| 1 stack | `/give WindWalker` | 1 extra jump mid-air available |
| 3 stacks | `/give WindWalker` × 3 | Jump → jump → jump → jump (4 total: 1 ground + 3 air) |
| 10 stacks | `/give WindWalker` × 10 | 11 consecutive jumps. Should feel like infinite float |

### Pass Criteria
- Each stack grants exactly 1 more air jump
- Character does not get stuck floating or teleport on jump
- No error in console at 10+ stacks
- **Fail:** Jumping causes errors, jump count does not increase, or game freezes

---

## TEST 3 — SharpWhetstone
**Item key:** `SharpWhetstone`
**Type:** Passive stat (Damage +10% per stack, Multiplier)

### Setup
```
/nospawn
/enemy Minion
```
Attack the Minion and note the floating damage numbers.

### Expected Damage Numbers (Vanguard M1, 18 / 28 / 48 base)

| Stacks | Hit 1 | Hit 2 | Hit 3 |
|---|---|---|---|
| 0 (baseline) | **18** | **28** | **48** |
| 1 stack | **19.8** (~20) | **30.8** (~31) | **52.8** (~53) |
| 5 stacks | **27** | **42** | **72** |
| 10 stacks | **36** | **56** | **96** |

### What to test

| Stacks | Command | Expected Output |
|---|---|---|
| 1 | `/give SharpWhetstone` then M1 combo | See numbers above — ~10% increase |
| 5 | `/give SharpWhetstone` × 5 | ~50% more damage — finisher should hit for ~72 |
| 10 | `/give SharpWhetstone` × 10 | Exactly 2× base — finisher hits for ~96 |

### Pass Criteria
- Damage numbers increase predictably with each batch of stacks
- Crit hits (gold numbers) are approximately 2× the values above
- **Fail:** Damage stays the same, goes to 0, or damage numbers show negative values

---

## TEST 4 — Lens Maker's Glasses
**Item key:** `LensMakersGlasses`
**Type:** Passive stat (CritChance +10% per stack, Additive) — CAPPED at 100%

### Setup
```
/nospawn
/enemy Minion
```
Attack the Minion with M1 spam. Watch for gold "CRIT" damage numbers.

### Expected Crit Frequency

| Stacks | Crit Chance | What you see |
|---|---|---|
| 0 | 0% | No gold numbers ever |
| 1 | 10% | Roughly 1 in 10 hits is gold — rare |
| 5 | 50% | About half the hits are gold |
| 10 | 100% | **Every single hit is a gold crit number** |
| 11+ | 100% (capped) | Same as 10 stacks — cap is enforced by StatLib |

### What to test

| Stacks | Command | Expected Output |
|---|---|---|
| 1 | `/give LensMakersGlasses` — spam M1 × 20 | Occasional gold number |
| 5 | `/give LensMakersGlasses` × 5 | Gold roughly every other hit |
| 10 | `/give LensMakersGlasses` × 10 | 100% gold — every hit is a crit |
| 11 | `/give LensMakersGlasses` | Still 100% — no change, cap working ✅ |
| 15 | `/give LensMakersGlasses` × 5 more | Still 100% crits, no change |

### Pass Criteria
- At 10 stacks every hit is gold (100% crit)
- At 11+ stacks behavior is IDENTICAL to 10 stacks (cap enforced)
- **Fail:** CritChance goes above 100% and causes errors, or every hit is double the crit damage somehow (would indicate 2.0× applied twice)

---

## TEST 5 — Glass Cannon
**Item key:** `GlassCannon`
**Type:** Legendary / Unique (Damage ×3.0, MaxHealth ×0.1)

> ⚠️ **UNIQUE ITEM.** Only 1 stack should ever be grantable.

### Setup
```
/nospawn
/enemy Minion
```
Note your current HP bar before granting.

### Expected Values (Vanguard, 120 base HP)

| Stacks | Expected HP | Expected M1 Hit 1 Damage |
|---|---|---|
| 0 | 120 HP | 18 |
| 1 | **12 HP** (×0.1) | **54** (×3.0) |
| 2 (attempt) | Should be **blocked** by Unique check | No change from 1 stack |

### What to test

| Test | Command | Expected Output |
|---|---|---|
| First grant | `/give GlassCannon` | HP bar drops to ~10% (12 HP). Damage floats should be 3× |
| Second grant | `/give GlassCannon` | **Warning in output window:** "already holds Unique item GlassCannon — grant rejected." HP and damage unchanged |
| Verify Unique | `/give GlassCannon` a third time | Same rejection warning. Inventory stays at 1 stack |
| Damage check | M1 combo on Minion | Hit 1 ≈ 54, Hit 2 ≈ 84, Hit 3 ≈ 144 |

### Pass Criteria
- HP bar visually shrinks to ~10% of the bar after grant
- Floating damage numbers are ~3× higher than baseline
- A second `/give GlassCannon` prints a warn to output and grants nothing
- **FAIL (critical):** If two stacks are allowed, HP becomes negative and the character dies instantly or errors. This was the bug fixed in the QA pass.

---

## TEST 6 — Static Filament (Chain Lightning)
**Item key:** `StaticFilament`
**Type:** OnHit proc — 15% chance on hit to chain-zap up to 3 nearby enemies

> ℹ️ Proc fires at most once every 0.25s (cooldown gate). Chain count increases with stacks (not raw damage).

### Setup
```
/nospawn
/enemy Minion
/enemy Minion
/enemy Minion
/enemy Minion
```
Cluster 4 Minions together. Attack the closest one repeatedly.

### Expected Proc Damage (base proc damage = 10, no Damage items)

| Stacks | damageMult | Damage per zapped enemy | Chain targets |
|---|---|---|---|
| 1 | 0.33 | **~3.3** | up to 3 |
| 5 | 1.0 | **~10** | up to 7 |
| 10 | 1.33 | **~13.3** | up to 10 (capped) |
| 50 | ~1.82 | **~18.2** | up to 10 (capped) |

*Formula: `cap × (1 − 1/(1 + k×n))` where cap=2.0, k=0.2*

### What to test

| Test | Command | Expected Output |
|---|---|---|
| Proc fires | `/give StaticFilament` — M1 spam on 1 enemy | Occasionally a second enemy takes damage without being hit — chain proc fired |
| Proc cooldown | Very rapid M1 spam | Proc fires at most ~4× per second (0.25s gate) — does NOT proc on every single hit |
| Chain count check (1 stack) | Cluster 4 enemies, M1 spam | Up to 3 enemies zapped per proc (fourth is out of chain count) |
| Chain count check (5 stacks) | `/give StaticFilament` × 5 | Up to 7 enemies zapped per proc |
| No proc chain | — | Zapped enemies should NOT trigger their own proc (no infinite chain) |

### Pass Criteria
- Second enemy sometimes takes damage when you only hit the first
- Proc does not fire on every single hit (cooldown working)
- Zapped enemies do not trigger another round of chain lightning
- **Fail:** Lightning procs every single hit, or enemies are killed before you can observe the chain (proc spam without cooldown)

---

## TEST 7 — Volatile Casing (Explosion on kill)
**Item key:** `VolatileCasing`
**Type:** OnKill proc — 100% chance enemies explode on death

### Setup
```
/nospawn
/enemy Minion
/enemy Minion
/enemy Minion
```
Cluster enemies. Kill the first one.

### Expected Explosion Values (base proc damage = 10)

| Stacks | damageMult | Damage per enemy in blast | Blast radius |
|---|---|---|---|
| 1 | 1.15 | **~11.5** | **15 studs** |
| 5 | 3.0 | **~30** | **27 studs** |
| 9 | 3.65 | **~36.5** | **39 studs** |
| 10+ | ~3.75 | **~37.5** | **40 studs** (capped) |

*Radius formula: `min(15 + 3×(n−1), 40)` — hard cap at 40 studs*
*Damage formula: `cap × (1 − 1/(1 + k×n))` where cap=5.0, k=0.3*

### What to test

| Test | Command | Expected Output |
|---|---|---|
| Kill triggers explosion | `/give VolatileCasing` — kill a Minion | Dead enemy explodes, nearby enemies take ~11.5 damage |
| Radius growth (5 stacks) | `/give VolatileCasing` × 5 — kill a Minion | Explosion visually larger, damage ~30, radius ~27 studs |
| Radius cap (10+ stacks) | `/give VolatileCasing` × 10 — kill Minion | Radius does NOT exceed 40 studs. Damage ~37.5 |
| Chain kills OK | Kill Minion whose explosion kills another Minion | Second Minion explodes too (OnKill re-fires). Three-deep chains are possible but coolgate limits spam |
| No infinite loop | Kill in a large pack | Game continues normally — no freeze, no crash from explosion chains |

### Pass Criteria
- Visual explosion effect on enemy death
- Nearby enemies take damage (check their HP or watch for damage numbers)
- Radius feels larger at higher stacks but stops growing past 40 studs
- **Fail:** Game freezes due to infinite explosion chain. Explosion damage hits zero or goes negative. Radius fills the entire map.

---

## TEST 8 — Void Magnet (Crit pulls enemies)
**Item key:** `VoidMagnet`
**Type:** OnCrit proc — 100% on crit, pulls nearby enemies inward

> ⚠️ **STUB.** `triggerVacuum` is not yet implemented. Proc should fire (rolls chance, passes cooldown) but **does nothing visually or mechanically.** Test is just confirming it does not crash.

### Setup
```
/give LensMakersGlasses
/give LensMakersGlasses
/give LensMakersGlasses
/give VoidMagnet
/enemy Minion
```
Use 3 Glasses for reliable crits.

### What to test

| Test | Command | Expected Output |
|---|---|---|
| No crash on crit | M1 spam with above setup | Gold crit numbers appear. **No errors in console.** Enemies do not move or pull. |
| Console output | Check output window | No `attempt to index nil` or script errors |

### Pass Criteria
- Crits happen (gold numbers)
- No console errors when crit fires with VoidMagnet in inventory
- Enemies stay in place (pull is not implemented yet — expected)
- **Fail:** Error in output window on crit. Game crashes or enemy model breaks.

---

## TEST 9 — Afterimage Cloak (Dash leaves explosive decoy)
**Item key:** `AfterimageCloak`
**Type:** OnDash proc — 100% chance on dash, leaves a decoy

> ⚠️ **STUB.** `Decoy` proc handler does not have a spawn implementation yet. Test is just confirming no crash.

### Setup
```
/give AfterimageCloak
/enemy Minion
```
Play as Scrapper (has a dash).

### What to test

| Test | Command | Expected Output |
|---|---|---|
| Dash triggers proc | Dash key (Scrapper) | No errors. Decoy not spawned yet (stub). |
| Stack test | `/give AfterimageCloak` × 5 — dash | Multiple procs can fire, still no crash |

### Pass Criteria
- Dashing with AfterimageCloak in inventory produces no console errors
- **Fail:** Error on dash. Game freezes after dashing.

---

## TEST 10 — Jetstream Sandals (Double jump stuns enemies below)
**Item key:** `JetstreamSandals`
**Type:** OnJump proc — 100% on jump, ground slam AoE below

> ⚠️ **STUB.** `GroundSlam` handler not yet implemented. Test is confirming no crash.

### Setup
```
/give JetstreamSandals
/enemy Minion
```
Stand above a Minion and double jump.

### What to test

| Test | Command | Expected Output |
|---|---|---|
| Air jump triggers proc | Double jump | No errors. No ground slam yet (stub). |

### Pass Criteria
- No console errors on jump with item in inventory
- **Fail:** Error on jump. Character freezes.

---

## TEST 11 — Momentum Battery (OnHit speed buff)
**Item key:** `MomentumBattery`
**Type:** OnHit passive buff (tagged `OnHitBuff`) — no handler implemented yet

> ⚠️ **STUB.** Logic tag only. No buff applied yet.

### Setup
```
/give MomentumBattery
/enemy Minion
```

### What to test

| Test | Command | Expected Output |
|---|---|---|
| No crash on hit | M1 spam on Minion | No console errors. Speed is unchanged (stub). |

### Pass Criteria
- No errors. Combat works normally.
- **Fail:** Error on hit. Speed goes to zero or infinity.

---

## TEST 12 — Echo Blade (Ghost slash after M2)
**Item key:** `EchoBlade`
**Type:** Passive on Aerial Slash — fires a second ghostly cyan slash 0.25s after M2

### Expected EchoDamage Values
Formula: `MainDamage × clamp(0.3 + 0.1 × stacks, 0.4, 1.2)`

| Stacks | Multiplier | Echo scales as... |
|---|---|---|
| 1 | 0.40 (40%) | Echo deals 40% of main slash damage |
| 5 | 0.80 (80%) | Echo deals 80% of main slash damage |
| 9 | 1.20 (120%) | Echo at cap — deals 120% of main slash damage |
| 10+ | 1.20 (120%) | Capped — no change above 9 stacks |

### Setup (Vanguard only)
```
/nospawn
/enemy Minion
/give EchoBlade
```

### What to test

| Test | Command | Expected Output |
|---|---|---|
| Echo VFX fires | Press M2 (Aerial Slash) | Two crescent projectiles travel forward. The second (0.25s later) is **smaller (80% size)** and **cyan/icy white** instead of purple/violet |
| Echo hits enemy | M2 at a Minion | Two sets of damage numbers appear on the Minion — one from the main slash, one smaller set ~0.25s later |
| Damage check (1 stack) | Note main slash damage, then echo damage | Echo ≈ 40% of main |
| Damage check (5 stacks) | `/give EchoBlade` × 5 | Echo ≈ 80% of main |
| Cap at 9 stacks | `/give EchoBlade` × 9 | Echo ≈ 120% of main |
| Cap check (10 stacks) | `/give EchoBlade` (1 more) | Echo damage UNCHANGED from 9 stacks |
| No third slash | Watch carefully after M2 | **Exactly two** crescents appear. Never three. |
| echo-of-echo prevention | M2 spam | Echo never triggers its own echo — only one delayed crescent per cast |

### Pass Criteria
- Two distinct projectiles: 1 purple/violet, 1 cyan/smaller
- Second projectile fires ~0.25s after the first
- Damage on enemy shows two separate instances
- Stack count correctly scales echo damage up to cap
- Infinite loop test: no matter how many times M2 is pressed, only 2 projectiles per cast
- **Fail:** Three or more crescents appear. Echo deals 0 damage. Only one crescent. Console error after M2.

---

## TEST 13 — W1 Chest + Scrap Economy
**Type:** Economy / UI flow

### Setup
```
/scrap 50
/chest
```

### What to test

| Test | Command | Expected Output |
|---|---|---|
| Chest spawns | `/chest` | Golden glowing chest spawns in front of you, oriented toward you |
| Proximity prompt | Walk up to chest | "Open W1_Chest (25 Scrap)" prompt appears within ~15 studs |
| Insufficient scrap | Buy with 0 scrap | Red "Not enough Scrap! Need 25." feedback on screen. Chest stays open. |
| Valid purchase | `/scrap 25` then open | **Item selection screen** appears with 3 distinct item cards. Chest disappears after 0.5s. |
| Item granted | Click one card | Card selected, screen closes, `/give` equivalent runs for that item. Player has +1 of chosen item. |
| Only offered items | Open DevConsole → try to fire `SelectChestItem` manually with `"GlassCannon"` | Server should print warn: "tried to select unoffered item GlassCannon — rejected." Item NOT granted. |
| No double-open | Have 2 players open the same chest simultaneously | Only 1 player gets the item selection. Chest is gone for the other. |
| Scrap HUD | `/scrap 25` | Scrap counter in HUD increases by 25 |
| Scrap deducted | Buy a chest (25 cost) | Scrap HUD decreases by 25 |

### Pass Criteria
- Full buy flow works end-to-end: Scrap → Chest → Item cards → Grant
- Security check correctly rejects tampered item keys
- **Fail:** Chest can be opened multiple times. Item granted without spending scrap. Arbitrary item keys accepted.

---

## TEST 14 — Stacking Stress Test (All stat items × 50)
Run this after all individual tests pass. Tests the StatLib safety floor.

### Setup
```
/nospawn
```
Then paste this into chat one at a time:
```
/give SwiftBoots     (×10)
/give SharpWhetstone (×10)
/give LensMakersGlasses (×15)
/give WindWalker     (×15)
```

### What to test

| Test | Expected Output |
|---|---|
| No console errors | Output window should be silent (no script errors) |
| Speed is fast but bounded | Can still move and navigate. Does not exceed StatLib cap (100 studs/sec) |
| Crit is 100% (not higher) | Every M1 hit is gold. No "200% crit" weirdness |
| Damage is high but consistent | Numbers are large but not `inf` or `nan` |
| Air jumps work | Can jump many times. Character does not get stuck in the air |

### Pass Criteria
- Game continues running normally after extreme stacks
- No `inf`, `nan`, or negative values in damage numbers
- Character is controllable (very fast, but not clipping through world)
- **Fail:** Any console error. Damage number shows `inf`. Character falls through the map. Game lags significantly.

---

## TEST 15 — GlassCannon + SharpWhetstone Interaction
Tests that two multipliers stack correctly (not multiplicatively compounding wrongly).

### Setup
```
/give GlassCannon
/give SharpWhetstone
/give SharpWhetstone
/give SharpWhetstone
/enemy Minion
```

### Expected M1 Hit 1 damage
- Base: 18
- SharpWhetstone × 3: multiplierBonus = 1 + (0.1 × 3) = 1.3
- GlassCannon: multiplierBonus += 2.0 → total multiplierBonus = 1 + 0.3 + 2.0 = **3.3**
- Final: 18 × 3.3 = **59.4 (~59)**

### What to test

| Test | Expected Output |
|---|---|
| M1 Hit 1 | ~59 damage (not 18 × 1.3 × 3.0 = 70.2 — they are ADDITIVE not multiplicative) |
| HP bar | Should still be at ~10% of max (12 HP) from GlassCannon |

### Pass Criteria
- Hit 1 shows approximately **59** (not 70 — confirms additive stacking)
- HP bar is 12 HP (GlassCannon still applied correctly)
- **Fail:** Value is 70 (would indicate wrong multiplicative stacking). Character died on grant (negative HP from second GlassCannon — should be blocked by Unique check).

---

## Summary Checklist

| Item | Stat Works | Stacking Sane | No Crash at 10+ | Security OK |
|---|---|---|---|---|
| SwiftBoots | ☐ | ☐ | ☐ | N/A |
| WindWalker | ☐ | ☐ | ☐ | N/A |
| SharpWhetstone | ☐ | ☐ | ☐ | N/A |
| LensMakersGlasses | ☐ | ☐ (caps at 100%) | ☐ | N/A |
| GlassCannon | ☐ | ☐ (Unique blocked) | ☐ | N/A |
| StaticFilament | ☐ | ☐ (chain count grows) | ☐ | N/A |
| VolatileCasing | ☐ | ☐ (radius capped at 40) | ☐ | N/A |
| VoidMagnet | ☐ (stub) | N/A | ☐ | N/A |
| AfterimageCloak | ☐ (stub) | N/A | ☐ | N/A |
| JetstreamSandals | ☐ (stub) | N/A | ☐ | N/A |
| MomentumBattery | ☐ (stub) | N/A | ☐ | N/A |
| EchoBlade | ☐ | ☐ (caps at 9 stacks) | ☐ | N/A |
| W1 Chest / Scrap | ☐ | N/A | N/A | ☐ |
| HiveMind | ☐ (stub) | N/A | ☐ | N/A |
| AuraOfTheTyrant | ☐ (stub) | N/A | ☐ | N/A |
