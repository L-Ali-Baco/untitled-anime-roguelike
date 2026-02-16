# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Roblox multiplayer roguelike action game (Luau). "Risk of Rain" meets anime combat. Mobile-first (70% mobile players), server-authoritative architecture.

## Toolchain & Commands

All tools are managed by Rokit. Install with `rokit install`.

```bash
wally install              # Install Luau dependencies (Promise, Roact, Signal, Fusion)
rojo serve                 # Live-sync files to Roblox Studio
rojo build -o build.rbxl   # Build place file
selene src/                # Lint (roblox standard library)
stylua src/                # Format code
```

There are no automated tests. Testing is done in Roblox Studio via `rojo serve`.

## Architecture

### Service/Controller Pattern

The codebase uses a custom two-phase bootstrap framework:

- **Services** (`src/server/Services/`) — Server-side modules. Named `*Service.luau`. Auto-discovered by `init.server.luau` if the name ends with "Service".
- **Controllers** (`src/client/Core/`, `src/client/Features/`, `src/client/VFX/`) — Client-side modules. Named `*Controller.luau`. Auto-discovered by `init.client.luau`.

Both follow the same lifecycle:
1. `Init()` — Setup phase. Can reference other modules but not call them.
2. `Start()` — All modules loaded. Safe to call other modules. Runs in `task.spawn`.

Module shape:
```luau
local MyService = {}
MyService.Name = "MyService"
function MyService:Init() end
function MyService:Start() end
return MyService
```

### Rojo Mapping (`default.project.json`)

| Filesystem | Roblox Location |
|---|---|
| `src/client/` | `StarterPlayer.StarterPlayerScripts.Client` |
| `src/server/` | `ServerScriptService.Server` |
| `src/shared/` | `ReplicatedStorage.Shared` |
| `Packages/` | `ReplicatedStorage.Packages` |

### Client-Server Communication

All remotes are defined in `src/shared/Remotes.luau` — single source of truth. Uses `RemoteEvent` names listed in `REMOTE_EVENTS` table. Server creates them on init; client waits for them. Add new remotes to the `REMOTE_EVENTS` table in that file.

### Config-Driven Design

All game tuning lives in `src/shared/Config/`. Key configs:
- `CombatConfig` — combo data, hitstop, screen shake, damage numbers
- `ClassConfig` — class stats (Vanguard, Gunner), model paths
- `ItemRegistry` — all items, effects, stacking behavior
- `DirectorConfig` — difficulty scaling ("The Storm")
- `EnemyConfig`, `MovementConfig`, `StaminaConfig`, `SkillConfig`, `CameraConfig`

### Key Principles

- **Server-authoritative**: Server validates all damage/actions. Client handles VFX and immediate feedback.
- **Config-first**: Game mechanics are data in config files, not hardcoded logic.
- **Fail-safe bootstrap**: All module loading wrapped in `pcall`; one failing module doesn't crash others.
- **Attribute-based state**: Player stats stored as Instance attributes for replication.
- **CollectionService tags**: Entities identified by tags ("Enemy", "TrainingDummy").

## Code Style

Enforced by StyLua (`stylua.toml`): tabs, 120-char line width, double quotes, Unix line endings.

Naming:
- `PascalCase` for modules, services, controllers, types
- `camelCase` for local variables and functions
- `UPPER_SNAKE_CASE` for module-level constants

Type annotations are used on function signatures. Export types from modules with `export type`.

## High-Risk Files (Coordinate Before Editing)

- `src/shared/Remotes.luau` — all network communication
- `src/shared/Config/*.luau` — shared game configuration
- `default.project.json` — Rojo file mapping
- `src/client/init.client.luau` / `src/server/init.server.luau` — bootstrappers

## Branch Conventions

Feature branches: `feature/`, `fix/`, `refactor/` prefixes. Never push directly to `main`.
