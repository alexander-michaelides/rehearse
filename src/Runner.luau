--!strict
--[=[
	@class Runner

	Server DataModel of a test session: waits for client agents, runs the planned
	tests of one spec, and reports back to the Launcher through StudioTestService:EndTest.
]=]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StudioTestService = game:GetService("StudioTestService")

local Spec = require(script.Parent.Spec)
local Expect = require(script.Parent.Expect)

local Runner = {}

local CLIENT_JOIN_TIMEOUT = 30 -- normal joins take 6–10s
local TOP_UP_AFTER = 15 -- replace clients that still haven't appeared after this long

local function resolveFullName(fullName: string): Instance?
	local current: Instance? = game
	for _, part in string.split(fullName, ".") do
		current = current and current:FindFirstChild(part)
	end
	return current
end

local function waitFor(predicate: () -> any, timeout: number?, what: string?): any
	local limit = timeout or 5
	local deadline = os.clock() + limit
	while true do
		local ok, value = pcall(predicate)
		if ok and value then
			return value
		end
		if os.clock() > deadline then
			error(
				`timed out after {limit}s waiting for {what or "condition"}`
					.. (if not ok then ` (last error: {value})` else ""),
				0
			)
		end
		RunService.Heartbeat:Wait()
	end
end

local function makeChannel(args: { [string]: any }, specModule: ModuleScript): (RemoteFunction, RemoteEvent)
	local folder = Instance.new("Folder")
	folder.Name = "__Rehearse"
	if args.device then
		folder:SetAttribute("Device", args.device.id)
		folder:SetAttribute("Orientation", args.device.orientation)
	end
	local fn = Instance.new("RemoteFunction")
	fn.Name = "Command"
	fn.Parent = folder
	local ready = Instance.new("RemoteEvent")
	ready.Name = "AgentReady"
	ready.Parent = folder
	-- Clients can't see ServerStorage, so ship a copy of the spec for client:call().
	local specCopy = specModule:Clone()
	specCopy.Name = "Spec"
	specCopy.Parent = folder
	folder.Parent = ReplicatedStorage
	return fn, ready
end

local function fmtArgs(...: any): string
	local parts = {}
	for i = 1, select("#", ...) do
		local v = select(i, ...)
		parts[i] = if type(v) == "string" then string.format("%q", v) else tostring(v)
	end
	return table.concat(parts, ", ")
end

local function run(args: { [string]: any }): { [string]: any }
	local module = resolveFullName(args.spec)
	if not module or not module:IsA("ModuleScript") then
		return { status = "error", error = "spec module not found in test session", tests = {} }
	end
	local decl = Spec.load(module, true)

	local command, agentReady = makeChannel(args, module)
	local readyPlayers: { [Player]: boolean } = {}
	local agentErrors: { [Player]: string } = {}
	local pinging: { [Player]: boolean } = {}
	agentReady.OnServerEvent:Connect(function(player, setupError: any)
		if type(setupError) == "string" then
			agentErrors[player] = setupError
		end
		if readyPlayers[player] or pinging[player] then
			return
		end
		pinging[player] = true
		local ok, res = pcall(command.InvokeClient, command, player, "ping")
		pinging[player] = nil
		if ok and type(res) == "table" and res.ok then
			readyPlayers[player] = true
		end
	end)

	local ordered: { Player } = {}
	local left: { [Player]: boolean } = {}

	-- Waits until `count` agents beyond those already in `ordered` are listening, then appends them in join order.
	local toppedUp = 0

	-- Waits until `count` agents beyond those already in `ordered` are listening, then appends
	-- them in join order. Studio sometimes never launches one of a session's clients; with
	-- `topUpAfter`, missing clients are replaced once via AddPlayers instead of failing the session.
	local function admit(count: number, timeout: number, topUpAfter: number?): ()
		local known: { [Player]: boolean } = {}
		for _, p in ordered do
			known[p] = true
		end
		local started = os.clock()
		local toppedThisRound = false
		local okJoin, joinErr = pcall(waitFor, function()
			local ready, present = 0, 0
			for _, p in Players:GetPlayers() do
				if not known[p] then
					present += 1
					if readyPlayers[p] then
						ready += 1
					end
				end
			end
			if topUpAfter and not toppedThisRound and os.clock() - started > topUpAfter and present < count then
				toppedThisRound = true
				local missing = count - present
				local okAdd, addErr = pcall(function()
					StudioTestService:AddPlayers(missing)
				end)
				if okAdd then
					toppedUp += missing
					print(`[Rehearse] {missing} client(s) never joined; added replacement(s)`)
				else
					warn(`[Rehearse] could not add replacement clients: {addErr}`)
				end
			end
			return ready >= count
		end, timeout, `{count} client agent(s) to connect`)
		if not okJoin then
			local seen = {}
			for _, p in Players:GetPlayers() do
				local state = if readyPlayers[p] then "agent ready" else "no agent"
				table.insert(seen, `{p.Name}({state}{if agentErrors[p] then ", " .. agentErrors[p] else ""})`)
			end
			error(`{joinErr}; players: {if #seen > 0 then table.concat(seen, ", ") else "no players joined"}`, 0)
		end
		local added = 0
		for _, p in Players:GetPlayers() do
			if added < count and readyPlayers[p] and not known[p] then
				table.insert(ordered, p)
				known[p] = true
				added += 1
			end
		end
	end

	local joinStarted = os.clock()
	local okAdmit, admitErr = pcall(admit, decl.players, CLIENT_JOIN_TIMEOUT, TOP_UP_AFTER)
	if not okAdmit then
		return { status = "error", error = tostring(admitErr), tests = {} }
	end
	local joinSeconds = math.floor((os.clock() - joinStarted) * 10) / 10

	-- A setup problem on a client (for example an unknown device id) fails the session up front.
	for _, p in ordered do
		if agentErrors[p] then
			return {
				status = "error",
				error = `client {p.Name}: {agentErrors[p]}`,
				tests = {},
				joinSeconds = joinSeconds,
			}
		end
	end

	local proxies: { [number]: any } = {}
	local function clientProxy(i: number)
		if proxies[i] then
			return proxies[i]
		end
		local player = ordered[i]
		if not player then
			error(`client({i}) does not exist; this session has {#ordered} client(s)`, 2)
		end
		local function call(cmd: string, ...: any): any
			if left[player] or player.Parent == nil then
				error(`client({i}) {cmd}: the client has left the session`, 0)
			end
			local okInvoke, res = pcall(command.InvokeClient, command, player, cmd, ...)
			if not okInvoke then
				error(`client({i}) {cmd}({fmtArgs(...)}): {res}`, 0)
			end
			if type(res) ~= "table" then
				error(`client({i}) {cmd}: no response`, 0)
			end
			if not res.ok then
				error(`client({i}) {cmd}({fmtArgs(...)}): {res.err}`, 0)
			end
			return res.value
		end
		local proxy = {
			index = i,
			player = player,
			click = function(_, path: string, opts: any?)
				return call("click", path, opts)
			end,
			key = function(_, keyCode: string, opts: any?)
				return call("key", keyCode, opts)
			end,
			type = function(_, text: string)
				return call("type", text)
			end,
			fill = function(_, path: string, text: string, opts: any?)
				return call("fill", path, text, opts)
			end,
			get = function(_, path: string)
				return call("get", path)
			end,
			exists = function(_, path: string)
				return call("exists", path)
			end,
			isVisible = function(_, path: string)
				return call("isVisible", path)
			end,
			isInViewport = function(_, path: string)
				return call("isInViewport", path)
			end,
			waitFor = function(_, path: string, expected: any?, timeout: number?)
				return call("waitFor", path, expected, timeout)
			end,
			character = function(_, timeout: number?)
				return call("character", timeout)
			end,
			moveTo = function(_, target: Vector3, timeout: number?)
				return call("moveTo", target, timeout)
			end,
			call = function(_, fnName: string, ...: any)
				return call("call", fnName, ...)
			end,
			leave = function(_, timeout: number?)
				call("leave")
				waitFor(function()
					return player.Parent == nil
				end, timeout or 10, `client({i}) to leave`)
				left[player] = true
			end,
		}
		proxies[i] = proxy
		return proxy
	end

	local wanted: { [number]: boolean }? = nil
	if type(args.tests) == "table" then
		local w = {}
		for _, idx in args.tests do
			w[idx] = true
		end
		wanted = w
	end

	local results = {}
	for index, test in decl.tests do
		if wanted and not wanted[index] then
			continue
		end
		local logs = {}
		local ctx = {
			client = clientProxy,
			clients = function()
				local out = {}
				for i in ordered do
					table.insert(out, clientProxy(i))
				end
				return out
			end,
			players = function()
				return table.clone(ordered)
			end,
			-- Adds players mid-session and returns their client proxies.
			addPlayers = function(n: number, timeout: number?)
				assert(type(n) == "number" and n >= 1, "addPlayers(n) needs n >= 1")
				local before = #ordered
				StudioTestService:AddPlayers(n)
				admit(n, timeout or CLIENT_JOIN_TIMEOUT)
				local out = {}
				for i = before + 1, #ordered do
					table.insert(out, clientProxy(i))
				end
				return table.unpack(out)
			end,
			device = args.device,
			waitFor = waitFor,
			wait = function(seconds: number)
				task.wait(seconds)
			end,
			expect = Expect,
			log = function(...)
				local parts = {}
				for i = 1, select("#", ...) do
					parts[i] = tostring((select(i, ...)))
				end
				table.insert(logs, table.concat(parts, " "))
			end,
		}

		local started = os.clock()
		local done, ok, err = false, false, nil
		local function body()
			for _, hook in decl.beforeEach do
				hook(ctx)
			end
			local bodyOk, bodyErr = xpcall(test.fn, function(m)
				return tostring(m)
			end, ctx)
			-- afterEach always runs; its failure only matters if the test itself passed.
			for _, hook in decl.afterEach do
				local hookOk, hookErr = xpcall(hook, function(m)
					return tostring(m)
				end, ctx)
				if bodyOk and not hookOk then
					bodyOk, bodyErr = false, `afterEach: {hookErr}`
				end
			end
			if not bodyOk then
				error(bodyErr, 0)
			end
		end
		local thread = task.spawn(function()
			local o, e = xpcall(body, function(m)
				return tostring(m)
			end)
			done, ok, err = true, o, e
		end)
		while not done and os.clock() - started < test.timeout do
			RunService.Heartbeat:Wait()
		end
		if not done then
			task.cancel(thread)
			ok, err = false, `test timed out after {test.timeout}s`
		end
		table.insert(results, {
			name = test.name,
			status = if ok then "pass" else "fail",
			error = if ok then nil else err,
			ms = math.floor((os.clock() - started) * 1000),
			logs = if #logs > 0 then logs else nil,
		})
	end

	return {
		status = "ran",
		tests = results,
		joinSeconds = joinSeconds,
		replacedClients = if toppedUp > 0 then toppedUp else nil,
	}
end

function Runner.start()
	local ok, args = pcall(function()
		return StudioTestService:GetTestArgs()
	end)
	if not ok or type(args) ~= "table" or args.rehearse ~= true then
		return -- not a Rehearse session; stay inert
	end
	task.spawn(function()
		local runOk, result = pcall(run, args)
		if not runOk then
			result = { status = "error", error = tostring(result), tests = {} }
		end
		StudioTestService:EndTest(HttpService:JSONEncode(result))
	end)
end

return Runner
