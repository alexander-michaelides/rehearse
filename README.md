# Rehearse

**End-to-end and multiplayer tests for Roblox games.** Write a spec once. Rehearse launches a real Studio test session with up to 8 clients, clicks your actual UI, types into text boxes, presses keys, walks characters around, checks server and client state, and gives you a pass/fail report. Run it from the toolbar, from a terminal or CI runner, or from an AI agent through the Studio MCP.

> **Status: early (v0.2.0).** Works end to end on macOS with Studio 0.748. The API may still change before 1.0.

```lua
-- ServerStorage/RehearseSpecs/Lobby (ModuleScript)
return function(s)
	s.players(2)

	s.test("match starts only after both players press Play", function(t)
		local p1, p2 = t.client(1), t.client(2)

		p1:click("PlayerGui.Menu.Frame.PlayButton")
		t.waitFor(function() return p1.player:GetAttribute("Ready") end, 5, "player 1 to be ready")
		t.expect(workspace:GetAttribute("MatchStarted")).toBe(false)

		p2:click("PlayerGui.Menu.Frame.PlayButton")
		t.waitFor(function() return workspace:GetAttribute("MatchStarted") end, 5, "the match to start")
		t.expect(p1:waitFor("PlayerGui.Menu.Enabled", false)).toBe(false)
	end)
end
```

```
$ lune run cli/rehearse run build/Game.rbxlx
rehearse: opening build/Game.rbxlx in Studio...
rehearse: 1/7 JoinLeave (2p)
...
Rehearse PASSED: 10 passed, 0 failed, 0 errors, 0 skipped (89.73s)
  Lobby [2p, 11.62s]
    ✓ both players see the Play button (215ms)
    ✓ match starts only after both players press Play (566ms)
  Mobile [iphone_7] [1p, 9.15s]
    ✓ Play button is fully on screen (466ms)
  ...
```

## Why
Roblox shipped the building blocks for automated playtesting (`StudioTestService`, `VirtualInput`, `StudioDeviceSimulatorService`), but nothing to write and run tests with. Rehearse is that missing layer: a spec format, a runner that absorbs the APIs' rough edges (sessions that start too early, slow client joins, leftover processes), and reports that people, CI and agents can read.

## Install
1. Build the plugin into your Plugins folder (needs [Aftman](https://github.com/LPGhatguy/aftman)):
   ```bash
   aftman install
   rojo build -o ~/Documents/Roblox/Plugins/Rehearse.rbxm     # Windows: %LOCALAPPDATA%\Roblox\Plugins
   ```
2. Restart Studio (it doesn't hot-reload local plugins).
3. Put specs in `ServerStorage.RehearseSpecs` (with Rojo, map a folder there; see `example.project.json`).

## Spec API
Declarations (`s`):

| Call | What it does |
|---|---|
| `s.players(n)` | Number of simulated clients, 1–8 (default 1) |
| `s.test(name, fn)` / `s.test(name, opts, fn)` | A test. `opts`: `timeout` (default 30s), `isolated`, `skip`, `only` |
| `s.skip(name, fn)`, `s.only(name, fn)` | Shorthands. If any test is `only`, only those run |
| `s.isolated()` | Every test in this spec gets its own fresh session |
| `s.devices({ "iphone_7", { id = "ipad_a16", orientation = "Portrait" } })` | Run the spec once per simulated device |
| `s.beforeEach(fn)`, `s.afterEach(fn)` | Hooks around every test (`afterEach` runs even when the test fails) |
| `s.beforeJoin(fn)` | Runs on the server before any client joins (setup, or tracing PlayerAdded/CharacterAdded). `t.log` goes to the session's `setupLogs` |
| `s.client(name, fn)` | A function that runs **on the client**, called with `client:call(name, ...)` |
| `s.failOnErrors()` | Fail a test if any game script logs an error during it (or `--fail-on-errors` for a whole run) |
| `s.ignoreErrors({ "pattern", ... })` | Lua patterns for errors and warnings that aren't the game's fault |

In a test (`t`):

| Call | What it does |
|---|---|
| `t.client(i)` | The *i*-th client in join order. `.player` is its `Player` on the server |
| `t.clients()`, `t.players()` | All client proxies / `Player`s |
| `t.waitFor(fn, timeout?, description?)` | Polls a server-side predicate (default 5s) |
| `t.expect(v, label?).toBe / toEqual / toBeTruthy / toBeFalsy / toBeNear / toContain`, `.never.*` | Assertions |
| `t.addPlayers(n)` | Adds players mid-session and returns their client proxies (experimental; see limitations) |
| `t.device` | The simulated device for this session (`{ id, orientation? }`) or nil |
| `t.gameErrors()` | Script errors logged so far in this test, from the server and every client |
| `t.log(...)`, `t.wait(sec)` | Attach log lines to the result / sleep (prefer `waitFor`) |

On a client (`local c = t.client(1)`). Every action waits for its target first:

| Call | What it does |
|---|---|
| `c:click(path, { button?, offset?, timeout? })` | Clicks the centre of a visible, active GuiObject |
| `c:fill(path, text, { submit? })` | Focuses a TextBox, types `text`, optionally presses Enter |
| `c:key("E", { hold? })`, `c:type(text)` | Key press (or hold for N seconds) / text into the focused box |
| `c:get(path)`, `c:exists(path)` | Reads an instance, property or `@Attribute` on the client |
| `c:waitFor(path, expected?, timeout?)` | Polls a client value until truthy or equal to `expected` |
| `c:isVisible(path)`, `c:isInViewport(path)` | Rendered at all / rendered and fully on screen |
| `c:character()`, `c:moveTo(Vector3, timeout?)` | Waits for the character / walks it there, returns final position |
| `c:equip(name)`, `c:unequip()`, `c:activate({ hold? })` | Equip a Tool from the Backpack, unequip, activate the equipped tool |
| `c:clickWorld(target)` | Clicks where a part, model, attachment (path) or `Vector3` is drawn on screen. Use it for tools that read the mouse |
| `c:prompt(path, { walk? })` | Walks into range of a ProximityPrompt and holds it until it triggers |
| `c:snapshot()` | What the player sees: visible UI (path, text, rect), position, health, tool, focused TextBox |
| `c:call(name, ...)` | Runs a `s.client` function on that client and returns its result |
| `c:leave()` | Disconnects the client and waits until the server sees it leave |

Any other method name is sent to the client agent as a command, so `c:somethingNew()` fails with "unknown command" rather than silently doing nothing.

### What a failing test reports
Each test result also carries:
- `gameErrors` and `gameWarnings`: anything game scripts logged during the test on the server or any client, prefixed `server:` or `client(i):`. Known Studio noise (other plugins' icons, asset loading) is ignored.
- On the session: `startupErrors` and `startupWarnings`, for anything logged while the session started and players joined. A script that crashes at load shows up here, not as a pile of downstream errors.
- `snapshot`, on failure only: for each client, the visible UI elements with their paths and text, the character position and health, the equipped tool and the focused TextBox. An agent can see why `click("PlayerGui.Shop.Buy")` failed (for example, the shop never opened) without a screenshot.

Client paths are relative to `LocalPlayer` (`"PlayerGui.Menu.Play"`) unless they start with `game.` (`"game.Workspace.CurrentCamera.ViewportSize"`). The last segment can be a property or `@Attribute`.

Device ids come from `StudioDeviceSimulatorService:GetDeviceListAsync()`, for example `iphone_7`, `iphone_14`, `samsung_galaxy_a16`, `ipad_a16`, `vga`.

## Running
- **Toolbar:** Rehearse → *Run tests*. The summary prints to Output.
- **Terminal / CI** ([Lune](https://lune-org.github.io/docs) CLI). Opens the place in Studio, runs, closes Studio:
  ```bash
  rojo build -o build/Game.rbxlx
  lune run cli/rehearse run build/Game.rbxlx --junit results.xml
  lune run cli/rehearse list build/Game.rbxlx --grep "lobby"      # what would run
  ```
  Options: `--filter`, `--grep`, `--fail-on-errors`, `--solo`, `--json`, `--junit`, `--report`, `--retries`, `--timeout`, `--stall`, `--studio`, `--keep-open`, `--quiet`. Exit codes: `0` passed, `1` failed, `2` couldn't run.
- **AI agents (Studio MCP):** see [AGENTS.md](AGENTS.md).

### Solo mode
`--solo` (or `{ solo = true }` through the bridge) runs 1-player sessions as an ordinary Play test inside the Studio window, instead of a separate server and client. It's faster, and the Studio MCP can screenshot or record the client (`video_capture`). Notes:
- The player is your signed-in Studio account, so your name and avatar appear in the game and in reports.
- Studio throttles rendering when its window is in the background, so keep the window visible if you're recording.
- Multi-player specs always use separate processes.

## How it works
Studio loads plugins into every DataModel of a test session, so one plugin plays three roles:

| DataModel | Role |
|---|---|
| Edit | **Launcher**: loads specs, plans sessions, starts each with `StudioTestService:ExecuteMultiplayerTestAsync`, retries sessions that fail to start, collects the report |
| Server | **Runner**: waits for every client agent, runs the planned tests, returns results through `EndTest` |
| Client | **Agent**: performs input with `VirtualInput`, sets the simulated device, and reads client state on request |

The plugin adds nothing to your saved place. During a Rehearse session it creates `ReplicatedStorage.__Rehearse` (a RemoteFunction, a RemoteEvent and a copy of the running spec) inside the throwaway test DataModel only. In Edit it creates a non-archivable `ServerStorage.RehearseBridge` for the CLI and agents. Outside Rehearse sessions it stays inert during normal playtests.

## Permissions
The plugin asks for none: no HTTP and no script injection. The CLI runs Studio with `-task RunScript` and reads Studio's own log file (`~/Library/Logs/Roblox` on macOS) to get the report.

## Known limitations
- Each session costs about 8–12s of startup, mostly clients joining. Tests in a spec share a session unless you mark them `isolated`.
- One run at a time per Studio instance (a `StudioTestService` limit).
- Specs are loaded from a fresh copy each run. In Edit the copy isn't parented, so `require(script.Parent...)` from a spec only works inside sessions; reference shared helpers by absolute path (`game:GetService("ServerStorage").RehearseSpecs._Helpers`). Modules whose names start with `_` aren't treated as specs.
- `s.client` functions are loaded on the client by requiring the spec there, so a spec that declares them must not `require` server-only modules at its top level.
- `t.addPlayers` uses `StudioTestService:AddPlayers`. It usually works in the example spec, but once in testing the session froze, consistent with the reported crash bug ([DevForum](https://devforum.roblox.com/t/4691976)). The watchdog recovered it. Give those tests `isolated = true`.
- Test clients run in unfocused windows, and holding a key there doesn't register. `c:prompt` falls back to `ProximityPrompt:InputHoldBegin`, but `c:key(k, { hold })` for movement may not work. Use `c:moveTo` for walking.
- VirtualInput has no touch input, so mobile tests check layout (`s.devices`, `isInViewport`) and drive input with mouse and keys.
- If Studio crashes (for example in `AddPlayers`), it may show a dialog that blocks new Studio launches until you dismiss it. The CLI reports this within 60s.
- The CLI is tested on macOS only. On Windows, Studio discovery and log paths are implemented but untested, and the CLI doesn't close Studio afterwards.
- Studio's test sessions are occasionally flaky. During development, a session's second client sometimes never launched, and once a session never finished. Rehearse works around this in three ways, all recorded in the report:
  - It replaces clients that haven't appeared after 15s (`replacedClients`). This path hasn't been triggered in testing yet.
  - It retries a session that fails before its tests run (`attempts`, `retried`).
  - It flags a session that runs past its time budget. The CLI then closes that session's processes so the retry can run. Through the MCP bridge, a stuck session needs a manual Stop in Studio.
- During development, one CLI run also stalled before its first session, and the cause isn't known yet. The CLI exits with code 2 if there's no progress for `--stall` seconds (default 180).

## Develop
```bash
aftman install
stylua src example cli tests && selene src example && selene --config cli/selene.toml cli tests
lune run tests/run                                           # unit tests for spec loading, planning, reports
rojo build -o ~/Documents/Roblox/Plugins/Rehearse.rbxm
rojo build example.project.json -o build/RehearseExample.rbxlx
lune run cli/rehearse run build/RehearseExample.rbxlx        # end-to-end against the example game
```

## License
MIT
