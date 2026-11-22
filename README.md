# Rehearse

**End-to-end and multiplayer tests for Roblox games.** Write a spec once. Rehearse launches a real Studio test session with up to 8 clients, clicks your actual UI, checks server and client state, and gives you a pass/fail report. You can run it from a toolbar button, from the command bar, or from an AI agent through the Studio MCP.

> **Status: prototype (v0.0.x).** The core loop works: a 2-player session, VirtualInput clicks, server and client assertions, and a JSON report. Expect the API to change.

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
Rehearse PASSED: 2 passed, 0 failed, 0 errors (11.5s)
  Lobby [2p, 11.5s]
    ✓ both players see the Play button (1067ms)
    ✓ match starts only after both players press Play (748ms)
```

## How it works
Studio loads plugins into every DataModel of a test session, so one plugin plays three roles:

| DataModel | Role |
|---|---|
| Edit | **Launcher**: finds specs, starts `StudioTestService:ExecuteMultiplayerTestAsync`, and collects reports |
| Server | **Runner**: waits for every client agent, runs the spec, and returns results through `EndTest` |
| Client | **Agent**: performs input with `VirtualInput` and reads client-side state on request |

Specs run on the server. Client actions are sent to each client's agent over a RemoteFunction that exists only during Rehearse sessions. Outside a Rehearse session, the plugin stays inert during normal playtests.

## Spec API
| Call | What it does |
|---|---|
| `s.players(n)` | Number of simulated clients (1–8) |
| `s.test(name, fn)` / `s.test(name, { timeout = 10 }, fn)` | Declare a test (default timeout 30s) |
| `t.client(i)` | The *i*-th client in join order. `.player` is its `Player` on the server |
| `client:click(path)` | Waits until the GuiObject is visible, then clicks its center |
| `client:key("E")`, `client:type("hello")` | Keyboard and text input |
| `client:get(path)` | Reads an instance, property, or `@Attribute` on the client |
| `client:waitFor(path, expected?, timeout?)` | Polls a client value until it's truthy or equals `expected` |
| `t.waitFor(fn, timeout?, description?)` | Polls a server-side predicate |
| `t.expect(v).toBe / toEqual / toBeTruthy / toBeFalsy / toBeNear / toContain`, `.never.*` | Assertions |
| `t.log(...)` | Attach log lines to the test result |

Client paths are relative to `LocalPlayer` (`"PlayerGui.Menu.Play"`) unless they start with `game.` (`"game.Workspace.Door.@Open"`).

## Running
- **Toolbar:** Rehearse → *Run tests*. The summary prints to Output.
- **Command bar, scripts, or agents:** see [AGENTS.md](AGENTS.md).

## Develop
```bash
aftman install
rojo build -o ~/Documents/Roblox/Plugins/Rehearse.rbxm      # install the plugin
rojo build example.project.json -o build/RehearseExample.rbxlx
```
Studio doesn't hot-reload local plugins. Reopen the place after reinstalling.

## Known limitations (prototype)
- All tests in a spec share one session, so state carries over between tests. Order your tests or write them to be independent.
- Each spec costs about 10s of session startup, mostly clients joining.
- One run at a time per Studio instance (a StudioTestService limit).

## License
MIT
