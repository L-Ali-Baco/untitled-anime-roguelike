# Development Changelog

## v0.4.0 - "The Loot Loop" (Current)

_Focus: Item Systems, Progression, and Game Loop._

### 🛠️ Core Systems

- **Item Registry:** Refactored the item system into a centralized `ItemRegistry` (Single Source of Truth).
- **Stat System:** Fully integrated `StatLib` across all controllers. Items now correctly modify:
  - **Damage:** `CombatService` & `DamageNumbers` (Client prediction).
  - **Attack Speed:** `CombatController` (Cooldown reduction) & `CombatService` (Validation).
  - **Movement:** `MovementController` (WalkSpeed) & `DashController` (Distance/Speed).
  - **Stamina:** `StaminaController` (Regen Rate).
  - **Jumping:** `JumpController` (Air Jump count).
- **Proc System:** Implemented `ProcService` handling On-Hit, On-Kill, and On-Crit effects.
  - **Static Filament:** Chain lightning on hit.
  - **Volatile Casing:** Explosions on kill.
  - **Void Magnet:** Pull enemies on crit.

### ⚔️ Combat & Movement Polish

- **Dash Overhaul:**
  - Velocity is now a multiplier of current speed (4x) instead of a fixed value.
  - Added "Depreciation" (Drag) so dash feels like a burst that slows down naturally.
  - Increased I-Frames to **0.25s** (more forgiving).
  - Increased Stamina Cost to **40** (strategic use).
  - Added Momentum Preservation (`SyncVelocity`) so dashing/jumping doesn't snap speed to 0.
- **Shield Logic:** Fixed `EnemyService` to respect player Shield attribute (Iron Will). Enemies now deplete Shield before Health.
- **Acceleration Scaling:** Movement acceleration now scales with Speed stats (prevents "sliding on ice" feel at high speeds).
- **VFX Fixes:** Fixed `EnemyVFXController` errors and ensured Hitstun works reliably.

### 🎮 Content

- **New Items:** Added 12+ items across 4 tiers (Proc, Movement, Game Changer, Standard).
- **Brute Enemy Overhaul:**
  - Added **LeapSlam Attack**: Brute now performs a massive gap-closing leap when player is far away (30-60 studs).
  - **Smart AI**: Brute intelligently switches between walking and leaping based on distance.
  - **VFX Overhaul**: New dust, ground cracks, and slam shockwaves for the Brute.
- **Debug Commands:** Added `/give [item]`, `/diff [level]`, `/elite`, `/horde`, `/time`.

---

## v0.3.0 - "The Director"

_Focus: Difficulty Scaling and Dynamic Events._

### 🌪️ Director System

- **Difficulty Scaling:** Game gets harder over time (Enemy HP/Damage/Speed multipliers).
- **Visuals:** Sky darkens, fog increases, and atmosphere shifts as difficulty rises.
- **UI:** Added `DifficultyIndicator` (Top Right) showing Tier (Drizzle, Monsoon, etc.) and Timer.
- **Events:**
  - **Elite Spawns:** Larger, stronger enemies appear periodically.
  - **Horde Waves:** Sudden bursts of 10+ enemies.

### 🤖 AI Improvements

- **Aggro Ranges:** Significantly increased detection range (Enemies don't ignore you anymore).
- **Spawn Logic:** Enemies spawn closer to the action.

---

## v0.2.0 - "Game Feel"

_Focus: Combat Feedback and Responsiveness._

- **Hitstop:** Time freezes briefly on impact for crunchiness.
- **Screen Shake:** Dynamic camera shake on hits.
- **Damage Numbers:** Floating text for damage (White = Normal, Red = Crit/Finisher).
- **Networking:** Server-side hit validation with client-side prediction for instant feedback.

---

## v0.1.0 - "Prototype"

_Focus: Core Mechanics._

- **Classes:** Warrior (Melee Combo) and Gunner (Ranged Auto-aim).
- **Movement:** Double Jump, Dash, Sprint.
- **Enemies:** Basic Minion AI (Chase/Attack).
