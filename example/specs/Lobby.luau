-- Rehearse spec: runs inside a 2-player Studio test session.
return function(s)
	s.players(2)

	s.test("both players see the Play button", function(t)
		t.expect(t.client(1):waitFor("PlayerGui.Menu.Enabled", true)).toBe(true)
		t.expect(t.client(2):waitFor("PlayerGui.Menu.Frame.PlayButton.Visible", true)).toBe(true)
	end)

	s.test("match starts only after both players press Play", function(t)
		local p1, p2 = t.client(1), t.client(2)

		p1:click("PlayerGui.Menu.Frame.PlayButton")
		t.waitFor(function()
			return p1.player:GetAttribute("Ready")
		end, 5, "player 1 to be ready")
		t.expect(workspace:GetAttribute("MatchStarted")).toBe(false)

		p2:click("PlayerGui.Menu.Frame.PlayButton")
		t.waitFor(function()
			return workspace:GetAttribute("MatchStarted")
		end, 5, "the match to start")

		-- The menu hides on every client once the match starts.
		t.expect(p1:waitFor("PlayerGui.Menu.Enabled", false)).toBe(false)
		t.expect(p2:waitFor("PlayerGui.Menu.Enabled", false)).toBe(false)
	end)
end
