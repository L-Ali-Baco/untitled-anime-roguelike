# Keg VFX Design Document

## Objective

Implement stylized visual effects for the Keg enemy, covering both its active rolling state (aura) and its detonation explosion, matching the "Void Eruption" particle-heavy art direction.

## Context

- The Keg is a suicide-bomber enemy that rolls towards the player and detonates after an arming period.
- Its movement and rotation are procedurally driven on the Server in `Keg.luau`.
- The current explosion is a generic server-side neon sphere and Roblox `Explosion` instance.

## Approach: Particle-Heavy "Void Eruption"

We will separate the VFX into two components: the aura attached to the Keg while alive, and the client-side explosion when it dies.

### 1. Aura (Rolling & Arming Visuals)

Attached directly to the `KegMesh` on the Server so it replicates smoothly to all clients syncing with the physical model.

- **Setup:** An `Attachment` placed at the center of the `KegMesh`.
- **Glow:**
  - A `Highlight` (deep purple fill/outline) to simulate stylized cracks/energy.
  - A `PointLight` (purple) to illuminate the surrounding environment.
- **Particles:** A `ParticleEmitter` emitting dark purple trailing smoke and sharp, stylized magenta "sparks" or "cracks" as it rolls.
- **Arming State:** When `Keg:_beginArming()` is called, we tween the `Highlight` and `PointLight` to pulse more intensely and increase the particle emission rate, signaling the impending explosion.

### 2. Detonation Explosion

Moved entirely to the Client for high-fidelity, stylized rendering without server lag. Triggered via the `EnemyAttack` remote (attack type: `"Explosion"`).

- **VFX Module:** Create `src/client/VFX/ExplosionVFX.luau`.
- **Core Burst:** A rapid burst of dark purple/black spherical particles expanding outward and fading quickly to serve as the explosion's volume.
- **Energy Spikes:** A secondary `ParticleEmitter` shooting out 5-8 bright magenta stylized "lightning" or "shard" textures radially.
- **Debris:**
  - Spawn 5-10 small, low-poly wood shards (or brown wedge parts).
  - Fling them outward in parabolic arcs using client-side physics or scripts, having them scatter on the ground and fade out.
- **Integration:** Update `EnemyVFXController.luau` to route the `"Explosion"` attack type to the new `ExplosionVFX` module. Remove the server-side visual sphere from `Keg:_spawnExplosionVFX()` (retain the invisible Roblox `Explosion` for potential sound/lighting, or replace entirely if custom sound is handled).

## Implementation Steps

1.  **Create Aura Assets:** Add the `Attachment`, `Highlight`, `PointLight`, and `ParticleEmitter` to the Keg rig in Studio, or create them procedurally in `Keg:_buildPlaceholderVisual()`.
2.  **Update Keg.luau:** Modify the arming sequence to animate the new aura effects instead of just flashing colors. Create a method to clean up the aura on death. Modify `_spawnExplosionVFX` to rely on the client for visuals.
3.  **Create ExplosionVFX Module:** Build the client-side particle systems and debris physics in `client/VFX/ExplosionVFX.luau`.
4.  **Wire up the Controller:** Add `ExplosionVFX` to `EnemyVFXController` and call it when an `"Explosion"` attack occurs.

## Verification

- Spawn a Keg and observe the aura while it chases.
- Let the Keg enter the arming state and observe the intensification of the aura.
- Let the Keg detonate and observe the new client-side stylized explosion and debris.
