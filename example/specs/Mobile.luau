-- Rehearse spec: the menu fits on small phones and tablets.
return function(s)
	s.players(1)
	s.devices({ "iphone_7", { id = "ipad_a16", orientation = "Portrait" } })

	s.test("Play button is fully on screen", function(t)
		local p = t.client(1)
		p:waitFor("PlayerGui.Menu.Frame.PlayButton.Visible", true)
		t.log("device", t.device.id, "viewport", p:get("game.Workspace.CurrentCamera.ViewportSize"))
		t.expect(p:isInViewport("PlayerGui.Menu.Frame.PlayButton")).toBe(true)
		t.expect(p:isInViewport("PlayerGui.Menu.Frame.NameBox")).toBe(true)
	end)
end
