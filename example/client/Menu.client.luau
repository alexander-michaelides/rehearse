--!strict
-- Example game: a lobby menu with a Play button that hides once the match starts.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ready = ReplicatedStorage:WaitForChild("Ready") :: RemoteEvent

local gui = Instance.new("ScreenGui")
gui.Name = "Menu"
gui.ResetOnSpawn = false

local frame = Instance.new("Frame")
frame.Name = "Frame"
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.fromScale(0.5, 0.5)
frame.Size = UDim2.fromOffset(300, 160)
frame.Parent = gui

local button = Instance.new("TextButton")
button.Name = "PlayButton"
button.AnchorPoint = Vector2.new(0.5, 0.5)
button.Position = UDim2.fromScale(0.5, 0.5)
button.Size = UDim2.fromOffset(200, 60)
button.Text = "Play"
button.TextScaled = true
button.Parent = frame

button.Activated:Connect(function()
	button.Text = "Waiting..."
	button.Active = false
	ready:FireServer()
end)

local function sync()
	gui.Enabled = not workspace:GetAttribute("MatchStarted")
end
workspace:GetAttributeChangedSignal("MatchStarted"):Connect(sync)
sync()

gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
