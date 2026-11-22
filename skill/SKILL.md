---
name: rehearse-e2e-tests
description: Write and run Rehearse end-to-end and multiplayer tests (specs in ServerStorage.RehearseSpecs) to verify gameplay and UI changes. Use after changing game code, UI or multiplayer flows, or when asked to test, verify or playtest something repeatably.
---

# Rehearse: repeatable E2E tests for this place

Rehearse is a Studio plugin that runs specs in real multiplayer test sessions (1–8 clients) with real input. Use it instead of improvising a playtest whenever a change can be checked by a script.

## 1. Check it's installed
Run in the Edit DataModel:
```lua
local b = game.ServerStorage:FindFirstChild("RehearseBridge")
return b and b:GetAttribute("Version") or "not installed"
```
If it isn't installed, tell the user. The plugin comes from https://github.com/alexander-michaelides/rehearse.

## 2. Write or update a spec
A spec is a ModuleScript under `ServerStorage.RehearseSpecs` (in a Rojo project, edit the `.luau` file on disk instead):
```lua
return function(s)
	s.players(2)
	s.test("what the player should experience", function(t)
		local p1 = t.client(1)
		p1:click("PlayerGui.Menu.Frame.PlayButton")             -- waits until visible
		t.waitFor(function() return p1.player:GetAttribute("Ready") end, 5, "player 1 ready")
		t.expect(p1:waitFor("PlayerGui.Menu.Enabled", false)).toBe(false)
	end)
end
```
- Client: `click`, `fill(path, text, { submit = true })`, `key("E")`, `get`, `waitFor`, `isInViewport`, `character`, `moveTo(Vector3)`, `equip(tool)`, `activate()`, `clickWorld(partPath)`, `prompt(promptPath)`, `call(name)` (for `s.client(name, fn)`), `leave()`.
- `s.failOnErrors()` fails tests on game script errors. `t.gameErrors()` lists them.
- Spec: `s.isolated()` or `{ isolated = true }` for a fresh session. `s.devices({ "iphone_7", "ipad_a16" })` to test screen sizes. `s.beforeEach`, `s.afterEach`, `s.skip`, `s.only`.
- Paths are relative to LocalPlayer unless they start with `game.`. The last segment may be a property or `@Attribute`.

## 3. Run it (non-blocking)
```lua
return game.ServerStorage.RehearseBridge.Start:Invoke({ filter = "Lobby" })
```
Poll `RehearseBridge:GetAttribute("Status")` every few seconds until it's `"done"` (about 10s per session), then read `RehearseBridge:GetAttribute("LastReport")` (JSON).

## 4. Act on the report
- `ok: true`: done. Report what was verified.
- Test `status: "fail"`: the game or the spec is wrong. Read `error`, then `gameErrors` (often the real cause), then `snapshot.visible` (what was on screen). Fix the game code and rerun only that spec (`filter`) or test (`grep`).
- Test `status: "error"`: the session failed to start (environment). Rerun once, then report it.
- Never loosen an assertion just to make it pass. Don't call `start_stop_play` during a run.
