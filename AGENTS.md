# AGENTS.md: using Rehearse from an AI agent

Rehearse runs end-to-end and multiplayer tests inside Roblox Studio. Use it to verify gameplay and UI changes with repeatable specs instead of improvised playtests.

## Prerequisites
- The Rehearse plugin is installed (`~/Documents/Roblox/Plugins/Rehearse.rbxm`), and the place is open in Studio in Edit mode.
- You can call the Studio MCP `execute_luau` tool with `datamodel_type: "Edit"`.

## Write a spec
Create a ModuleScript under `ServerStorage.RehearseSpecs` (with Rojo, a `.luau` file in the folder mapped there):

```lua
return function(s)
	s.players(2)                       -- 1–8 simulated clients
	s.test("door opens for everyone", function(t)
		t.client(1):key("E")
		t.waitFor(function() return workspace.Door:GetAttribute("Open") end, 5, "door to open")
		t.expect(t.client(2):waitFor("game.Workspace.Door.@Open", true)).toBe(true)
	end)
end
```
Prefer `waitFor` over fixed waits. Every client action already waits for its target.

## Run and read results (non-blocking; avoids MCP timeouts)
1. Start the run:
   ```lua
   return game.ServerStorage.RehearseBridge.Start:Invoke({ filter = "Lobby" })  -- filter is optional
   ```
   This returns `"started"`.
2. Poll every few seconds until the status is `"done"` (allow about 15s per spec):
   ```lua
   return game.ServerStorage.RehearseBridge:GetAttribute("Status")
   ```
3. Read the report:
   ```lua
   return game.ServerStorage.RehearseBridge:GetAttribute("LastReport")
   ```

There's also a blocking variant, `RehearseBridge.Run:Invoke(opts)`, but it can exceed MCP call timeouts.

## Report shape
```json
{
  "ok": false, "passed": 1, "failed": 1, "errors": 0, "seconds": 11.5, "runId": "…",
  "specs": [{
    "spec": "Lobby", "players": 2, "status": "ran", "sessionSeconds": 11.5, "joinSeconds": 8.7,
    "error": null,
    "tests": [
      { "name": "…", "status": "pass", "ms": 748 },
      { "name": "…", "status": "fail", "ms": 34, "error": "expected: \"Waiting...\" to be \"Start\"", "logs": ["…"] }
    ]
  }]
}
```
- `ok` is true only when there are no failures and no errors.
- A spec with `status: "error"` never ran its tests. Read `error`, for example "timed out waiting for 2 client agent(s) to connect; players: …".

## Rules
- Don't call `start_stop_play` while a Rehearse run is active. Only one test session can run per Studio instance.
- A failing test is information. Fix the game code, or report a suspected bug. Never weaken an assertion just to make a test pass.
