# Changelog
All notable changes to this project are documented here. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), versioning: [SemVer](https://semver.org/).

## [Unreleased]

## [0.2.0] - 2026-11-22
### Added
- Game script error capture. Each test lists the `gameErrors` and `gameWarnings` logged on the server and every client during it. Known Studio noise is ignored, and `s.ignoreErrors({...})` adds patterns.
- `s.failOnErrors()` and the CLI's `--fail-on-errors` (bridge option `failOnErrors`) fail a test when game scripts log errors. `t.gameErrors()` reads them mid-test.
- Failure snapshots: a failed test records what each client saw (visible UI with paths, text and rects; position, health, equipped tool, focused TextBox). Also available as `client:snapshot()`.
- World and tool actions: `equip`, `unequip`, `activate`, `clickWorld` (parts, models, attachments or a Vector3) and `prompt` (walks into range and holds the ProximityPrompt, retrying until it triggers).
- The client proxy passes any method through to the agent, so new commands don't need server-side wiring.
- Example game: a coin pickup, a ProximityPrompt shop selling a Sword, a mouse-reading Paintbrush tool, a deliberate script error, and a Shop spec covering them.

### Changed
- The session watchdog's slack went from 60s to 45s, so stuck sessions are recovered sooner.

## [0.1.0] - 2026-11-22
### Added
- Command-line runner (`lune run cli/rehearse run|list <place>`). It opens the place in Studio with `-task RunScript`, reads the report from Studio's log, and closes Studio and any leftover test windows. Supports `--json`, `--junit`, `--report`, `--filter`, `--grep`, `--retries`, `--timeout`, `--stall` and `--keep-open`. Exit codes: 0 passed, 1 failed, 2 couldn't run.
- Session planning: tests in a spec share a session by default. `s.isolated()` and `{ isolated = true }` give a test its own session. `s.devices({...})` repeats a spec per simulated device and orientation.
- `s.skip`, `s.only`, `{ skip/only/timeout }` options, run-level `grep` (test names) and `filter` (spec names).
- `s.beforeEach` / `s.afterEach` hooks.
- `s.client(name, fn)` with `client:call(name, ...)` to run code inside a client.
- Client actions: `fill` (focus a TextBox, type, optionally submit), `key` with `{ hold }`, `click` with `{ button, offset }`, `exists`, `isVisible`, `isInViewport`, `character`, `moveTo`, `leave`.
- `t.clients()`, `t.addPlayers(n)` (experimental), `t.device`, `t.wait`.
- Flakiness handling for Studio test sessions:
  - Retries for sessions that fail before their tests run (default 1), with the reasons recorded in `retried`.
  - Clients that never appear are replaced through `AddPlayers` after 15s (`replacedClients`).
  - A short pause between sessions.
  - A per-session time budget. Past it, the bridge sets `Hung` and the CLI closes the stuck session's processes so it can be retried.
- `RehearseBridge.List` (planned sessions), `Progress` and `Version` attributes, and `[Rehearse]` progress lines in Output.
- JUnit XML and text reporters shared by the plugin and the CLI (`src/Report.luau`).
- StyLua, Selene and Lune in `aftman.toml`; Lune unit tests for spec loading, planning, reports and assertions; CI that lints, tests and builds.
- A draft Roblox skill (`skill/SKILL.md`) that teaches agents to write and run specs.
- Example specs for join/leave, text entry, keys, walking, client functions and device layouts.

### Changed
- Report format: `specs` is now `sessions`. Every planned test appears with `pass`, `fail` or `error`, and skipped tests are listed in `skippedTests`.
- Client paths can go through Instance-valued properties (`game.Workspace.CurrentCamera.ViewportSize`).
- The toolbar button is disabled while a run is in progress, and failed runs print as warnings.

### Fixed
- The toolbar icon failed to load. The button is now text-only.

## [0.0.1] - 2026-11-22
### Added
- Prototype plugin: Launcher (Edit), Runner (Server) and Agent (Client) built on `StudioTestService` and `VirtualInput`.
- Spec API: `players`, `test`, client `click`/`key`/`type`/`get`/`waitFor`, server `waitFor`, Jest-style `expect`.
- JSON report and an agent bridge (`ServerStorage.RehearseBridge`) for running from the Studio MCP.
- Example 2-player lobby place and spec.
