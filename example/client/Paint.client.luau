--!strict
-- Example game: the Paintbrush tool. Clicking the canvas while it's equipped paints it.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local tool = script.Parent :: Tool
local mouse = Players.LocalPlayer:GetMouse()
local paint = ReplicatedStorage:WaitForChild("Paint") :: RemoteEvent

tool.Activated:Connect(function()
	if mouse.Target and mouse.Target.Name == "Canvas" then
		paint:FireServer(mouse.Hit.Position)
	end
end)
