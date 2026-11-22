-- Rehearse spec: text entry, key presses, walking, and client-side functions with one player.
return function(s)
	s.players(1)

	-- Runs inside the client, called with client:call("menuText").
	s.client("menuText", function()
		local gui = game:GetService("Players").LocalPlayer.PlayerGui.Menu
		return gui.Frame.PlayButton.Text
	end)

	s.test("typing a name and pressing Enter sets it on the server", function(t)
		local p = t.client(1)
		p:fill("PlayerGui.Menu.Frame.NameBox", "Ada", { submit = true })
		t.waitFor(function()
			return p.player:GetAttribute("DisplayName") == "Ada"
		end, 5, "DisplayName to be Ada")
	end)

	s.test("pressing E waves", function(t)
		local p = t.client(1)
		p:character()
		p:key("E")
		t.waitFor(function()
			return (p.player:GetAttribute("Waves") or 0) >= 1
		end, 5, "a wave")
	end)

	s.test("the character can walk to a point", function(t)
		local p = t.client(1)
		local start = p:character()
		local target = start + Vector3.new(12, 0, 0)
		local stopped = p:moveTo(target, 10)
		t.expect(((stopped - target) * Vector3.new(1, 0, 1)).Magnitude < 3).toBe(true)
	end)

	s.test("client functions run on the client", { isolated = true }, function(t)
		t.expect(t.client(1):call("menuText")).toBe("Play")
	end)
end
