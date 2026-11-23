# Recording the agent demo: "Claude Code finds and fixes a multiplayer bug with Rehearse"

**Project:** `~/Coding/lobby-game` (its own git repo, outside this workspace).

**The bug (seeded on purpose):** if a player presses Play and then leaves, the match starts for everyone else, even though they never pressed Play. The server counts ready players but never un-counts one who leaves (`src/server/Lobby.server.luau`). The existing specs pass, because none of them covers leaving.

**What the viewer sees:**
1. A bug report goes in.
2. Claude Code writes a 2-player test, runs it, and two real client windows open. Player 1 presses Play and leaves, and player 2's menu disappears.
3. The test fails with `MatchStarted: expected: true to be false`.
4. Claude fixes the server script, reruns, and gets green, then runs the whole suite.

Dry-run on 2026-11-22: the reproduction failed for the right reason, and after the fix 3 of 3 passed (24s).

## Before recording

1. Close other Studio windows you don't need. Fewer windows makes it faster and avoids stray dialogs. Make sure Studio is signed in and no dialog is open.
2. The plugin must be current: `cd ~/Coding/agentic-rblx-tooling/tools/rehearse && rojo build -o ~/Documents/Roblox/Plugins/Rehearse.rbxm`.
3. Warm-up run, which also shows you where the windows appear:
   ```bash
   cd ~/Coding/lobby-game && ./test
   ```
   You should get `Rehearse PASSED: 2 passed` in about 25s. While it runs you'll see a Studio window and two small client windows. Arrange your screen so Claude Code is on the left and the area where those windows open is on the right.
4. Open Claude Code in `~/Coding/lobby-game`, either the desktop app or `claude` in a terminal. `.claude/settings.json` pre-allows `./test` and edits to `src/` and `specs/`, so there are no permission prompts mid-take.

## Recording

1. Start a screen recording (Cmd+Shift+5, "Record Selected Portion" covering both halves).
2. Paste this prompt:

   > Players report: "if someone presses Play in the lobby and then leaves, the match starts for everyone else even though we never pressed Play." Reproduce it with a Rehearse test first, then fix it, and show me the suite passing.

3. Let it run. Expect about 3 test runs at roughly 20–25s each (red, green, full suite), so 1.5–3 minutes in total.
4. Stop the recording. In the edit, speed up the waiting parts (4–8x) and keep these moments at normal speed:
   - the red result
   - the diff of the fix
   - the green result

   A 30–45s cut is the goal.

## Retakes

Reset the project to the buggy state:
```bash
cd ~/Coding/lobby-game && git reset --hard && git clean -fd
```

## If it goes off-script

- **Claude fixes the code without writing a test first:** `CLAUDE.md` tells it to reproduce first, but you can add "write the failing test before touching the code" to the prompt.
- **The test passes on the buggy code:** the test probably checks right after `leave()` without waiting. Ask it to wait about a second after the player leaves. The dry-run test used `t.wait(1)`.
- **`./test` exits with code 2 and "Studio didn't start":** a Studio dialog is open somewhere. Dismiss it and retake.
- **Your avatar and name don't appear:** this demo uses multiplayer sessions, so the players are Player1 and Player2, not your account.
