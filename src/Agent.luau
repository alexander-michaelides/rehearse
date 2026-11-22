--!strict
-- Client DataModel of a test session: executes commands sent by the Runner.
-- Every action auto-waits for its target (Playwright-style) before acting.

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Agent = {}

local DEFAULT_TIMEOUT = 5

local virtualInput: any = nil

local function vi(): any
	if not virtualInput then
		virtualInput = (UserInputService :: any):CreateVirtualInput()
		if not virtualInput then
			error("VirtualInput is not available in this session", 0)
		end
	end
	return virtualInput
end

-- Paths are relative to the LocalPlayer ("PlayerGui.Menu.Play") unless they start
-- with "game." ("game.Workspace.Door"). The final segment may name a property
-- or an attribute ("@Coins") instead of a child.
local function resolve(path: string): (Instance?, string?)
	local parts = string.split(path, ".")
	local current: Instance
	local i = 1
	if parts[1] == "game" then
		current = game
		i = 2
	else
		current = Players.LocalPlayer
	end
	while i <= #parts do
		local part = parts[i]
		local child = current:FindFirstChild(part)
		if child then
			current = child
		elseif i == #parts then
			return current, part -- property or @attribute on `current`
		else
			return nil, nil
		end
		i += 1
	end
	return current, nil
end

local function readValue(path: string): (boolean, any)
	local inst, member = resolve(path)
	if not inst then
		return false, nil
	end
	if not member then
		return true, inst
	end
	if string.sub(member, 1, 1) == "@" then
		return true, inst:GetAttribute(string.sub(member, 2))
	end
	local ok, value = pcall(function()
		return (inst :: any)[member]
	end)
	if ok then
		return true, value
	end
	return false, nil
end

local function waitUntil(predicate: () -> any, timeout: number, what: string): any
	local deadline = os.clock() + timeout
	while true do
		local value = predicate()
		if value then
			return value
		end
		if os.clock() > deadline then
			error(`timed out after {timeout}s waiting for {what}`, 0)
		end
		RunService.Heartbeat:Wait()
	end
end

local function isOnScreen(obj: GuiObject): boolean
	if not obj.Visible or obj.AbsoluteSize.X <= 0 or obj.AbsoluteSize.Y <= 0 then
		return false
	end
	local p: Instance? = obj.Parent
	while p do
		if p:IsA("GuiObject") and not p.Visible then
			return false
		end
		if p:IsA("LayerCollector") then
			return (p :: any).Enabled ~= false
		end
		p = p.Parent
	end
	return false
end

local function screenPoint(obj: GuiObject): Vector2
	local center = obj.AbsolutePosition + obj.AbsoluteSize / 2
	local gui = obj:FindFirstAncestorWhichIsA("ScreenGui")
	if gui and not gui.IgnoreGuiInset then
		local inset = GuiService:GetGuiInset()
		center += inset
	end
	return center
end

local commands = {}

function commands.click(path: string, opts: any?): any
	local timeout = (opts and opts.timeout) or DEFAULT_TIMEOUT
	local obj = waitUntil(function()
		local inst = resolve(path)
		if inst and inst:IsA("GuiObject") and isOnScreen(inst) then
			return inst
		end
		return nil
	end, timeout, `{path} to be visible`)
	local pos = screenPoint(obj)
	local input = vi()
	input:SendMousePosition(pos)
	RunService.Heartbeat:Wait()
	input:SendMouseButton(pos, Enum.UserInputType.MouseButton1, true)
	RunService.Heartbeat:Wait()
	input:SendMouseButton(pos, Enum.UserInputType.MouseButton1, false)
	return { x = pos.X, y = pos.Y }
end

function commands.key(keyCode: string): any
	local code = (Enum.KeyCode :: any)[keyCode]
	assert(code, `unknown KeyCode {keyCode}`)
	local input = vi()
	input:SendKey(true, code, false)
	RunService.Heartbeat:Wait()
	input:SendKey(false, code, false)
	return nil
end

function commands.type(text: string): any
	vi():SendTextInput(text)
	return nil
end

function commands.get(path: string): any
	local ok, value = readValue(path)
	if not ok then
		error(`{path} not found`, 0)
	end
	return value
end

function commands.waitFor(path: string, expected: any?, timeout: number?): any
	return waitUntil(function()
		local ok, value = readValue(path)
		if not ok then
			return nil
		end
		if expected == nil then
			return value and { value = value }
		end
		return value == expected and { value = value }
	end, timeout or DEFAULT_TIMEOUT, if expected == nil then `{path}` else `{path} == {tostring(expected)}`).value
end

function Agent.start()
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
	local folder = ReplicatedStorage:WaitForChild("__Rehearse", 60)
	if not folder then
		return -- not a Rehearse session
	end
	local command = folder:WaitForChild("Command") :: RemoteFunction
	local ready = folder:WaitForChild("AgentReady") :: RemoteEvent
	local acknowledged = false
	command.OnClientInvoke = function(cmd: string, ...: any)
		if cmd == "ping" then
			acknowledged = true
			return { ok = true, value = "pong" }
		end
		local handler = commands[cmd]
		if not handler then
			return { ok = false, err = `unknown command {cmd}` }
		end
		local ok, value = pcall(handler, ...)
		if ok then
			return { ok = true, value = value }
		end
		return { ok = false, err = tostring(value) }
	end
	Players.LocalPlayer:WaitForChild("PlayerGui")
	-- Keep announcing until the server pings back, in case an early event is missed.
	while not acknowledged do
		ready:FireServer()
		task.wait(1)
	end
end

return Agent
