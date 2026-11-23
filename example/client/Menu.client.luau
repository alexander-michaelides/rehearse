--!strict
-- Example game: a lobby menu with a name box and a Play button that hides once the match starts.

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local UserInputService = game:GetService("UserInputService")

local ready = ReplicatedStorage:WaitForChild("Ready") :: RemoteEvent
local setName = ReplicatedStorage:WaitForChild("SetName") :: RemoteEvent
local wave = ReplicatedStorage:WaitForChild("Wave") :: RemoteEvent

local gui = Instance.new("ScreenGui")
gui.Name = "Menu"
gui.ResetOnSpawn = false

local frame = Instance.new("Frame")
frame.Name = "Frame"
frame.AnchorPoint = Vector2.new(0.5, 0.5)
frame.Position = UDim2.fromScale(0.5, 0.5)
frame.Size = UDim2.fromOffset(300, 200)
frame.Parent = gui

local nameBox = Instance.new("TextBox")
nameBox.Name = "NameBox"
nameBox.AnchorPoint = Vector2.new(0.5, 0)
nameBox.Position = UDim2.new(0.5, 0, 0, 20)
nameBox.Size = UDim2.fromOffset(200, 40)
nameBox.PlaceholderText = "Your name"
nameBox.Text = ""
nameBox.ClearTextOnFocus = false
nameBox.Parent = frame

local button = Instance.new("TextButton")
button.Name = "PlayButton"
button.AnchorPoint = Vector2.new(0.5, 1)
button.Position = UDim2.new(0.5, 0, 1, -20)
button.Size = UDim2.fromOffset(200, 60)
button.Text = "Play"
button.TextScaled = true
button.Parent = frame

nameBox.FocusLost:Connect(function(enterPressed)
	if enterPressed then
		setName:FireServer(nameBox.Text)
	end
end)

button.Activated:Connect(function()
	button.Text = "Waiting..."
	button.Active = false
	ready:FireServer()
end)

UserInputService.InputBegan:Connect(function(input, processed)
	if not processed and input.KeyCode == Enum.KeyCode.E then
		wave:FireServer()
	end
	if not processed and input.KeyCode == Enum.KeyCode.Q then
		error("Q is not implemented yet") -- a deliberate bug, caught by the Shop spec
	end
end)

local function sync()
	gui.Enabled = not workspace:GetAttribute("MatchStarted")
end
workspace:GetAttributeChangedSignal("MatchStarted"):Connect(sync)
sync()

gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
