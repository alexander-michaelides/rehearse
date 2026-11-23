--!strict
-- Example game: a coin to collect, a shop (ProximityPrompt) that sells a Sword, and a canvas to paint.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Anchored = true
	for k, v in props do
		(p :: any)[k] = v
	end
	p.Parent = workspace
	return p
end

Players.PlayerAdded:Connect(function(player)
	local stats = Instance.new("Folder")
	stats.Name = "leaderstats"
	local coins = Instance.new("IntValue")
	coins.Name = "Coins"
	coins.Parent = stats
	stats.Parent = player
end)

-- Coin: touching it gives 1 coin, then it respawns after 2 seconds.
local coin = part({
	Name = "Coin",
	Shape = Enum.PartType.Ball,
	Size = Vector3.new(2, 2, 2),
	Position = Vector3.new(16, 2, 0),
	CanCollide = false,
	BrickColor = BrickColor.new("Bright yellow"),
})
local collected = false
coin.Touched:Connect(function(hit)
	local player = Players:GetPlayerFromCharacter(hit.Parent)
	if not player or collected then
		return
	end
	collected = true
	local coins = player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Coins") :: IntValue?
	if coins then
		coins.Value += 1
	end
	coin.Transparency = 1
	task.delay(2, function()
		coin.Transparency = 0
		collected = false
	end)
end)

-- Shop: hold E for half a second to buy a Sword for 1 coin.
local shop = part({ Name = "Shop", Size = Vector3.new(4, 4, 4), Position = Vector3.new(-16, 2, 0) })
local prompt = Instance.new("ProximityPrompt")
prompt.Name = "BuySword"
prompt.ActionText = "Buy Sword"
prompt.ObjectText = "1 coin"
prompt.HoldDuration = 0.5
prompt.MaxActivationDistance = 10
prompt.Parent = shop

local function makeSword(): Tool
	local tool = Instance.new("Tool")
	tool.Name = "Sword"
	local handle = Instance.new("Part")
	handle.Name = "Handle"
	handle.Size = Vector3.new(0.4, 4, 0.4)
	handle.Parent = tool
	return tool
end

prompt.Triggered:Connect(function(player)
	local coins = player:FindFirstChild("leaderstats") and player.leaderstats:FindFirstChild("Coins") :: IntValue?
	if not coins or coins.Value < 1 then
		return
	end
	coins.Value -= 1
	local sword = makeSword()
	sword.Activated:Connect(function()
		player:SetAttribute("Swings", (player:GetAttribute("Swings") or 0) + 1)
	end)
	sword.Parent = player:FindFirstChildOfClass("Backpack")
end)

-- Canvas: the Paintbrush tool (StarterPack) paints wherever the player clicks on it.
local canvas = part({ Name = "Canvas", Size = Vector3.new(40, 16, 1), Position = Vector3.new(0, 8, -40) })
local paint = Instance.new("RemoteEvent")
paint.Name = "Paint"
paint.Parent = ReplicatedStorage
paint.OnServerEvent:Connect(function(player, where: any)
	if typeof(where) == "Vector3" then
		canvas:SetAttribute("Painted", true)
		canvas:SetAttribute("PaintedBy", player.Name)
	end
end)
