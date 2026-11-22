--!strict
-- Server DataModel of a test session: waits for clients, runs the spec's tests,
-- and reports back to the Launcher through StudioTestService:EndTest.

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local StudioTestService = game:GetService("StudioTestService")

local Spec = require(script.Parent.Spec)
local Expect = require(script.Parent.Expect)

local Runner = {}

local CLIENT_JOIN_TIMEOUT = 60

local function resolveFullName(fullName: string): Instance?
	local current: Instance? = game
	for _, part in string.split(fullName, ".") do
		current = current and current:FindFirstChild(part)
	end
	return current
end

local function waitFor(predicate: () -> any, timeout: number?, what: string?): any
	local deadline = os.clock() + (timeout or 5)
	while true do
		local ok, value = pcall(predicate)
		if ok and value then
			return value
		end
		if os.clock() > deadline then
			error(`timed out after {timeout or 5}s waiting for {what or "condition"}` .. (if not ok then ` (last error: {value})` else ""), 0)
		end
		RunService.Heartbeat:Wait()
	end
end

local function makeChannel(): (RemoteFunction, RemoteEvent)
	local folder = Instance.new("Folder")
	folder.Name = "__Rehearse"
	local fn = Instance.new("RemoteFunction")
	fn.Name = "Command"
	fn.Parent = folder
	local ready = Instance.new("RemoteEvent")
	ready.Name = "AgentReady"
	ready.Parent = folder
	folder.Parent = ReplicatedStorage
	return fn, ready
end

local function run(args: { [string]: any }): { [string]: any }
	local module = resolveFullName(args.spec)
	if not module or not module:IsA("ModuleScript") then
		return { spec = args.spec, status = "error", error = "spec module not found in test session", tests = {} }
	end
	local decl = Spec.load(module)

	local command, agentReady = makeChannel()
	local readyPlayers: { [Player]: boolean } = {}
	local pinging: { [Player]: boolean } = {}
	agentReady.OnServerEvent:Connect(function(player)
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

	-- Wait until every simulated client has joined and its agent is listening.
	local joinStarted = os.clock()
	local okJoin, joinErr = pcall(waitFor, function()
		local n = 0
		for _, p in Players:GetPlayers() do
			if readyPlayers[p] then
				n += 1
			end
		end
		return n >= decl.players
	end, CLIENT_JOIN_TIMEOUT, `{decl.players} client agent(s) to connect`)
	if not okJoin then
		local seen = {}
		for _, p in Players:GetPlayers() do
			table.insert(seen, `{p.Name}({if readyPlayers[p] then "agent ready" else "no agent"})`)
		end
		local detail = if #seen > 0 then table.concat(seen, ", ") else "no players joined"
		return { spec = decl.name, status = "error", error = `{joinErr}; players: {detail}`, tests = {} }
	end

	-- Stable client order: join order.
	local ordered: { Player } = {}
	for _, p in Players:GetPlayers() do
		if readyPlayers[p] then
			table.insert(ordered, p)
		end
	end

	local function clientProxy(i: number)
		local player = ordered[i]
		assert(player, `client({i}) does not exist; spec has {#ordered} client(s)`)
		local function call(cmd: string, ...: any): any
			local res = command:InvokeClient(player, cmd, ...)
			if type(res) ~= "table" then
				error(`client({i}) {cmd}: no response`, 0)
			end
			if not res.ok then
				error(`client({i}) {cmd}: {res.err}`, 0)
			end
			return res.value
		end
		return {
			player = player,
			click = function(_, path: string, opts: any?)
				return call("click", path, opts)
			end,
			key = function(_, keyCode: string)
				return call("key", keyCode)
			end,
			type = function(_, text: string)
				return call("type", text)
			end,
			get = function(_, path: string)
				return call("get", path)
			end,
			waitFor = function(_, path: string, expected: any?, timeout: number?)
				return call("waitFor", path, expected, timeout)
			end,
		}
	end

	local results = {}
	for _, test in decl.tests do
		local logs = {}
		local ctx = {
			client = clientProxy,
			players = function()
				return table.clone(ordered)
			end,
			waitFor = waitFor,
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
		local thread = task.spawn(function()
			local o, e = xpcall(test.fn, function(m)
				return tostring(m)
			end, ctx)
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

	return { spec = decl.name, status = "ran", tests = results, joinSeconds = math.floor((os.clock() - joinStarted) * 10) / 10 }
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
			result = { spec = args.spec, status = "error", error = tostring(result), tests = {} }
		end
		StudioTestService:EndTest(HttpService:JSONEncode(result))
	end)
end

return Runner
