# Untitled Anime Roguelike (Working Title)

**Concept:** A 3rd-person, multiplayer Roguelike on Roblox.
**Vibe:** "Risk of Rain" meets "Black Desert Online." High-speed combat, high-fidelity Anime VFX, and god-tier power scaling.
**Core Loop:** Scavenge floating islands consumed by a magical Super-Storm -> Charge beacons -> Fight massive bosses -> Get overpowered.

---

## 1. Core Mechanics

### The Storm (Director System)
A "Director" mechanic that scales difficulty over time. The longer the run, the darker the sky, the stronger the enemies.

- **Time-Based Scaling:** Difficulty increases the longer the run takes
- **Visual Indicators:** Sky darkens, storm effects intensify as difficulty rises
- **Director Events:** Random events to keep players on their toes
  - Elite enemy spawns
  - Mini-boss encounters
  - Weather effects (lightning strikes, wind gusts affecting movement)
  - Horde waves
  - Treasure goblins / loot events

### Hand-Crafted Maps with Random Encounters
Instead of full procedural generation (which can be messy), the game uses high-quality "Set Maps" designed for flow and verticality. Replayability comes from:
- **Dynamic Spawns:** Enemies spawn in different locations and compositions via the Director.
- **Randomized Loot:** Chests and shrines spawn in different potential locations each run.
- **Map Rotation:** The game picks a random map from the pool for each stage.

### Item Synergies
Items stack visually on the character model.
- *Example:* Fire Bullets + Bouncing Bullets = Screen full of bouncing fireballs.

### Multiplayer Focus
- **Party Size:** 4 players max
- Item sharing/pinging system
- "Ghost" mechanics (dead players can buff the living)

---

## 2. Combat Design ("The BDO Feel")
The goal is **"Carnage"**: Exaggerated movement, weight, and flow.

### Damage Numbers
Floating damage text that appears on enemy hits for satisfying visual feedback.

- **Animation Style:** Classic float-up and fade-out
- **Color Coding by Damage Type:**
  | Type | Color | When |
  |------|-------|------|
  | Normal | White | Standard hits |
  | Critical | Gold/Yellow | Random crits or weak point hits |
  | Finisher | Orange | 3rd hit in combo chain |
  | Bleed | Dark Red | Bleed DoT ticks |
  | Fire | Orange-Red | Burn damage |
  | Poison | Green | Poison DoT ticks |
- **Scaling:** Larger font for bigger damage numbers
- **Stacking Prevention:** Slight random X offset so numbers don't overlap

### Melee ("The Vanguard")
- **M1 Combo:** 3-hit string. 3rd hit has **0.1s Hitstop** (freeze frame) + Radial Blur for impact.
- **Hitstop:** Crucial for the "heavy" feel. The game freezes briefly when a hit lands to simulate cutting through mass.
- **Vaulting:** "Magnetic Leap." Hitting Jump mid-combo near an enemy automatically vaults off them (illusion of interaction without complex physics).
- **Carnage Factor:** High enemy density. One swing sends 10+ "Minion" enemies ragdolling.

### Ranged ("The Gunslinger")
- **Physical Projectiles:** Bullets don't just disappear; they explode or pierce.
- **Recoil:** Firing big shots pushes the character back physically.
- **Mobile Aiming:** "Paint" targets by dragging a finger, release to fire homing missiles.

---

## 3. Characters & Classes

### Prototype Focus
Initial development focuses on one character to nail the core feel before expanding.

### Planned Archetypes
- **Vanguard** - Melee brawler, high enemy density cleave
- **Gunslinger** - Ranged DPS, mobility through recoil mechanics
- *More TBD after prototype*

### Character Progression
- **Alternate Abilities:** Unlock different ability loadouts per character
- **Skill Trees:** Character-specific upgrades that persist between runs

---

## 4. Progression Systems

### Meta-Progression (Between Runs)
Inspired by Binding of Isaac's unlock system.

#### Character Unlocks
- **Achievement-Based:** Complete specific challenges to unlock new characters
  - *Example:* "Beat Stage 3 without taking damage" unlocks a new character
- **Premium Path:** Instant unlock with Robux (optional)

#### Item Unlocks
- Items are locked behind achievements
- Completing achievements adds items to the **loot pool** for future runs
- Creates long-term goals and "just one more run" motivation

#### Permanent Upgrades
- Spend currency earned from runs on permanent stat boosts
- Unlock new starting loadout options
- Upgrade character abilities

### In-Run Progression
- Collect items from chests, enemies, and beacons
- Stack items for synergies
- Power scaling gets absurd by late game (the fun part)

### Mobility Upgrades (Roguelike Items)
Movement-enhancing items that can be found during runs:

#### Air Jump Items
| Item | Effect | Rarity |
|------|--------|--------|
| **Wind Walker** | +1 Air Jump | Common |
| **Skybound Feather** | +2 Air Jumps, -5% ground speed | Rare |
| **Cloud Dancer** | +1 Air Jump, air jumps cost no stamina | Epic |
| **Featherfall Charm** | Reduced fall speed while holding jump | Common |
| **Momentum Keeper** | Air jumps preserve horizontal velocity | Rare |

#### Dash Items
| Item | Effect | Rarity |
|------|--------|--------|
| **Phantom Step** | +1 Dash charge (can dash twice) | Common |
| **Afterimage Cloak** | Afterimages deal 10% damage to enemies | Rare |
| **Blink Shard** | Dash distance +50%, cooldown +25% | Rare |
| **I-Frame Extender** | Invincibility duration +0.1s | Epic |

#### General Mobility
| Item | Effect | Rarity |
|------|--------|--------|
| **Swift Boots** | +15% movement speed | Common |
| **Air Control Matrix** | +50% air control (strafe while airborne) | Rare |
| **Magnetic Soles** | Can wall-jump once per airtime | Epic |
| **Gravity Defier** | -20% gravity (higher jumps, floatier) | Legendary |

---

## 5. World & Stages

### Structure
- Multiple distinct worlds/biomes
- Each world has unique:
  - Enemy types
  - Environmental hazards
  - Visual themes
  - Boss encounter

### Floating Islands Theme
- Islands consumed by the magical Super-Storm
- Verticality in level design (air combos, platforming)
- StreamingEnabled chunks for performance

---

## 6. Bosses
*TBD - To be designed after core combat prototype*

Potential directions:
- Giant creatures (kaiju-style)
- Humanoid anime villains with phases
- Environmental/puzzle bosses
- Storm manifestations

---

## 7. Mobile-First Optimization (Critical)
70% of players are on mobile. The game must feel "Pro" but play "Easy."

### Camera
- **Smart-Snap:** Camera automatically pitches up when doing air combos so mobile players don't lose the enemy.
- **Soft-Lock:** Attacks slightly "bend" toward enemies (Auto-Assist).

### Controls
- **Context Button:** One big button that changes function (Open Chest / Activate Teleporter) based on location.
- **Auto-Combo:** Holding the attack button cycles the full combo to save thumb fatigue.

### Performance
- **Client-Side VFX:** The server calculates damage; the phone calculates the pretty explosions.
- **Billboards:** Use 2D sprites for particles (anime style) instead of heavy 3D meshes.
- **StreamingEnabled:** Only load the chunks of the map the player is standing on.

---

## 8. Monetization (Fair & Ethical)
Avoid "Pay-to-Win" vibes to keep the F2P crowd happy.

- **Dual Currency:** Scrap (Free) vs. Flux (Premium).
- **Character Unlocks:**
  - *Free Path:* Hard challenges (e.g., "Beat Stage 3 without taking damage").
  - *Paid Path:* Buy the character instantly with Robux.
- **"Party Starter" Items:** Buy a "Loot Boost" for the *whole server*. Makes the buyer a hero.
- **Cosmetics:** Kill effects, victory poses, weapon skins.

---

## 9. Development Roadmap

### Phase 1: The Feel (Complete)
- [x] Prototype the "Vanguard" character
- [x] Nail the **Hitstop** and **Screen Shake**
- [x] Basic enemy AI (minion type)
- [x] Test on iPad

### Phase 2: The Dash (Complete)
- [x] Implement dash with I-Frames
- [x] After-image effect on dash
- [x] Dash "clips" through enemies

### Phase 3: The UI (Complete)
- [x] Big, chunky mobile buttons
- [x] Ensure buttons don't cover center screen
- [x] Context-sensitive action button

### Phase 4: Core Loop (In Progress)
- [x] Beacon charging mechanic
- [x] Storm/Director timer system (Difficulty scaling & Events)
- [x] Item System (Registry, Stats, Procs)
- [x] Skill System (Cooldowns, VFX, 2 Classes)
- [ ] Basic room generation / Map layout

### Phase 5: Multiplayer
- [ ] 4-player networking
- [ ] Item pinging
- [ ] Ghost mechanic for dead players

### Phase 6: Content Expansion
- [ ] More Characters (Mage, Assassin)
- [ ] More Items (Target: 30+)
- [ ] Boss Encounters
- [ ] Biomes / Maps

---

## 13. Next Steps / Tomorrow's Agenda
**Focus:** Asset Integration & Visual Polish.

### Assets Integration
Now that the systems are robust, we need to replace placeholders with real art.
- [ ] **Characters:** Replace dummy avatars with Vanguard/Gunner models.
- [ ] **Enemies:** Replace colored blocks with Minion/Brute/Shooter models.
- [ ] **Environment:** Build the "Training Arena" map chunks.

### Polish Tasks
- [ ] **Audio:** Add SFX for Skill usage, Cooldown ready, Item pickup.
- [ ] **VFX:** Improve particle quality for Overclock and Seismic Slam.
- [ ] **Animation:** Rig and import custom attack animations.

### Map Construction
- [ ] Assemble `ReplicatedStorage.Maps` models with proper `EnemySpawn` and `ChestLocation` tags.


### Future Phases
- [ ] Meta-progression system
- [ ] Monetization implementation

---

## 10. Technical Notes

### Architecture Decisions
- **Client-Side VFX:** Server handles damage/game logic, client handles visual effects
- **Hitbox System:** Server-authoritative for anti-cheat
- **State Management:** Consider using Promises for async operations

### Libraries in Use
- **Roact/Fusion** - UI framework
- **Promise** - Async handling
- **Signal** - Event system

---

## 11. Art & Audio Direction
**Note:** The developer is creating all custom assets and sounds personally. The visual style is iterative and not yet finalized.

### Visual Style (Target)
- High-fidelity Anime VFX (particles, trails, impact frames).
- Stylized 3D models (low-poly but high-style).
- Clear visual hierarchy (gameplay elements pop against background).

### Audio
- Crunchy, impactful SFX for combat (using "Hitstop" sync).
- Adaptive music that intensifies with the "Director" difficulty.

---

## 12. Reference Games
- **Risk of Rain 2** - Roguelike loop, item stacking, difficulty scaling
- **Black Desert Online** - Combat feel, weight, hitstop
- **Binding of Isaac** - Achievement-based unlocks, item pool expansion
- **Hades** - Meta-progression, character upgrades between runs
