# Item Database & Stacking Logic

Reference table for all implemented and planned items.

## 1. The "Proc" Tier (Combat Satisfaction)
*On-Hit and On-Kill effects that create chaos.*

| Item Name | Rarity | Effect Description | Stacking Behavior | Implementation Tags |
|-----------|--------|--------------------|-------------------|---------------------|
| **Static Filament** | Common | **On Hit:** 15% chance to link nearby enemies with electricity, dealing **40%** damage. | **+40% Damage** per stack. (Chance stays 15%) | `Proc:OnHit`, `ChainLightning` |
| **Echo Blade** | Rare | Every **4th** M1 attack triggers a ghost-duplicate of the swing 0.2s later. | **-1 Hits** required (min 1). OR Ghost deals **+50%** damage. | `Passive:AttackCount`, `GhostSwing` |
| **Volatile Casing** | Common | **On Kill:** The enemy explodes for **150%** base damage in a **15 stud** radius. | **+150% Damage** and **+5 stud** radius per stack. | `Proc:OnKill`, `Explosion` |
| **Void Magnet** | Rare | **Critical Hits** pull enemies within **20 studs** toward the target. | **+10 studs** pull radius per stack. | `Proc:OnCrit`, `Vacuum` |

## 2. The "Movement" Tier (Speed & Flow)
*Mobility enhancers that integrate with combat.*

| Item Name | Rarity | Effect Description | Stacking Behavior | Implementation Tags |
|-----------|--------|--------------------|-------------------|---------------------|
| **Afterimage Cloak** | Rare | **Dash** leaves a decoy that explodes for **200%** damage after 1.5s. | **+100% Damage** per stack. | `Ability:Dash`, `Decoy` |
| **Jetstream Sandals** | Epic | **Double Jump** launches a gust of wind downward, stunning enemies for **1s**. | **+0.5s Stun** and **+Damage** per stack. | `Ability:AirJump`, `AOE` |
| **Momentum Battery** | Common | Hitting enemies grants **+2%** Movement Speed for 5s. Stacks up to **10** times. | **+2 Max Stacks** (Higher top speed) or **+1s Duration**. | `Buff:OnHit`, `Speed` |

## 3. The "Game Changer" Tier (Legendary/Unique)
*Build-defining items that alter core mechanics.*

| Item Name | Rarity | Effect Description | Stacking Behavior | Implementation Tags |
|-----------|--------|--------------------|-------------------|---------------------|
| **Glass Cannon** | Legendary | Deal **+200%** Damage, but Max Health is reduced by **90%**. | **+100% Damage** (Health penalty stays static). | `Stat:Damage`, `Stat:Health` |
| **The Hive-Mind** | Legendary | Attacks apply "Infection" instead of damage. After **3s**, infected enemies take **total damage stored**. | **-0.5s** delay before damage burst. | `Replace:DamageLogic`, `DoT` |
| **Aura of the Tyrant** | Legendary | **Disables M1 combo.** A massive spectral sword attacks automatically when you use Skills. | **+50% Sword Size** and Damage. | `Replace:M1`, `Summon` |

## 4. Standard Stat Items (The Basics)
*Filler items to enable the scaling of the fancy ones.*

| Item Name | Rarity | Effect Description | Stacking Behavior |
|-----------|--------|--------------------|-------------------|
| **Sharp Whetstone** | Common | **+10%** Damage. | Linear (+10% additively). |
| **Swift Boots** | Common | **+15%** Movement Speed. | Linear. |
| **Vitality Gem** | Common | **+25** Max Health. | Linear. |
| **Lens Maker's Glasses**| Common | **+10%** Critical Chance. | Linear (Max 100%). |
