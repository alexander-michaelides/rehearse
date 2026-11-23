-- Rehearse spec: players joining and leaving mid-session.
return function(s)
	s.players(2)

	s.test("the server tracks players leaving", function(t)
		t.waitFor(function()
			return workspace:GetAttribute("PlayerCount") == 2
		end, 5, "2 players")
		t.client(2):leave()
		t.waitFor(function()
			return workspace:GetAttribute("PlayerCount") == 1
		end, 5, "1 player after one left")
	end)

	-- Skipped by default: StudioTestService:AddPlayers can crash Studio's test server
	-- (https://devforum.roblox.com/t/4691976), and after a crash Studio may show a dialog that
	-- blocks every later launch until someone dismisses it. Run it with s.only to try it.
	s.skip("a player can join mid-session", { isolated = true }, function(t)
		local newcomer = t.addPlayers(1)
		t.expect(newcomer.index).toBe(3)
		t.expect(newcomer:waitFor("PlayerGui.Menu.Frame.PlayButton.Visible", true)).toBe(true)
		t.waitFor(function()
			return workspace:GetAttribute("PlayerCount") == 3
		end, 5, "3 players")
	end)
end
