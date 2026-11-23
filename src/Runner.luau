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

-- Polls `predicate` every frame until it returns a truthy value. The timeout holds even if
-- the predicate yields (for example a WaitForChild inside it): each poll runs in its own thread.
local function waitFor(predicate: () -> any, timeout: number?, what: string?): any
	local limit = timeout or 5
	local deadline = os.clock() + limit
	local lastErr: any = nil
	local yielding = false
	while true do
		local finished, ok, value = false, false, nil
		local thread = task.spawn(function()
			ok, value = pcall(predicate)
			finished = true
		end)
		while not finished and os.clock() <= deadline do
			RunService.Heartbeat:Wait()
		end
		if not finished then
			task.cancel(thread)
			yielding = true
		elseif ok and value then
			return value
		elseif not ok then
			lastErr = value
		end
		if os.clock() > deadline then
			local detail = if yielding
				then " (the check was still waiting on something; avoid WaitForChild or wait() inside waitFor)"
				elseif lastErr then ` (last error: {lastErr})`
				else ""
			error(`timed out after {limit}s waiting for {what or "condition"}{detail}`, 0)
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

local function fmtValue(v: any, depth: number): string
	if type(v) == "string" then
		return string.format("%q", v)
	elseif type(v) == "table" and depth < 2 then
		local parts = {}
		for k, inner in v do
			table.insert(parts, `{k} = {fmtValue(inner, depth + 1)}`)
		end
		table.sort(parts)
		return "{ " .. table.concat(parts, ", ") .. " }"
	end
	return tostring(v)
end

local function fmtArgs(...: any): string
	local parts = {}
	for i = 1, select("#", ...) do
		parts[i] = fmtValue((select(i, ...)), 0)
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

	-- beforeJoin hooks run before any client is admitted; their logs stay with the session.
	local setupLogs = {}
	if #decl.beforeJoin > 0 then
		local setupCtx = {
			waitFor = waitFor,
			expect = Expect,
			device = args.device,
			log = function(...)
				local parts = {}
				for i = 1, select("#", ...) do
					parts[i] = tostring((select(i, ...)))
				end
				table.insert(setupLogs, table.concat(parts, " "))
			end,
		}
		for _, hook in decl.beforeJoin do
			local okHook, hookErr = pcall(hook, setupCtx)
			if not okHook then
				return { status = "error", error = `beforeJoin: {hookErr}`, tests = {}, setupLogs = setupLogs }
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
		-- Any method not defined here is sent to the client agent as a command:
		-- client:click(path) -> Agent commands.click(path), and so on.
		local proxy = setmetatable({
			index = i,
			player = player,
			leave = function(_, timeout: number?)
				call("leave")
				waitFor(function()
					return player.Parent == nil
				end, timeout or 10, `client({i}) to leave`)
				left[player] = true
			end,
		}, {
			__index = function(_, cmd: string)
				return function(_, ...: any)
					return call(cmd, ...)
				end
			end,
		})
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

	-- Game script errors and warnings, from the server and every client, per test.
	-- Seeded with what was logged before Rehearse started (game scripts run first).
	local serverLog: { { kind: string, message: string } } = {}
	local LogService = game:GetService("LogService")
	pcall(function()
		for _, entry in LogService:GetLogHistory() do
			local mt = entry.messageType
			if
				(mt == Enum.MessageType.MessageError or mt == Enum.MessageType.MessageWarning)
				and string.sub(entry.message, 1, 10) ~= "[Rehearse]"
			then
				table.insert(serverLog, {
					kind = if mt == Enum.MessageType.MessageError then "error" else "warning",
					message = string.sub(entry.message, 1, 500),
				})
			end
		end
	end)
	LogService.MessageOut:Connect(function(message, messageType)
		if string.sub(message, 1, 10) == "[Rehearse]" then
			return
		end
		if messageType == Enum.MessageType.MessageError or messageType == Enum.MessageType.MessageWarning then
			if #serverLog < 500 then
				table.insert(serverLog, {
					kind = if messageType == Enum.MessageType.MessageError then "error" else "warning",
					message = string.sub(message, 1, 500),
				})
			end
		end
	end)

	-- InvokeClient never times out on its own; diagnostics must not hang a session.
	local function invokeWithin(player: Player, seconds: number, cmd: string, ...: any): any
		local result, finished = nil, false
		local packed = table.pack(...)
		local thread = task.spawn(function()
			local okInvoke, res = pcall(command.InvokeClient, command, player, cmd, table.unpack(packed, 1, packed.n))
			if okInvoke and type(res) == "table" and res.ok then
				result = res.value
			end
			finished = true
		end)
		local deadline = os.clock() + seconds
		while not finished and os.clock() < deadline do
			RunService.Heartbeat:Wait()
		end
		if not finished then
			task.cancel(thread)
		end
		return result
	end

	local function drainClientLogs(into: { { kind: string, message: string } })
		for i, p in ordered do
			if not left[p] and p.Parent ~= nil then
				local entries = invokeWithin(p, 2, "drainLogs")
				for _, e in entries or {} do
					table.insert(into, { kind = e.kind, message = `client({i}): {e.message}` })
				end
			end
		end
	end

	local function snapshots(): { [string]: any }?
		local out = {}
		local any = false
		for i, p in ordered do
			if not left[p] and p.Parent ~= nil then
				local snap = invokeWithin(p, 3, "snapshot")
				if snap then
					out[`client({i})`] = snap
					any = true
				end
			end
		end
		return if any then out else nil
	end

	local failOnErrors = decl.failOnErrors or args.failOnErrors == true

	-- Studio noise that isn't the game's fault (other plugins, asset loading in a local place).
	local ignorePatterns = {
		"^Unable to load plugin icon",
		"^ContentId: .* failed due to",
		"^Failed to load sound",
		"^Asset type does not match",
	}
	for _, pattern in decl.ignoreErrors do
		table.insert(ignorePatterns, pattern)
	end
	local function ignored(message: string): boolean
		local text = string.gsub(message, "^client%(%d+%): ", "")
		text = string.gsub(text, "^server: ", "")
		for _, pattern in ignorePatterns do
			if string.find(text, pattern) then
				return true
			end
		end
		return false
	end

	-- Everything logged while the session started up and players joined.
	local startupErrors, startupWarnings = {}, {}
	do
		local startupLog = {}
		for _, e in serverLog do
			table.insert(startupLog, { kind = e.kind, message = `server: {e.message}` })
		end
		drainClientLogs(startupLog)
		for _, e in startupLog do
			local list = if e.kind == "error" then startupErrors else startupWarnings
			if #list < 20 and not ignored(e.message) then
				table.insert(list, e.message)
			end
		end
	end
	local startupReported = false

	local results = {}
	for index, test in decl.tests do
		if wanted and not wanted[index] then
			continue
		end
		local logs = {}
		-- Start this test's log window: drop anything logged before it.
		local serverMark = #serverLog
		drainClientLogs({})
		local testLog: { { kind: string, message: string } } = {}
		local function collectLogs()
			for i = serverMark + 1, #serverLog do
				local e = serverLog[i]
				table.insert(testLog, { kind = e.kind, message = `server: {e.message}` })
			end
			serverMark = #serverLog
			drainClientLogs(testLog)
		end
		local function errorsOnly(): { string }
			local out = {}
			for _, e in testLog do
				if e.kind == "error" and not ignored(e.message) then
					table.insert(out, e.message)
				end
			end
			return out
		end
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
			-- Game script errors logged so far in this test (server and clients).
			gameErrors = function(): { string }
				collectLogs()
				return errorsOnly()
			end,
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
		local ms = math.floor((os.clock() - started) * 1000)

		task.wait(0.1) -- let errors from the test's last actions reach the log
		collectLogs()
		local gameErrors, gameWarnings = {}, {}
		for _, e in testLog do
			local list = if e.kind == "error" then gameErrors else gameWarnings
			if #list < 20 and not ignored(e.message) then
				table.insert(list, e.message)
			end
		end
		if ok and failOnErrors and #gameErrors > 0 then
			ok, err = false, `{#gameErrors} game script error(s) during the test (failOnErrors): {gameErrors[1]}`
		end
		if ok and failOnErrors and #startupErrors > 0 and not startupReported then
			ok, err =
				false,
				`{#startupErrors} game script error(s) while the session started (failOnErrors): {startupErrors[1]}`
		end
		startupReported = true

		table.insert(results, {
			name = test.name,
			status = if ok then "pass" else "fail",
			error = if ok then nil else err,
			ms = ms,
			logs = if #logs > 0 then logs else nil,
			gameErrors = if #gameErrors > 0 then gameErrors else nil,
			gameWarnings = if #gameWarnings > 0 then gameWarnings else nil,
			snapshot = if ok then nil else snapshots(),
		})
	end

	return {
		status = "ran",
		tests = results,
		startupErrors = if #startupErrors > 0 then startupErrors else nil,
		setupLogs = if #setupLogs > 0 then setupLogs else nil,
		startupWarnings = if #startupWarnings > 0 then startupWarnings else nil,
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
