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

-- Like resolve, but only succeeds when the whole path names an instance
-- (so "Menu.Frame.Missing" doesn't fall back to Frame and a property called "Missing").
local function resolveInstance(path: string): Instance?
	local inst, member = resolve(path)
	if member then
		return nil
	end
	return inst
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
		local inst = resolveInstance(path)
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
	local inst = resolveInstance(path)
	return inst ~= nil and inst:IsA("GuiObject") and isRendered(inst)
end

function commands.isInViewport(path: string): any
	local inst = resolveInstance(path)
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

-- Tools ---------------------------------------------------------------------------------

local function findTool(name: string, timeout: number): Tool
	local player = Players.LocalPlayer
	return waitUntil(function()
		local char = player.Character
		local inChar = char and char:FindFirstChild(name)
		if inChar and inChar:IsA("Tool") then
			return inChar
		end
		local backpack = player:FindFirstChildOfClass("Backpack")
		local inPack = backpack and backpack:FindFirstChild(name)
		if inPack and inPack:IsA("Tool") then
			return inPack
		end
		return nil
	end, timeout, `a Tool named "{name}" in the Backpack or character`)
end

local function equippedTool(): Tool?
	local char = Players.LocalPlayer.Character
	return char and char:FindFirstChildOfClass("Tool")
end

function commands.equip(name: string, opts: any?): any
	local timeout = (opts and opts.timeout) or DEFAULT_TIMEOUT
	local tool = findTool(name, timeout)
	local pair = localHumanoid(timeout) :: any
	local hum: Humanoid = pair[2]
	if tool.Parent ~= pair[1] then
		hum:EquipTool(tool)
	end
	waitUntil(function()
		return tool.Parent == Players.LocalPlayer.Character
	end, timeout, `"{name}" to be equipped`)
	return tool.Name
end

function commands.unequip(): any
	local pair = localHumanoid(DEFAULT_TIMEOUT) :: any
	(pair[2] :: Humanoid):UnequipTools()
	waitUntil(function()
		return equippedTool() == nil
	end, DEFAULT_TIMEOUT, "tools to be unequipped")
	return nil
end

-- Activates the equipped tool (Tool:Activate fires Activated on the client and server).
-- For tools that read the mouse, use clickWorld instead.
function commands.activate(opts: any?): any
	local tool = equippedTool()
	if not tool and opts and opts.tool then
		commands.equip(opts.tool)
		tool = equippedTool()
	end
	if not tool then
		error("no tool is equipped; call equip(name) first", 0)
	end
	tool:Activate()
	frame()
	task.wait((opts and opts.hold) or 0)
	tool:Deactivate()
	frame()
	return tool.Name
end

-- World input --------------------------------------------------------------------------

local function worldPoint(target: any, timeout: number): Vector3
	if typeof(target) == "Vector3" then
		return target
	end
	if type(target) ~= "string" then
		error("target must be a Vector3 or a path to a BasePart or Model", 0)
	end
	local inst = waitUntil(function()
		local i = resolveInstance(target)
		if i and (i:IsA("BasePart") or i:IsA("Model") or i:IsA("Attachment")) then
			return i
		end
		return nil
	end, timeout, `{target} to exist`)
	if inst:IsA("BasePart") then
		return inst.Position
	elseif inst:IsA("Attachment") then
		return inst.WorldPosition
	end
	return (inst :: Model):GetPivot().Position
end

-- Clicks the point on screen where a world position (or a part) is drawn.
function commands.clickWorld(target: any, opts: any?): any
	local timeout = (opts and opts.timeout) or DEFAULT_TIMEOUT
	local point = worldPoint(target, timeout)
	local camera = workspace.CurrentCamera
	local screen, onScreen
	waitUntil(function()
		local p, visible = camera:WorldToViewportPoint(point)
		screen, onScreen = p, visible
		return visible and p.Z > 0
	end, timeout, `{if type(target) == "string" then target else tostring(point)} to be on screen`)
	local pos = Vector2.new(screen.X, screen.Y)
	local button = BUTTONS[(opts and opts.button) or "left"]
	local input = vi()
	input:SendMousePosition(pos)
	frame()
	frame()
	input:SendMouseButton(pos, button, true)
	frame()
	input:SendMouseButton(pos, button, false)
	frame()
	return { x = pos.X, y = pos.Y, onScreen = onScreen }
end

local shownPrompts: { [ProximityPrompt]: boolean } = {}
do
	local pps = game:GetService("ProximityPromptService")
	pps.PromptShown:Connect(function(p)
		shownPrompts[p] = true
	end)
	pps.PromptHidden:Connect(function(p)
		shownPrompts[p] = nil
	end)
end

-- Triggers a ProximityPrompt like a player would: walk into range if needed, hold for HoldDuration.
function commands.prompt(path: string, opts: any?): any
	local timeout = (opts and opts.timeout) or 10
	local prompt = waitUntil(function()
		local i = resolveInstance(path)
		if i and i:IsA("ProximityPrompt") then
			return i
		end
		return nil
	end, timeout, `a ProximityPrompt at {path}`) :: ProximityPrompt
	if not prompt.Enabled then
		error(`{path} is disabled`, 0)
	end
	local parent = prompt.Parent
	local where = if parent and parent:IsA("BasePart")
		then parent.Position
		elseif parent and parent:IsA("Attachment") then parent.WorldPosition
		elseif parent and parent:IsA("Model") then parent:GetPivot().Position
		else nil
	if not where then
		error(`{path} is not under a BasePart, Attachment or Model`, 0)
	end
	local pair = localHumanoid(timeout) :: any
	local root = pair[1].HumanoidRootPart :: BasePart
	local range = prompt.MaxActivationDistance
	local function distance(): number
		return (root.Position - where).Magnitude
	end
	local function approach(fraction: number)
		local toward = (root.Position - where) * Vector3.new(1, 0, 1)
		local stop = where
			+ (if toward.Magnitude > 0 then toward.Unit else Vector3.xAxis) * math.max(2, range * fraction)
		commands.moveTo(Vector3.new(stop.X, root.Position.Y, stop.Z), timeout)
		-- Come to rest so the prompt doesn't flicker in and out of range mid-hold.
		local restDeadline = os.clock() + 1
		while root.AssemblyLinearVelocity.Magnitude > 1 and os.clock() < restDeadline do
			frame()
		end
	end
	if distance() > range - 1 then
		if opts and opts.walk == false then
			error(`{path} is {math.floor(distance())} studs away (range {range}); pass walk = true or moveTo first`, 0)
		end
		approach(0.5)
	end

	local key = prompt.KeyboardKeyCode
	local input = vi()
	local triggered = false
	local conn = prompt.Triggered:Connect(function()
		triggered = true
	end)
	local function holdUntilTriggered(begin: () -> (), finish: () -> (), slack: number)
		begin()
		local deadline = os.clock() + prompt.HoldDuration + slack
		while not triggered and os.clock() < deadline do
			frame()
		end
		finish()
		frame()
	end

	local attempts = {}
	local method = "key"
	for attempt = 1, 3 do
		local okShown = pcall(waitUntil, function()
			return shownPrompts[prompt]
		end, 2, `{path} to be shown`)
		if not okShown then
			table.insert(attempts, `#{attempt}: not shown at {math.floor(distance())} studs`)
			approach(0.3) -- closer, in case line of sight or the range edge is the problem
			continue
		end
		if attempt == 1 then
			-- The way a player does it: hold the prompt's key.
			holdUntilTriggered(function()
				input:SendKey(true, key, false)
			end, function()
				input:SendKey(false, key, false)
			end, 0.5)
			method = "key"
		end
		if not triggered then
			-- Test clients' windows are usually unfocused, which can cancel held keys;
			-- the prompt's own hold API (what custom prompt UIs call) doesn't depend on focus.
			holdUntilTriggered(function()
				prompt:InputHoldBegin()
			end, function()
				prompt:InputHoldEnd()
			end, 2)
			method = "InputHoldBegin"
		end
		if triggered then
			break
		end
		table.insert(attempts, `#{attempt}: shown but the hold didn't trigger`)
		task.wait(0.3)
	end
	conn:Disconnect()
	if not triggered then
		error(`{path} never triggered ({table.concat(attempts, "; ")})`, 0)
	end
	return { action = prompt.ActionText, method = method, attempts = #attempts + 1 }
end

-- Diagnostics --------------------------------------------------------------------------

local logBuffer: { { t: number, kind: string, message: string } } = {}

local function relPath(inst: Instance): string
	local parts = {}
	local cur: Instance? = inst
	local lp = Players.LocalPlayer
	while cur and cur ~= lp and cur ~= game do
		table.insert(parts, 1, cur.Name)
		cur = cur.Parent
	end
	if cur == game then
		return "game." .. table.concat(parts, ".")
	end
	return table.concat(parts, ".")
end

-- Returns (and clears) client errors and warnings logged since the last drain.
function commands.drainLogs(): any
	local out = logBuffer
	logBuffer = {}
	return out
end

-- What the player can see right now, for failure reports. Capped to keep reports small.
function commands.snapshot(): any
	local lp = Players.LocalPlayer
	local gui = lp:FindFirstChildOfClass("PlayerGui")
	local visible = {}
	local total = 0
	if gui then
		for _, d in gui:GetDescendants() do
			if d:IsA("GuiObject") and isRendered(d) then
				local text = if d:IsA("TextLabel")
						or d:IsA("TextButton")
						or d:IsA("TextBox")
					then (d :: any).Text
					else nil
				if d:IsA("GuiButton") or d:IsA("TextBox") or (type(text) == "string" and text ~= "") then
					total += 1
					if #visible < 40 then
						local a = d.AbsolutePosition + insetFor(d)
						table.insert(visible, {
							path = relPath(d),
							class = d.ClassName,
							text = if type(text) == "string" and text ~= "" then string.sub(text, 1, 80) else nil,
							rect = {
								math.floor(a.X),
								math.floor(a.Y),
								math.floor(d.AbsoluteSize.X),
								math.floor(d.AbsoluteSize.Y),
							},
						})
					end
				end
			end
		end
	end
	local char = lp.Character
	local root = char and char:FindFirstChild("HumanoidRootPart") :: BasePart?
	local hum = char and char:FindFirstChildOfClass("Humanoid")
	local tool = equippedTool()
	local camera = workspace.CurrentCamera
	return {
		viewport = camera and { math.floor(camera.ViewportSize.X), math.floor(camera.ViewportSize.Y) },
		position = root and { math.floor(root.Position.X), math.floor(root.Position.Y), math.floor(root.Position.Z) },
		health = hum and hum.Health,
		tool = tool and tool.Name,
		focused = (function()
			local f = UserInputService:GetFocusedTextBox()
			return f and relPath(f)
		end)(),
		visible = visible,
		hidden = if total > #visible then total - #visible else nil,
	}
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
	game:GetService("LogService").MessageOut:Connect(function(message, messageType)
		if messageType == Enum.MessageType.MessageError or messageType == Enum.MessageType.MessageWarning then
			if #logBuffer < 200 then
				table.insert(logBuffer, {
					t = os.clock(),
					kind = if messageType == Enum.MessageType.MessageError then "error" else "warning",
					message = string.sub(message, 1, 500),
				})
			end
		end
	end)
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
