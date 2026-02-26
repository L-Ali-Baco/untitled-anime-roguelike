# W1_Chest Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Scrap economy where enemies drop Scrap, which players spend on W1_Chests to pick 1 of 3 items, and fix the dark lighting.

**Architecture:** We will add Scrap distribution to CombatService, store Scrap as Player attributes, add a UI HUD for Scrap, build W1_Chest interaction in ItemService, and a Pick-3 UI in the client.

**Tech Stack:** Luau, Roblox Services (CollectionService, ReplicatedStorage), Roact/Fusion (if applicable for UI, or standard GUI).

---

### Task 1: Shared Remotes Setup

**Files:**

- Modify: `src/shared/Remotes.luau`

**Step 1: Add Remotes**
Add `PromptItemSelection` and `SelectChestItem` to the `REMOTE_EVENTS` table.

**Step 2: Commit**

```bash
git add src/shared/Remotes.luau
git commit -m "feat: add W1_Chest remotes"
```

### Task 2: Scrap Economy (Server)

**Files:**

- Modify: `src/server/Services/ItemService.luau`
- Modify: `src/server/Services/CombatService.luau`

**Step 1: Add Economy Logic to ItemService**
Add `scrapBalances = {}`, `AddScrap`, `SpendScrap`, and update attributes.

**Step 2: Hook up to CombatService**
In CombatService, find where enemies die (likely near `target.Humanoid.Health <= 0` or similar) and call `ItemService:AddScrap(attacker, 5)`.

**Step 3: Commit**

```bash
git add src/server/Services/ItemService.luau src/server/Services/CombatService.luau
git commit -m "feat: implement Scrap economy on server"
```

### Task 3: W1_Chest Interaction Location

**Files:**

- Modify: `src/server/Services/ItemService.luau`

**Step 1: Implement W1_Chest Logic**
Create `ItemService:SpawnW1Chest(position)` with a 25 Scrap requirement. On trigger, deduct scrap, get 3 items, fire `PromptItemSelection`. Listen to `SelectChestItem`.

**Step 2: Commit**

```bash
git commit -am "feat: add W1_Chest spawning and validation logic"
```

### Task 4: Client UI

**Files:**

- Create: `src/client/UI/HUD/ScrapDisplay.luau`
- Create: `src/client/UI/Screens/ItemSelectionScreen.luau`

**Step 1: Scrap Display**
Read `LocalPlayer:GetAttribute("Scrap")` and listen for changes. Display in lower right.

**Step 2: Item Selection Screen**
Listen to `PromptItemSelection`. Display 3 buttons. On click, fire `SelectChestItem` and hide.

**Step 3: Commit**

```bash
git add src/client/UI/
git commit -m "feat: add Scrap HUD and Item Selection UI"
```

### Task 5: Lighting Fix

**Files:**

- Modify: `src/client/VFX/StormController.luau`

**Step 1: Increase Brightness**
Bump `Lighting.Brightness` and `OutdoorAmbient` in the original lighting state or directly in Roblox Studio properties (`test.rbxl` generation might need default project tweaks, but StormController overrules it so we tweak that).

**Step 2: Commit**

```bash
git commit -am "fix: brighten baseline game lighting"
```
