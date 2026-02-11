# Debug Commands

These commands are available to the developer (and usually admins) for testing the game loop and items.

## 1. Loot & Items
Commands to test the progression and item system.

| Command | Usage | Description |
|---------|-------|-------------|
| **/give** | `/give [ItemName]` | Grants the specified item to your inventory. Supports partial matching (e.g., `/give sharp` gives `Sharp Whetstone`). |

## 2. Director & Difficulty
Commands to control "The Storm" difficulty scaling.

| Command | Usage | Description |
|---------|-------|-------------|
| **/diff** | `/diff [Number]` | Sets the difficulty multiplier instantly. <br> **1.0** = Drizzle (Start)<br> **2.0** = Downpour<br> **4.0** = Typhoon (Max) |
| **/time** | `/time [Multiplier]` | Accelerates time scaling. `/time 10` makes difficulty increase 10x faster. |
| **/reset** | `/reset` | Resets the run timer and difficulty to base levels. |

## 3. Spawning & Events
Commands to trigger AI director events.

| Command | Usage | Description |
|---------|-------|-------------|
| **/elite** | `/elite` | Forces an Elite Enemy (larger, stronger) to spawn near you. |
| **/horde** | `/horde` | Forces a Horde Wave event (spawn ~10 enemies around you). |

## Notes
*   **Partial Matching:** The `/give` command uses partial string matching, so `/give gla` will give "Glass Cannon".
*   **Permissions:** Currently, these commands are enabled for **all players** in the development build. Ensure you add an Admin check before release.
