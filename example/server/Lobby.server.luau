--!strict
-- Example game: the match starts once every player in the server has pressed Play.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local MIN_PLAYERS = 2

local ready = Instance.new("RemoteEvent")
ready.Name = "Ready"
ready.Parent = ReplicatedStorage

workspace:SetAttribute("MatchStarted", false)

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

ready.OnServerEvent:Connect(function(player)
	player:SetAttribute("Ready", true)
	checkStart()
end)
