# ANIMATION_REQUIREMENTS_TODO.md
## Vertical Movement Animations — Enemy Jump / Fall / Land

This document specifies every animation that must be created in Roblox Studio
for the vertical-movement system added by `JumpController.luau` and the
`Jumping / Falling / Landing` states in `BaseEnemy.luau`.

---

## How the Blend Tree Works (Important Context)

Roblox's `Animator` blends tracks by **priority tier**. The three tiers used in
this game, from lowest to highest override:

| Tier | `Enum.AnimationPriority` | Used for |
|---|---|---|
| 1 (lowest) | `Idle` | Idle pose (not used yet) |
| 2 | `Movement` | Walk, run tracks |
| 3 (highest) | `Action` | All attack, jump, land tracks |

**All new vertical-movement animations MUST use `Action` priority.**
This guarantees Jump/Fall/Land always overrides the Walk track, even if the
walk track is still technically "playing" when the jump is triggered
(it is stopped via `:Stop(0.05)` in `_setupAnimator`, but a tiny blend window
may overlap).

### Looped vs Non-Looped

| Animation | `Looped` | Reason |
|---|---|---|
| **JumpAnim** | `false` | One-shot takeoff arc. Plays from frame 0 to end once. |
| **FallAnim** | `true` | Held indefinitely while descending. Must loop seamlessly. |
| **LandAnim** | `false` | One-shot impact stumble. Plays from frame 0 to end once. |

---

## Config Field Names

Add these three keys to the enemy's config block in `src/shared/Config/EnemyConfig.luau`
and set `CanJump = true`:

```lua
CanJump          = true,
JumpAnimationId  = "rbxassetid://YOUR_JUMP_ANIM_ID",
FallAnimationId  = "rbxassetid://YOUR_FALL_ANIM_ID",
LandAnimationId  = "rbxassetid://YOUR_LAND_ANIM_ID",
LandRecoveryTime = 0,   -- seconds enemy stays in Landing state (0 = instant return to Chase)
```

---

## Per-Enemy Requirements

---

### 1. Minion (Fodder Swarm)

> **CanJump: YES** — Minions form hordes and WILL reach ledges constantly.
> Fast, disposable animations. No weight or drama.

| Anim | ID Field | Looped | Priority | Duration | Description |
|---|---|---|---|---|---|
| Jump | `JumpAnimationId` | `false` | `Action` | ~0.35s | Quick spring-up. Arms swing back, legs tuck slightly. Light, agile. No anticipation pose needed — speed matters more than readability. |
| Fall | `FallAnimationId` | `true` | `Action` | seamless loop | Arms slightly outstretched, body angled slightly forward. Neutral descent pose. Loop point at peak of the loop cycle (no jarring pop). |
| Land | `LandAnimationId` | `false` | `Action` | ~0.2s | Light crouch-absorb. Knees bend, body dips. Fast recovery. |

```lua
LandRecoveryTime = 0,  -- instant; Minions re-aggro immediately on landing
```

---

### 2. Brute (Heavy Melee)

> **CanJump: YES** — Brute is the most impactful jumper. His land should feel like
> a miniature LeapSlam. Needs anticipation and a pronounced recovery pose.

| Anim | ID Field | Looped | Priority | Duration | Description |
|---|---|---|---|---|---|
| Jump | `JumpAnimationId` | `false` | `Action` | ~0.5s | Heavy crouch wind-up (0.15s), then explosive launch. Arms reach forward. Body leans into the jump direction. |
| Fall | `FallAnimationId` | `true` | `Action` | seamless loop | Arms wide and slightly behind, body hunched slightly forward. Conveys mass and speed. Loop point at neutral falling position. |
| Land | `LandAnimationId` | `false` | `Action` | ~0.55s | Hard two-fist slam into ground or heavy knee-drop. Body crumples on impact. Head rocks forward. This is the longest recovery — the camera shake and dust VFX fire on the first frame of this animation. |

```lua
LandRecoveryTime = 0.4,  -- 400ms recovery; Brute is stunned briefly after landing
```

> **Animator Note:** The Land animation should have the peak impact pose at
> frame ~3 (≈0.1s in). The shake VFX fires at state entry, not on a frame event,
> so the visual dust cloud and the animation peak should be roughly simultaneous.
> Adjust `LandRecoveryTime` to match your animation's full-recovery frame count.

---

### 3. MossFrog (Nimble Mid-Tier)

> **CanJump: YES** — Frogs jump. These animations should feel distinctly
> frog-like: a squat prep, a wide-body leap arc, and a splayed landing.

| Anim | ID Field | Looped | Priority | Duration | Description |
|---|---|---|---|---|---|
| Jump | `JumpAnimationId` | `false` | `Action` | ~0.4s | Strong hindleg crouch into a wide spread-arm leap. FacingOffset = -90° so make sure the VISUAL forward direction matches the animation's launch direction. |
| Fall | `FallAnimationId` | `true` | `Action` | seamless loop | Limbs splayed outward (classic frog glide). Loops at the neutral glide position. |
| Land | `LandAnimationId` | `false` | `Action` | ~0.25s | All four limbs absorb impact simultaneously. Quick crouch-and-rise. |

```lua
LandRecoveryTime = 0.1,  -- brief; frog is agile and recovers quickly
```

> **FacingOffset Reminder:** MossFrog has `FacingOffset = -90` in EnemyConfig,
> meaning its mesh's visual forward is 90° clockwise from the root CFrame forward.
> All animations must be authored to the MESH forward, not the root forward.
> The `FaceToward()` function in BaseEnemy already compensates for this offset
> when setting AlignOrientation.

---

### 4. Shooter (Ranged Harasser)

> **CanJump: OPTIONAL** — Shooter's AI (OnChaseOverride) manages its own
> retreat logic. Add jump support only if your map has cliffs the Shooter
> needs to retreat onto. Set `CanJump = false` initially.

| Anim | ID Field | Looped | Priority | Duration | Description |
|---|---|---|---|---|---|
| Jump | `JumpAnimationId` | `false` | `Action` | ~0.35s | Light spring. Arms brace weapon against body during launch. |
| Fall | `FallAnimationId` | `true` | `Action` | seamless loop | Body slightly hunched, weapon held out for balance. |
| Land | `LandAnimationId` | `false` | `Action` | ~0.2s | Roll-absorb or crouch. Quick recovery. |

```lua
CanJump          = false,  -- Set to true when map demands it
LandRecoveryTime = 0,
```

---

### 5. Keg (Rolling Bomber)

> **CanJump: NO** — Keg rolls to its target. Adding standard jump breaks the
> rolling animation system. If Keg needs to cross gaps, handle it with a
> specialised Keg-specific gap-bridge mechanic (out of scope for this system).

```lua
CanJump = false,  -- NEVER change this; Keg's _kegOrientationOffset + rolling
                  -- CFrame system is incompatible with AssemblyLinearVelocity jumps.
```

No animations needed. Skip entirely.

---

## Animation Authoring Checklist

Use this checklist for each animation before uploading to Roblox:

- [ ] **Root Motion OFF** — All animations must be root-motion-free. BaseEnemy
      movement is driven by `LinearVelocity` + `AssemblyLinearVelocity`, not
      root motion. Root motion would fight the physics constraints and cause
      position desync.
- [ ] **Rig matches AnimationController** — Enemy rigs use `AnimationController`
      (no Humanoid). Ensure you're animating the correct rig type in Moon Animator
      or the Roblox Animation Editor.
- [ ] **Fall loop is seamless** — Import the FallAnim, play it looped, and verify
      there is no visible pop at the loop boundary. A 2-3 frame ease at the loop
      point resolves most pops.
- [ ] **Priority NOT set in the Asset** — Do NOT set Priority inside the Animation
      asset itself. `_setupAnimator` in BaseEnemy sets Priority programmatically
      via `track.Priority = Enum.AnimationPriority.Action`. Setting it in the asset
      too can cause doubles.
- [ ] **Upload as R15 or Custom** — Use the same rig type your enemy model uses.
      Roblox won't allow loading an R15 animation onto a custom rig.
- [ ] **Test the LandAnim timing** — Place a Brute test dummy and print
      `tick()` at state entry and `LandRecoveryTime` expiry. Confirm the
      LandAnim has not finished before the recovery timer expires (or
      increase the timer to match the animation length).

---

## Animation State Machine Diagram

```
                    ┌─────────────────────────────┐
                    │          Idle / Chase        │
                    │      (Walk Track playing)    │
                    └──────────────┬──────────────┘
                                   │ CheckLedge() or CheckGap()
                                   ▼
                    ┌──────────────────────────────┐
                    │     JUMPING                  │
                    │  JumpAnim (Action, not looped)│
                    │  PlaneVelocity locked to      │
                    │  _jumpTrajectory             │
                    └──────────────┬───────────────┘
                                   │ Y velocity < -1 (past apex)
                                   ▼
                    ┌──────────────────────────────┐
                    │     FALLING                  │
                    │  FallAnim (Action, looped)    │
                    │  PlaneVelocity still locked  │
                    │  Separation SKIPPED           │
                    └──────────────┬───────────────┘
                                   │ IsGrounded() == true
                                   ▼
                    ┌──────────────────────────────┐
                    │     LANDING                  │
                    │  LandAnim (Action, not looped)│
                    │  PlaneVelocity = zero        │
                    │  Duration = LandRecoveryTime  │
                    └──────────────┬───────────────┘
                                   │ LandRecoveryTime expired
                                   ▼
                    ┌─────────────────────────────┐
                    │          Chase               │
                    │      (Walk Track resumes)    │
                    └─────────────────────────────┘
```

> **Gap Leap shortcut:** `DoGapLeap()` goes directly to **FALLING** (skips
> JUMPING entirely), because there is no upward arc — the enemy runs off the
> edge and falls.

---

## Summary Table

| Enemy | Jump | Fall | Land | `LandRecoveryTime` | `CanJump` |
|---|---|---|---|---|---|
| **Minion** | ✅ Required | ✅ Required | ✅ Required | `0` | `true` |
| **Brute** | ✅ Required | ✅ Required | ✅ Required | `0.4` | `true` |
| **MossFrog** | ✅ Required | ✅ Required | ✅ Required | `0.1` | `true` |
| **Shooter** | ⚠️ Optional | ⚠️ Optional | ⚠️ Optional | `0` | `false` (default) |
| **Keg** | ❌ Never | ❌ Never | ❌ Never | N/A | `false` (hardcoded) |

**Total minimum animations to create: 9** (3 enemies × 3 clips each)
