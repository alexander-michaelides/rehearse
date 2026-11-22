--!strict
-- Example game: the match starts once every player in the server has pressed Play.
-- Players can also set a display name and wave (E).

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MIN_PLAYERS = 2

local function remote(name: string): RemoteEvent
	local r = Instance.new("RemoteEvent")
	r.Name = name
	r.Parent = ReplicatedStorage
	return r
end

local ready = remote("Ready")
local setName = remote("SetName")
local wave = remote("Wave")

workspace:SetAttribute("MatchStarted", false)
workspace:SetAttribute("PlayerCount", 0)

local function checkStart()
	local players = Players:GetPlayers()
	if #players < MIN_PLAYERS then
		return
	end
	for _, p in players do
		if not p:GetAttribute("Ready") then
			return
		end
	end
	workspace:SetAttribute("MatchStarted", true)
end

local function countPlayers()
	workspace:SetAttribute("PlayerCount", #Players:GetPlayers())
end

Players.PlayerAdded:Connect(countPlayers)
Players.PlayerRemoving:Connect(function()
	task.defer(countPlayers)
end)
countPlayers()

ready.OnServerEvent:Connect(function(player)
	player:SetAttribute("Ready", true)
	checkStart()
end)

setName.OnServerEvent:Connect(function(player, name: any)
	if type(name) ~= "string" then
		return
	end
	name = string.sub(string.gsub(name, "^%s+", ""), 1, 20)
	player:SetAttribute("DisplayName", if name == "" then nil else name)
end)

wave.OnServerEvent:Connect(function(player)
	player:SetAttribute("Waves", (player:GetAttribute("Waves") or 0) + 1)
end)
