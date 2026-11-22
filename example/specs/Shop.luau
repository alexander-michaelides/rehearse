-- Rehearse spec: coins, a ProximityPrompt shop, tools, world clicks and script errors.
return function(s)
	s.players(1)

	s.beforeEach(function(t)
		-- Hide the lobby menu so world clicks aren't blocked by UI.
		workspace:SetAttribute("MatchStarted", true)
		t.client(1):character()
	end)

	s.test("collect a coin, buy a sword at the shop, and swing it", function(t)
		local p = t.client(1)
		local coins = p.player:WaitForChild("leaderstats"):WaitForChild("Coins")

		p:moveTo(workspace.Coin.Position)
		t.waitFor(function()
			return coins.Value == 1
		end, 5, "the coin to be collected")

		p:prompt("game.Workspace.Shop.BuySword")
		t.waitFor(function()
			return p.player.Backpack:FindFirstChild("Sword") ~= nil
		end, 5, "a Sword in the Backpack")
		t.expect(coins.Value).toBe(0)

		p:equip("Sword")
		p:activate()
		t.waitFor(function()
			return (p.player:GetAttribute("Swings") or 0) == 1
		end, 5, "one swing")
	end)

	s.test("paint the canvas by clicking it", function(t)
		local p = t.client(1)
		p:equip("Paintbrush")
		p:clickWorld("game.Workspace.Canvas")
		t.waitFor(function()
			return workspace.Canvas:GetAttribute("PaintedBy") == p.player.Name
		end, 5, "the canvas to be painted")
	end)

	s.test("script errors in the game are captured", function(t)
		t.client(1):key("Q")
		local errors = t.gameErrors()
		t.expect(#errors).toBe(1)
		t.expect(errors[1]).toContain("Q is not implemented yet")
	end)
end
