--!strict
--[=[
	@class Agent

	Client DataModel of a test session: executes commands sent by the Runner.
	Every action auto-waits for its target (Playwright-style) before acting.
]=]

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

local function frame()
	RunService.Heartbeat:Wait()
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
		local child: Instance? = if string.sub(part, 1, 1) == "@" then nil else current:FindFirstChild(part)
		if not child and i < #parts and string.sub(part, 1, 1) ~= "@" then
			-- Instance-valued properties in the middle of a path, e.g. Workspace.CurrentCamera.
			local ok, value = pcall(function()
				return (current :: any)[part]
			end)
			if ok and typeof(value) == "Instance" then
				child = value
			end
		end
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
		frame()
	end
end

-- Rendered: Visible all the way up, inside an enabled LayerCollector under PlayerGui.
local function isRendered(obj: GuiObject): boolean
	if not obj.Visible or obj.AbsoluteSize.X <= 0 or obj.AbsoluteSize.Y <= 0 then
		return false
	end
	local p: Instance? = obj.Parent
	while p do
		if p:IsA("GuiObject") and not p.Visible then
			return false
		end
		if p:IsA("LayerCollector") then
			return (p :: any).Enabled ~= false and p:IsDescendantOf(Players.LocalPlayer)
		end
		p = p.Parent
	end
	return false
end

local function insetFor(obj: GuiObject): Vector2
	local gui = obj:FindFirstAncestorWhichIsA("ScreenGui")
	if gui and not gui.IgnoreGuiInset then
		local inset = GuiService:GetGuiInset()
		return inset
	end
	return Vector2.zero
end

local function screenRect(obj: GuiObject): (Vector2, Vector2)
	local topLeft = obj.AbsolutePosition + insetFor(obj)
	return topLeft, topLeft + obj.AbsoluteSize
end

local function inViewport(obj: GuiObject): boolean
	local camera = workspace.CurrentCamera
	if not camera then
		return false
	end
	local size = camera.ViewportSize
	local a, b = screenRect(obj)
	return a.X >= 0 and a.Y >= 0 and b.X <= size.X + 0.5 and b.Y <= size.Y + 0.5
end

local function guiAt(path: string, timeout: number, requireInteractable: boolean): GuiObject
	return waitUntil(function()
		local inst = resolve(path)
		if inst and inst:IsA("GuiObject") and isRendered(inst) then
			if requireInteractable and inst:IsA("GuiButton") and not inst.Active then
				return nil
			end
			return inst
		end
		return nil
	end, timeout, `{path} to be visible`)
end

local BUTTONS = {
	left = Enum.UserInputType.MouseButton1,
	right = Enum.UserInputType.MouseButton2,
	middle = Enum.UserInputType.MouseButton3,
}

local function keyCodeOf(name: string): Enum.KeyCode
	local ok, code = pcall(function()
		return (Enum.KeyCode :: any)[name]
	end)
	if not ok or not code then
		error(`unknown KeyCode "{name}"`, 0)
	end
	return code
end

local function localHumanoid(timeout: number): (Model, Humanoid)
	return waitUntil(function()
		local char = Players.LocalPlayer.Character
		local hum = char and char:FindFirstChildOfClass("Humanoid")
		if char and hum and hum.Health > 0 and char:FindFirstChild("HumanoidRootPart") then
			return { char, hum }
		end
		return nil
	end, timeout, "the character to spawn") :: any
end

local clientFns: { [string]: (...any) -> ...any }? = nil

local function loadClientFns(folder: Instance): { [string]: (...any) -> ...any }
	if clientFns then
		return clientFns
	end
	local module = folder:FindFirstChild("Spec")
	if not module or not module:IsA("ModuleScript") then
		error("spec module was not shipped to the client", 0)
	end
	local ok, specFn = pcall(require, module)
	if not ok then
		error(`could not load the spec on the client (client functions must only use client-safe code): {specFn}`, 0)
	end
	local fns = {}
	local noop = function() end
	local api = setmetatable({
		client = function(name: string, fn: any)
			fns[name] = fn
		end,
	}, {
		__index = function()
			return noop -- every other declaration is irrelevant on the client
		end,
	})
	specFn(api)
	clientFns = fns
	return fns
end

local commands: { [string]: (...any) -> any } = {}

function commands.click(path: string, opts: any?): any
	local timeout = (opts and opts.timeout) or DEFAULT_TIMEOUT
	local button = BUTTONS[(opts and opts.button) or "left"]
	assert(button, "button must be left, right or middle")
	local obj = guiAt(path, timeout, true)
	local a, b = screenRect(obj)
	local pos = (a + b) / 2
	if opts and opts.offset then
		pos = a + opts.offset
	end
	local input = vi()
	input:SendMousePosition(pos)
	frame()
	input:SendMouseButton(pos, button, true)
	frame()
	input:SendMouseButton(pos, button, false)
	frame()
	return { x = pos.X, y = pos.Y }
end

-- Press a key, or hold it: key("W", { hold = 1.5 }).
function commands.key(keyName: string, opts: any?): any
	local code = keyCodeOf(keyName)
	local input = vi()
	input:SendKey(true, code, false)
	local hold = opts and opts.hold
	if hold and hold > 0 then
		task.wait(hold)
	else
		frame()
	end
	input:SendKey(false, code, false)
	frame()
	return nil
end

-- Text into whatever has focus (usually after clicking a TextBox).
function commands.type(text: string): any
	vi():SendTextInput(text)
	frame()
	return nil
end

-- Focus a TextBox, replace its text, and optionally press Enter: fill(path, "hi", { submit = true }).
function commands.fill(path: string, text: string, opts: any?): any
	local timeout = (opts and opts.timeout) or DEFAULT_TIMEOUT
	local box = guiAt(path, timeout, false)
	if not box:IsA("TextBox") then
		error(`{path} is a {box.ClassName}, not a TextBox`, 0)
	end
	if not box:IsFocused() then
		-- Focus it the way a player would; fall back to CaptureFocus if the click didn't land.
		commands.click(path, { timeout = timeout })
		local deadline = os.clock() + 1
		while not box:IsFocused() and os.clock() < deadline do
			frame()
		end
		if not box:IsFocused() then
			box:CaptureFocus()
		end
	end
	waitUntil(function()
		return box:IsFocused()
	end, timeout, `{path} to take focus`)
	box.Text = ""
	frame()
	vi():SendTextInput(text)
	waitUntil(function()
		return box.Text == text
	end, timeout, `{path} to contain "{text}" (it has "{box.Text}")`)
	if opts and opts.submit then
		commands.key("Return")
		waitUntil(function()
			return not box:IsFocused()
		end, timeout, `{path} to submit on Enter`)
	end
	return box.Text
end

function commands.get(path: string): any
	local ok, value = readValue(path)
	if not ok then
		error(`{path} not found`, 0)
	end
	return value
end

function commands.exists(path: string): any
	local ok = readValue(path)
	return ok
end

function commands.isVisible(path: string): any
	local inst = resolve(path)
	return inst ~= nil and inst:IsA("GuiObject") and isRendered(inst)
end

function commands.isInViewport(path: string): any
	local inst = resolve(path)
	return inst ~= nil and inst:IsA("GuiObject") and isRendered(inst) and inViewport(inst)
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

-- Waits for a living character; returns the root position.
function commands.character(timeout: number?): any
	local char = localHumanoid(timeout or 15)
	return ((char :: any)[1].HumanoidRootPart :: BasePart).Position
end

-- Walks the local character to a point; returns where it ended up.
function commands.moveTo(target: Vector3, timeout: number?): any
	local pair = localHumanoid(15) :: any
	local hum: Humanoid = pair[2]
	local root = pair[1].HumanoidRootPart :: BasePart
	local limit = timeout or 10
	local deadline = os.clock() + limit
	local reached = false
	local conn = hum.MoveToFinished:Connect(function(r)
		reached = r
	end)
	-- Humanoid:MoveTo gives up after 8s, so re-issue it until we arrive or time out.
	while os.clock() < deadline do
		hum:MoveTo(target)
		local issued = os.clock()
		while os.clock() - issued < 7 and os.clock() < deadline and not reached do
			local flat = Vector3.new(root.Position.X - target.X, 0, root.Position.Z - target.Z)
			if flat.Magnitude < 2 then
				reached = true
			end
			frame()
		end
		if reached then
			break
		end
	end
	conn:Disconnect()
	if not reached then
		error(`timed out after {limit}s walking to {target}; stopped at {root.Position}`, 0)
	end
	return root.Position
end

local currentFolder: Instance? = nil

function commands.call(fnName: string, ...: any): any
	local fns = loadClientFns(currentFolder :: Instance)
	local fn = fns[fnName]
	if not fn then
		error(`no client function "{fnName}" declared with s.client()`, 0)
	end
	return fn(...)
end

function commands.leave(): any
	local StudioTestService = game:GetService("StudioTestService")
	if not StudioTestService:CanLeaveTest() then
		error("this client cannot leave the test right now", 0)
	end
	task.delay(0.1, function()
		StudioTestService:LeaveTest()
	end)
	return true
end

local function applyDevice(folder: Instance): string?
	local deviceId = folder:GetAttribute("Device")
	if type(deviceId) ~= "string" then
		return nil
	end
	local ok, err = pcall(function()
		local sim = game:GetService("StudioDeviceSimulatorService") :: any
		sim:SetDeviceAsync(deviceId)
		local orientation = folder:GetAttribute("Orientation")
		if type(orientation) == "string" then
			sim:SetOrientationAsync((Enum.ScreenOrientation :: any)[orientation])
		end
	end)
	if not ok then
		return `could not simulate device "{deviceId}": {err}`
	end
	-- Let the viewport and GUI layout settle at the new size.
	local camera = workspace.CurrentCamera
	local last = camera and camera.ViewportSize
	for _ = 1, 30 do
		frame()
		local size = camera and camera.ViewportSize
		if size == last then
			break
		end
		last = size
	end
	task.wait(0.2)
	return nil
end

function Agent.start()
	if not game:IsLoaded() then
		game.Loaded:Wait()
	end
	local folder = ReplicatedStorage:WaitForChild("__Rehearse", 60)
	if not folder then
		return -- not a Rehearse session
	end
	currentFolder = folder
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
	local setupError = applyDevice(folder)
	-- Keep announcing until the server pings back, in case an early event is missed.
	while not acknowledged do
		ready:FireServer(setupError)
		task.wait(1)
	end
end

return Agent
