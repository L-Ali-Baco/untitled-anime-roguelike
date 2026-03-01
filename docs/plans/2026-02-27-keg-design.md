# Keg Enemy Design

**Date:** 2026-02-27
**Topic:** Replaces the generic 'Kamikaze' with a rolling 'Keg' model.

## Objective

Convert the current "Kamikaze" suicide bomber enemy into a "Keg" character, utilizing a rolling mesh instead of standard humanoid walking animations.

## Architecture

The Keg will continue to inherit from `BaseEnemy` and utilize the Humanoid-free physics implementation (leveraging `LinearVelocity`, `AlignOrientation`, and `GroundCollision` boxes).

## Components

1. **Model:** A `Keg` model consisting of an invisible `HumanoidRootPart` for physics representation and a child `KegMesh` (e.g., `MeshPart`) for visuals.
2. **AI Class (`src/server/Enemies/Keg.luau`):** Replaces `Kamikaze.luau`. Will handle movement override and arming sequence.
3. **Configuration (`src/shared/Config/EnemyConfig.luau`):** The `Kamikaze` block will be renamed to `Keg`.
4. **Enemy Service (`src/server/Services/EnemyService.luau`):** The spawn map will be updated from `Kamikaze` to `Keg`.

## Data Flow / Logic

- **Rolling Animation:**
  - Since the enemy does not use Humanoids or rigged animation for movement, it will use a procedural approach.
  - During the `Tick` loop, the script will calculate the distance the `HumanoidRootPart` has moved since the last frame.
  - The visual `KegMesh` will be rotated along its local X-axis. The rotation angle will be proportional to the distance moved (Angle in radians = Distance / Radius), causing it to appear to roll naturally on the ground.
- **Arming & Explosion:**
  - When the Keg reaches `ArmRange`, it enters the `Arming` state.
  - During arming, movement ceases, the rolling rotation stops, and the model flashes red and white for `ArmDuration`.
  - After arming, the Keg detonates, dealing AoE damage (`ExplosionRadius`) and despawning, exactly mirroring the predecessor's logic.

## Error Handling

- If the model lacks a specific `KegMesh`, procedural rolling logic will safely abort or fallback gracefully to prevent errors in the `Tick` loop.

## Testing

- Verify the `Keg` correctly spawns via director or `/enemy keg` command.
- Verify the keg rolls smoothly without jitter and the rotation speed matches movement speed.
- Verify the arming sequence stops the rolling and correctly plays the flashing VFX.
- Verify the explosion deals damage and respects I-frames.
