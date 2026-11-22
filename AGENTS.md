# AGENTS.md: using Rehearse from an AI agent

Rehearse runs end-to-end and multiplayer tests inside Roblox Studio. Use it to verify gameplay and UI changes with repeatable specs instead of improvised playtests. The loop is: change game code, run the relevant specs, read the failures, fix, rerun.

There are two ways to run it. Pick by what you have:

| You have | Use |
|---|---|
| The Studio MCP (`execute_luau`) and an open place | **Bridge** (below). Fastest; works on the place as it is in Studio. |
| A shell and a place file (`rojo build`) | **CLI**. Opens Studio itself, so it works without the MCP. |

## Prerequisites
- The plugin is installed: `rojo build -o ~/Documents/Roblox/Plugins/Rehearse.rbxm` from this repo, then restart Studio. Check with `game.ServerStorage:FindFirstChild("RehearseBridge")` (Edit DataModel); its `Version` attribute is the plugin version.
- Specs live under `ServerStorage.RehearseSpecs` (with Rojo, a folder mapped there; one `.luau` file per spec).

## Write a spec
```lua
return function(s)
	s.players(2)                                   -- 1–8 simulated clients
	s.beforeEach(function(t) end)                  -- optional hooks; afterEach too
	s.client("coins", function()                   -- runs on the client: t.client(1):call("coins")
		return game:GetService("Players").LocalPlayer:GetAttribute("Coins")
	end)

	s.test("door opens for everyone", function(t)
		t.client(1):key("E")
		t.waitFor(function() return workspace.Door:GetAttribute("Open") end, 5, "door to open")
		t.expect(t.client(2):waitFor("game.Workspace.Door.@Open", true)).toBe(true)
	end)

	s.test("name box", { isolated = true }, function(t)   -- isolated: its own fresh session
		t.client(1):fill("PlayerGui.Menu.Frame.NameBox", "Ada", { submit = true })
	end)
end
```
- Prefer `waitFor` over `t.wait`. Every client action already waits for its target (5s default).
- Client actions: `click`, `fill`, `key`, `type`, `get`, `exists`, `waitFor`, `isVisible`, `isInViewport`, `character`, `moveTo`, `equip`, `unequip`, `activate`, `clickWorld`, `prompt`, `snapshot`, `call`, `leave`.
- To walk, use `moveTo`. Held keys don't register in the unfocused test-client windows.
- Use `s.failOnErrors()` (or `--fail-on-errors`) when the change shouldn't introduce script errors. `t.gameErrors()` returns them mid-test.
- UI across screens: `s.devices({ "iphone_7", "ipad_a16" })` and assert `client:isInViewport(path)`.
- Full API: [README.md](README.md#spec-api).

## Run through the Studio MCP bridge (Edit DataModel)
Calls are non-blocking, so they stay under MCP timeouts.

1. Optional, to see what would run:
   ```lua
   return game:GetService("HttpService"):JSONEncode(game.ServerStorage.RehearseBridge.List:Invoke({ filter = "Lobby" }))
   ```
2. Start:
   ```lua
   return game.ServerStorage.RehearseBridge.Start:Invoke({ filter = "Lobby", grep = "match" })  -- "started"
   ```
   Options (all optional): `filter` is a substring of the spec module name. `grep` is a case-insensitive substring of `"Spec > test name"`. `retries` sets extra attempts for sessions that fail to start (default 1).
3. Poll every few seconds (allow about 12s per session) until `"done"`:
   ```lua
   local b = game.ServerStorage.RehearseBridge
   return b:GetAttribute("Status") .. " " .. tostring(b:GetAttribute("Progress"))
   ```
4. Read the report: `return game.ServerStorage.RehearseBridge:GetAttribute("LastReport")`

`RehearseBridge.Run:Invoke(opts)` is the blocking variant. It usually exceeds MCP call timeouts.

## Run through the CLI (shell)
```bash
rojo build <your project>.project.json -o build/Game.rbxlx
lune run cli/rehearse run build/Game.rbxlx --json --quiet > report.json; echo $?
```
- Exit codes: `0` all passed, `1` tests failed or errored, `2` couldn't run (bad usage, Studio missing, plugin not installed, timeout or stall). The message goes to stderr.
- `--json` prints the report (shape below) to stdout. `--junit file.xml` writes JUnit. `list` instead of `run` prints the plan.
- Expect about 5s for Studio to open, plus about 10s per session. Use `--grep` to run only what you changed.
- The CLI closes the Studio it opened, including leftover test windows. It doesn't touch other Studio windows.

## Report shape
```json
{
  "ok": false, "passed": 3, "failed": 1, "errors": 1, "skipped": 0, "seconds": 41.2, "runId": "…", "version": "0.1.0",
  "error": null,
  "sessions": [{
    "spec": "Lobby", "players": 2, "device": null, "status": "ran", "attempts": 1,
    "sessionSeconds": 11.6, "joinSeconds": 7.1, "retried": null,
    "tests": [
      { "name": "…", "status": "pass", "ms": 748 },
      { "name": "…", "status": "fail", "ms": 34, "error": "client(1) click(\"PlayerGui.Menu.Play\"): timed out after 5s waiting for PlayerGui.Menu.Play to be visible", "logs": ["…"],
        "gameErrors": ["client(1): Players.Player1.PlayerScripts.Menu:12: attempt to index nil with 'Frame'"],
        "snapshot": { "client(1)": { "viewport": [1038, 499], "position": [0, 3, 0], "health": 100, "tool": null, "focused": null,
          "visible": [{ "path": "PlayerGui.Loading.Label", "class": "TextLabel", "text": "Loading…", "rect": [400, 200, 240, 40] }] } } }
    ]
  }, {
    "spec": "Mobile", "device": { "id": "iphone_7" }, "status": "error", "attempts": 2,
    "error": "timed out after 30s waiting for 1 client agent(s) to connect; players: …",
    "retried": ["attempt 1 (0.1s): session ended without a report (got nil); …"],
    "tests": [{ "name": "…", "status": "error" }]
  }],
  "skippedTests": [{ "spec": "Lobby", "name": "…", "reason": "skipped | not marked only | filtered out" }]
}
```
- `ok` is true only when nothing failed or errored.
- A test with `status: "fail"` ran, and its assertion or action failed. Read `error` first, then `gameErrors` (a script error is often the real cause), then `snapshot.visible` for what was actually on screen. Then fix the game code or the spec.
- A test with `status: "error"` never ran because its session failed (see the session's `error`). That's an environment problem, not a test result. Rerun once. If it repeats, report it.
- If the bridge's `Hung` attribute is set, a session is stuck inside Studio. Through the MCP you can't end it. Ask the user to press Stop in Studio, or use the CLI, which closes stuck sessions itself.

## Rules
- Don't call `start_stop_play` while a Rehearse run is active. Only one test session runs per Studio instance.
- A failing test is information. Fix the game code, or report a suspected bug. Never weaken an assertion just to make a test pass.
- Specs only read and drive the game. Don't put setup that changes the user's real data (DataStores, purchases) in specs.
