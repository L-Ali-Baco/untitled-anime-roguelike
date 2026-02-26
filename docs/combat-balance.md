# Combat Balance Analysis
**Date:** 2026-02-26
**Branch:** feature/w1-chest-and-lighting

---

## 1. Player Stats (ClassConfig)

| Class       | HP  | DPS (approx) | Speed Mult | Notes                              |
|-------------|-----|-------------|------------|-------------------------------------|
| Vanguard    | 120 | ~49.5       | ×1.15      | 3-hit combo: 18+28+48=94 dmg, ~1.9s cycle |
| Scrapper    | 80  | ~66.7       | ×1.6       | 8 dmg/shot, 0.12s fire rate        |
| Biker King  | 100 | ~37.5       | ×1.0       | 3 dmg/tick, 0.08s tick             |

---

## 2. Enemy Stats (EnemyConfig)

| Enemy    | HP  | Dmg | Cooldown | DPS   | Speed | Notes                    |
|----------|-----|-----|----------|-------|-------|--------------------------|
| Minion   | 30  | 5   | 1.5s     | 3.33  | 14    | Fodder, 10% drop         |
| Brute    | 100 | 15  | 2.0s     | 7.5   | 6     | 3 attacks (Slam/Swing/LeapSlam) |
| MossFrog | 50  | 10  | 3.0s     | 3.33  | 16    | BogCharge gap-closer     |
| Shooter  | 20  | 8   | 2.0s     | 4.0   | 12    | Ranged, retreats         |

---

## 3. Time-to-Kill (TTK) Matrix

### Time to kill a player (seconds) at various enemy group compositions

**Vanguard (120 HP):**

| Composition         | Total DPS | TTK   |
|---------------------|-----------|-------|
| 1 Minion            | 3.33      | 36.0s |
| 3 Minions           | 10.0      | 12.0s |
| 5 Minions           | 16.7      | 7.2s  |
| 10 Minions          | 33.3      | **3.6s** ⚠️ |
| 1 Brute + 3 Minions | 17.5      | 6.9s  |
| 2 Brutes            | 15.0      | 8.0s  |
| 1 Brute + 1 MossFrog| 10.8      | 11.1s |

**Scrapper (80 HP):**

| Composition         | Total DPS | TTK   |
|---------------------|-----------|-------|
| 1 Minion            | 3.33      | 24.0s |
| 5 Minions           | 16.7      | **4.8s** ⚠️ |
| 1 Brute + 2 Minions | 14.2      | 5.6s  |

**Key threshold:** 5+ Minions attacking simultaneously drops TTK below 5s for all classes.
Scrapper (80HP, no armor) is especially fragile in swarms.

---

## 4. Overwhelm Analysis

### Root Causes of "Feel Bad" Moments

**Problem 1: Linear DPS Stacking**
All enemies attack whenever they are individually ready (`LastAttackTime + Cooldown`).
With 10 Minions swarmed on a player, all 10 fire at cooldown reset → 33 DPS burst.
No system limits simultaneous attackers. One spawn wave = guaranteed near-instant death.

**Problem 2: Spawn Distance = Immediate Aggro**
Old `MinSpawnDistance = 80`, `AggroRange = 70`. Gap: only 10 studs.
Enemy spawns → is already within aggro range → immediately chases.
Player has zero reaction window between "enemy appears" and "enemy is attacking."

**Problem 3: No Spawn Direction Awareness**
Enemies can spawn directly in the player's forward FOV, making them visible the moment they pop in.
This breaks immersion and makes spawning feel cheap ("enemy appeared out of thin air in my face").

---

## 5. AI Combat Director — Proposed Changes

### 5.1 Attack Token System

**Concept:** Only a fixed number of enemies can be in an active attack state per player at a time.
No explicit checkout/return — count live from state snapshot each tick.

```
canAttack(player) → boolean
  count = # enemies where (Target == player AND State ∈ {Attack, LeapAttack, ChargeAttack})
  return count < AttackTokens.Normal  -- default 2
```

**New config block in EnemyConfig:**
```lua
AttackTokens = {
    Normal   = 2,  -- Max simultaneous attackers per player in a standard fight
    Elite    = 3,  -- Room with elite enemies (room for more pressure)
    BossRoom = 1,  -- Boss fights: only 1 add attacks at a time
}
```

**Enemy behavior when token denied:**
- Enter a brief circling orbit (`_doCircle`) instead of waiting in place
- Re-check token every 0.5s; enter Attack as soon as a slot opens
- This keeps non-attacking enemies visually active (threatening) instead of frozen

### 5.2 Spawn Activation Delay

**Concept:** New enemies stand still for 1.5s after spawning before AI activates.
This gives the player a small window to react/reposition and prevents instant-aggro pop-in.

**Implementation:** `_activationEndTime = tick() + ActivationDelay`
Added to BaseEnemy constructor, checked at top of Tick().

```lua
ActivationDelay = 1.5  -- seconds frozen after spawn
```

### 5.3 Spawn Distance Tuning

| Parameter           | Old  | New  | Reason                                   |
|---------------------|------|------|------------------------------------------|
| MinSpawnDistance    | 80   | 100  | 30-stud buffer before aggro range (70)   |
| MaxSpawnDistance    | 120  | 140  | Maintain ~40-stud spawn band width       |

At 100 studs: enemy spawns → walks ~30 studs before entering aggro range (70) → player has ~2s at walk speed (14) to react.

### 5.4 FOV Exclusion Zone

**Concept:** Skip spawn points within ±50° of any player's look direction.
Prevents enemies from popping into view directly in front of the camera.

```lua
FOVExclusionAngle = 50  -- degrees either side of look direction
```

Enemies still spawn in the player's general area — just never directly in front.
Flanking and rear spawns feel earned; frontal spawns feel fair when they do occur.

---

## 6. Expected Feel After Changes

| Scenario                       | Before             | After                           |
|--------------------------------|--------------------|----------------------------------|
| 10 Minions swarm               | 3.6s TTK (instant) | 2 attacking at a time → 6.7s TTK |
| Enemy pops into FOV            | Immediate fight    | Behind player or side → fair     |
| First second after enemy spawn | Instant aggro      | 1.5s freeze → reaction window    |
| 5 enemies, only 2 attacking    | 16.7 DPS burst     | 6.7 DPS sustained (feels skilled) |

**Target TTK range:** 8–15s in a standard 5-enemy encounter.
With 2 tokens + Vanguard 120HP: 2 Minions attacking = 6.7 DPS → 18s solo, fair for solo play.

---

## 7. Circling Behavior Design

Non-attacking enemies that are token-denied should circle the player at their `StopDistanceFromTarget + 3` radius.

- Circle direction: alternating per enemy (`_circleSign = 1 or -1`) to avoid all going the same way
- Speed: 70% of normal WalkSpeed (stalking pace)
- Exit: as soon as `canAttack()` returns true → immediately enter Attack state

This creates the "pack mentality" feel: enemies surround and pressure the player visually even when they aren't swinging, rewarding the player for breaking the ring.
