# W1_Chest and Coins Mechanic Design

## Overview

This feature introduces an economy mechanic where eliminating enemies grants currency ("Scrap"), and players can spend this Scrap to open a `W1_Chest`. Instead of granting a random item immediately, opening a `W1_Chest` presents players with a "Pick 1 of 3" item selection UI.

## Architecture & Data Flow

### 1. Currency Generation (Server)

- We will add a `Scrap` or `Coins` balance to the player's data (likely within `ItemService` or a new `EconomyService`).
- When `CombatService` handles an enemy death, it will award a fixed amount of Scrap to the killing player (or distribute it).
- The server replicates the player's Scrap balance to the client using an attribute (e.g., `Player:SetAttribute("Scrap", value)`) so the HUD can read it effortlessly.

### 2. The HUD Updates (Client)

- A new UI component will be added to the player's HUD constantly displaying `{ScrapIcon} {Value}`.
- It will listen for the `AttributeChanged` signal on the Player for "Scrap".

### 3. W1_Chest Interaction (Server & Client)

- `MapService` or `ItemService` will spawn `W1_Chest` parts in the map.
- The chest will have a `ProximityPrompt` with the action text: `Open W1_Chest (25 Scrap)`.
- **Validation**: On trigger, `ItemService` verifies the player has $\ge$ 25 Scrap.
- **Consumption**: The server deducts 25 Scrap and disables the ProximityPrompt (or makes the chest disappear) so nobody else can take it.
- **Selection Generation**: The server queries `ItemRegistry.GetRandomItemKey()` three times to get 3 unique items.
- The server fires a new remote event: `PromptItemSelection(item1, item2, item3)` to that specific client.

### 4. Selection UI (Client)

- The client receives `PromptItemSelection`.
- A modal UI opens displaying 3 item cards. Each card shows the item's Icon, Name, and Description (retrieved locally from `ItemRegistry`).
- The player clicks one.
- The client fires a remote back to the server: `SelectChestItem(chosenItemKey)`.

### 5. Fulfillment (Server)

- The server validates the choice (ensuring it was one of the 3 offered).
- The server calls `ItemService:GrantItem(player, chosenItemKey)`.

## Future Considerations

- Allow the `W1_Chest` cost to scale with the Director's time/difficulty level.

## Lighting Fix

We will separately increase the `Brightness` and `Ambient`/`OutdoorAmbient` in the `Lighting` service and ensure `StormController` accommodates the brighter baseline.
