# Contributor Setup Guide

Everything you need to get the project running on your machine and start contributing.

---

## Prerequisites

Install these before doing anything else:

| Software | Download | Notes |
|----------|----------|-------|
| **Roblox Studio** | https://www.roblox.com/create | Required to run and test the game |
| **VS Code** | https://code.visualstudio.com/ | Primary code editor |
| **Git** | https://git-scm.com/downloads | Version control |
| **Rokit** | https://github.com/rojo-rbx/rokit | Toolchain manager (installs Rojo, Wally, etc.) |

### Installing Rokit

Rokit manages all the Roblox dev tools for you. Install it by following the instructions at https://github.com/rojo-rbx/rokit#installation.

On Windows, open PowerShell and run:
```powershell
irm https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.ps1 | iex
```

After installing, restart your terminal so the `rokit` command is available.

---

## Getting Started

### 1. Clone the repository

```bash
git clone https://github.com/L-Ali-Baco/untitled-anime-roguelike.git
cd untitled-anime-roguelike
```

### 2. Install the toolchain

This installs the exact versions of Rojo, Wally, Selene, and StyLua that the project uses (defined in `rokit.toml`):

```bash
rokit install
```

After this completes, you should have access to:

| Tool | Version | Purpose |
|------|---------|---------|
| **Rojo** | 7.6.1 | Syncs your Luau files into Roblox Studio |
| **Wally** | 0.3.2 | Package manager (installs dependencies) |
| **Selene** | 0.30.0 | Luau linter (catches bugs and bad patterns) |
| **StyLua** | 2.3.1 | Luau code formatter (keeps style consistent) |

### 3. Install packages

This downloads the project's dependencies (Promise, Roact, Fusion, Signal) into the `Packages/` folder:

```bash
wally install
```

### 4. Open the project in VS Code

```bash
code .
```

VS Code will prompt you to install recommended extensions. **Accept all of them.** They are:

- **Luau LSP** -- autocomplete, type checking, and go-to-definition for Luau
- **Selene** -- inline lint warnings
- **StyLua** -- auto-formats your code on save

### 5. Start Rojo and connect from Studio

Start the Rojo dev server:

```bash
rojo serve
```

Then in Roblox Studio:

1. Open the **Rojo plugin** (install it from the Roblox Plugin Marketplace if you don't have it)
2. Click **Connect** (it connects to `localhost:34872` by default)
3. Your file changes will now sync into Studio in real time

---

## Project Structure

```
src/
  client/          -- Client-side code (runs on each player's machine)
    Core/          -- Input, camera, stamina, combat controllers
    Features/      -- Class selection, targeting, loot, movement, beacons
    UI/            -- HUD elements, screens, mobile controls
    VFX/           -- Visual effects (combat, projectiles, screen shake, etc.)

  server/          -- Server-side code (authoritative game logic)
    Services/      -- CombatService, EnemyService, SkillService, ItemService, etc.
    Skills/        -- Skill definitions per class (Vanguard, Gunslinger)

  shared/          -- Code shared between client and server
    Config/        -- Game configuration (combat, movement, classes, enemies, etc.)
    Enums/         -- InputAction, CharacterState
    Events/        -- Event definitions
    Framework/     -- Custom Service/Controller framework (Init/Start lifecycle)
    Lib/           -- Utility libraries (CharacterLib, StatLib)
    Types/         -- Type definitions
```

Key files:
- `default.project.json` -- Rojo project config (maps `src/` folders to Roblox services)
- `wally.toml` -- Package dependencies
- `rokit.toml` -- Tool versions

---

## Development Workflow

### Branching

**Never push directly to `main`.** Always work on a feature branch:

```bash
git checkout -b feature/your-feature-name
```

When you're done, push your branch and open a Pull Request on GitHub:

```bash
git add .
git commit -m "Add your descriptive commit message"
git push -u origin feature/your-feature-name
```

Then go to the repo on GitHub and create a Pull Request for review.

### Branch naming conventions

- `feature/description` -- New features (e.g. `feature/new-enemy-type`)
- `fix/description` -- Bug fixes (e.g. `fix/combat-hitstop-timing`)
- `refactor/description` -- Code cleanup (e.g. `refactor/skill-registry`)

### Before committing

Run the linter and formatter to make sure your code is clean:

```bash
selene src/          -- Check for lint issues
stylua src/          -- Auto-format all code
```

StyLua will also format on save if you have the VS Code extension installed.

---

## Code Style

These are enforced by the tooling, but good to know:

- **Indentation:** Tabs (width 4)
- **Line width:** 120 characters max
- **Quotes:** Double quotes preferred (`"hello"` not `'hello'`)
- **Line endings:** Unix (LF)
- **Linting standard:** `roblox` (Selene)

---

## Merge Conflicts

Merge conflicts happen when two people edit the same lines in the same file. Here's how to prevent them and handle them when they do occur.

### Rules to Avoid Conflicts

1. **Pull before you start working.** Every time you sit down to code, pull the latest `main` first:
   ```bash
   git checkout main
   git pull
   git checkout -b feature/your-new-branch
   ```

2. **Keep branches short-lived.** The longer your branch lives, the more `main` diverges from it. Aim to merge within 1-3 days.

3. **Don't edit the same files as someone else at the same time.** Communicate with the team about what you're working on. A simple "I'm working on SkillService today" in the chat goes a long way.

4. **Stay in your lane.** Stick to the files related to your feature:
   - Working on a new enemy? Stay in `src/server/Services/EnemyService.luau` and `src/shared/Config/EnemyConfig.luau`.
   - Working on UI? Stay in `src/client/UI/`.
   - Avoid editing shared config files (`Config/`, `Remotes.luau`, `default.project.json`) unless your feature specifically requires it.

5. **Keep commits small and focused.** One commit per logical change, not one giant commit with everything mixed together.

6. **Rebase your branch on `main` regularly** if you're working on something for more than a day:
   ```bash
   git checkout main
   git pull
   git checkout feature/your-branch
   git rebase main
   ```

### How to Resolve a Conflict

If Git tells you there's a conflict when merging or rebasing:

1. Open the conflicting file(s) in VS Code. You'll see markers like this:
   ```
   <<<<<<< HEAD
   -- your version of the code
   =======
   -- the other person's version of the code
   >>>>>>> feature/other-branch
   ```

2. VS Code shows buttons above each conflict: **Accept Current**, **Accept Incoming**, **Accept Both**. Choose the right one, or manually edit the code to combine both changes correctly.

3. After resolving all conflicts in all files:
   ```bash
   git add .
   git rebase --continue    (if rebasing)
   git commit               (if merging)
   ```

4. **Test your code after resolving.** Connect Rojo and make sure nothing is broken in Studio.

### High-Risk Files (Be Extra Careful)

These files are most likely to cause conflicts because multiple people may need to edit them:

| File | Why it's risky | What to do |
|------|---------------|------------|
| `src/shared/Remotes.luau` | Everyone adds remote events here | Coordinate before adding new remotes |
| `src/shared/Config/*.luau` | Shared game config | Add new entries at the bottom of tables |
| `default.project.json` | Rojo project mapping | Only edit if adding new top-level folders |
| `src/client/init.client.luau` | Client bootstrap | Only edit to register new controllers |
| `src/server/init.server.luau` | Server bootstrap | Only edit to register new services |

### If Everything Goes Wrong

If a rebase or merge gets messy and you're not sure what happened:

```bash
git rebase --abort    (cancels an in-progress rebase)
git merge --abort     (cancels an in-progress merge)
```

This puts you back to where you were before you started. No damage done. Ask for help before trying again.

---

## Common Commands

| Command | What it does |
|---------|-------------|
| `rokit install` | Install/update all dev tools |
| `wally install` | Install/update Luau packages |
| `rojo serve` | Start live sync to Studio |
| `rojo build -o build.rbxl` | Build a standalone place file |
| `selene src/` | Lint all source files |
| `stylua src/` | Format all source files |
| `stylua --check src/` | Check formatting without changing files |

---

## Troubleshooting

**Rojo plugin not connecting?**
- Make sure `rojo serve` is running in your terminal
- Check that the Rojo plugin version in Studio is compatible (v7.x)
- Try restarting Studio

**Wally packages missing / errors about missing modules?**
- Run `wally install` again
- Make sure the `Packages/` folder was created

**Selene or StyLua not found?**
- Run `rokit install` to reinstall the toolchain
- Make sure Rokit's bin directory is in your PATH

**Git says "permission denied"?**
- Make sure you've been added as a collaborator on the GitHub repo
- Try authenticating with `gh auth login` or set up an SSH key

---

## Questions?

Ask in the team chat or open an issue on the GitHub repo.
