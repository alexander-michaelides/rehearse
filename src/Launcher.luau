--!strict
--[=[
	@class Launcher

	Edit DataModel: plans test sessions from the specs, starts each one with
	StudioTestService:ExecuteMultiplayerTestAsync, retries sessions that fail to
	start, and collects one report.

	Agents, the CLI and command-bar code trigger runs through a non-archivable bridge:
	```lua
	local bridge = game.ServerStorage.RehearseBridge
	bridge.Start:Invoke({ filter = "Lobby", grep = "match" })  -- returns "started" immediately
	bridge:GetAttribute("Status")                             -- "idle" | "running" | "done"
	bridge:GetAttribute("Progress")                           -- "2/5 Lobby [iphone_14]"
	bridge:GetAttribute("LastReport")                         -- JSON report (see Report.luau)
	bridge.Run:Invoke(opts)                                   -- same, but yields and returns the report table
	bridge.List:Invoke(opts)                                  -- the planned sessions, without running anything
	```
]=]

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local StudioTestService = game:GetService("StudioTestService")

local Spec = require(script.Parent.Spec)
local Plan = require(script.Parent.Plan)
local Report = require(script.Parent.Report)

local Launcher = {}

export type RunOptions = {
	filter: string?, -- substring of the spec module name
	grep: string?, -- substring of "Spec > test name" (case-insensitive)
	retries: number?, -- extra attempts for a session that fails before its tests run (default 1)
	failOnErrors: boolean?, -- fail tests when game scripts log errors (also per spec: s.failOnErrors())
	solo: boolean?, -- run 1-player sessions as an in-process Play test (faster; the Studio MCP can record it)
}

Launcher.VERSION = "0.2.0"

local running = false
local progress: ((string) -> ())? = nil
local onHung: ((string?) -> ())? = nil

-- Matches Runner's client join timeout, plus slack for session startup and shutdown.
local SESSION_OVERHEAD = 30 + 15

local function round(n: number, places: number): number
	local m = 10 ^ places
	return math.floor(n * m + 0.5) / m
end

local function loadSpecs(filter: string?): ({ ModuleScript }, { any }, { any })
	local modules = Spec.modules(filter)
	local decls, loadErrors = {}, {}
	local loaded: { ModuleScript } = {}
	for _, m in modules do
		local ok, decl = pcall(Spec.load, m, false)
		if ok then
			table.insert(loaded, m)
			table.insert(decls, decl)
		else
			table.insert(loadErrors, { spec = m.Name, error = tostring(decl) })
		end
	end
	return loaded, decls, loadErrors
end

local function runSession(
	module: ModuleScript,
	session: Plan.Session,
	runId: string,
	position: string,
	opts: RunOptions?
): { [string]: any }
	local indices = {}
	for _, t in session.tests do
		table.insert(indices, t.index)
	end
	local args = {
		rehearse = true,
		runId = runId,
		spec = module:GetFullName(),
		tests = indices,
		device = session.device,
		failOnErrors = opts and opts.failOnErrors == true,
	}
	-- A session started right after the previous one ends sometimes returns nil at once
	-- (old session processes still shutting down); a short pause avoids most of those.
	task.wait(1)
	if progress then
		progress(`{position} {Report.sessionLabel(session)} ({session.players}p)`)
	end
	-- Watchdog: Studio occasionally never finishes a session (its server or clients don't start).
	-- Edit can't cancel a session, so flag it; the CLI then kills the session's processes,
	-- ExecuteMultiplayerTestAsync returns, and the retry logic takes over.
	local budget = SESSION_OVERHEAD
	for _, t in session.tests do
		budget += t.timeout
	end
	local finished = false
	task.delay(budget, function()
		if not finished then
			if progress then
				progress(`{position} {Report.sessionLabel(session)} is stuck (no result after {budget}s)`)
			end
			if onHung then
				onHung(`{position} {Report.sessionLabel(session)}`)
			end
		end
	end)
	local solo = opts ~= nil and opts.solo == true and session.players == 1
	args.solo = solo
	local simulator = game:GetService("StudioDeviceSimulatorService") :: any
	local deviceBefore = nil
	if solo and session.device then
		pcall(function()
			deviceBefore = simulator:GetDeviceAsync()
		end)
	end
	local callOk, raw = pcall(function()
		if solo then
			-- Server and client run inside this Studio window, as with the Play button.
			return StudioTestService:ExecutePlayModeAsync(args)
		end
		return StudioTestService:ExecuteMultiplayerTestAsync(session.players, args)
	end)
	if deviceBefore then
		-- A solo session simulates the device in this window; put it back.
		pcall(function()
			simulator:SetDeviceAsync(deviceBefore)
		end)
	end
	finished = true
	if onHung then
		onHung(nil)
	end
	if not callOk then
		return { status = "error", error = `session failed to start: {raw}`, tests = {} }
	end
	if type(raw) ~= "string" then
		return {
			status = "error",
			error = `session ended without a report (got {typeof(raw)}); it may have been stopped manually`,
			tests = {},
		}
	end
	local decodeOk, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
	if not decodeOk or type(decoded) ~= "table" then
		return { status = "error", error = "the session returned an unreadable report", tests = {} }
	end
	return decoded
end

function Launcher.plan(opts: RunOptions?): { [string]: any }
	local _, decls, loadErrors = loadSpecs(opts and opts.filter)
	local planned = Plan.build(decls, { grep = opts and opts.grep })
	local sessions = {}
	for _, s in planned.sessions do
		local names = {}
		for _, t in s.tests do
			table.insert(names, t.name)
		end
		table.insert(sessions, { spec = s.spec, players = s.players, device = s.device, tests = names })
	end
	return { sessions = sessions, skippedTests = planned.skipped, loadErrors = loadErrors }
end

function Launcher.run(opts: RunOptions?): { [string]: any }
	if running then
		error("a Rehearse run is already in progress", 0)
	end
	running = true
	local filter = opts and opts.filter
	local retries = math.clamp((opts and opts.retries) or 1, 0, 5)
	local runId = HttpService:GenerateGUID(false)
	local started = os.clock()
	local report: { [string]: any } = { runId = runId, version = Launcher.VERSION, sessions = {}, skippedTests = {} }

	local ok, err = pcall(function()
		local modules, decls, loadErrors = loadSpecs(filter)
		for _, le in loadErrors do
			table.insert(report.sessions, {
				spec = le.spec,
				status = "error",
				error = le.error,
				attempts = 0,
				tests = { { name = "(load spec)", status = "error" } },
			})
		end
		if #modules == 0 and #loadErrors == 0 then
			error("no specs found in ServerStorage.RehearseSpecs" .. (if filter then ` matching "{filter}"` else ""), 0)
		end
		local planned = Plan.build(decls, { grep = opts and opts.grep })
		if progress then
			progress(`{#planned.sessions} session(s) planned from {#modules} spec(s)`)
		end
		report.skippedTests = planned.skipped

		for i, session in planned.sessions do
			local sessionStarted = os.clock()
			local result: { [string]: any }
			local attempts = 0
			local retried = {}
			while true do
				attempts += 1
				local attemptStarted = os.clock()
				result = runSession(modules[session.specIndex], session, runId, `{i}/{#planned.sessions}`, opts)
				-- Only retry sessions that never got to run tests (join timeouts, launch failures).
				if result.status ~= "error" or attempts > retries then
					break
				end
				table.insert(retried, `attempt {attempts} ({round(os.clock() - attemptStarted, 1)}s): {result.error}`)
				task.wait(1) -- let the previous session's processes shut down
			end

			result.retried = if #retried > 0 then retried else nil
			result.spec = session.spec
			result.players = session.players
			result.device = session.device
			result.attempts = attempts
			result.sessionSeconds = round(os.clock() - sessionStarted, 2)
			if result.status == "error" then
				-- Every planned test in a failed session is reported as an error, so nothing silently disappears.
				local tests = {}
				for _, t in session.tests do
					table.insert(tests, { name = t.name, status = "error" })
				end
				result.tests = tests
			end
			table.insert(report.sessions, result)
		end
	end)
	running = false
	if not ok then
		report.error = tostring(err)
	end
	report.seconds = round(os.clock() - started, 2)
	Report.tally(report)
	return report
end

function Launcher.start(plugin: Plugin)
	local existing = ServerStorage:FindFirstChild("RehearseBridge")
	if existing then
		existing:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "RehearseBridge"
	folder.Archivable = false
	folder:SetAttribute("Status", "idle")
	folder:SetAttribute("Version", Launcher.VERSION)

	local function fn(name: string): BindableFunction
		local f = Instance.new("BindableFunction")
		f.Name = name
		f.Parent = folder
		return f
	end

	onHung = function(label: string?)
		folder:SetAttribute("Hung", label)
	end
	progress = function(text: string)
		folder:SetAttribute("Progress", text)
		print(`[Rehearse] {text}`)
	end

	local button: PluginToolbarButton? = nil

	local function execute(opts: RunOptions?)
		folder:SetAttribute("Status", "running")
		folder:SetAttribute("Progress", "starting")
		if button then
			button.Enabled = false
		end
		local okRun, report = pcall(Launcher.run, opts)
		if not okRun then
			report = { ok = false, error = tostring(report), sessions = {}, skippedTests = {} }
			Report.tally(report)
		end
		folder:SetAttribute("LastReport", HttpService:JSONEncode(report))
		folder:SetAttribute("Progress", nil)
		folder:SetAttribute("Status", "done")
		if button then
			button.Enabled = true
		end
		local text = Report.text(report)
		if report.ok then
			print(text)
		else
			warn(text)
		end
		return report
	end

	fn("Run").OnInvoke = execute
	fn("Start").OnInvoke = function(opts: RunOptions?)
		if running then
			error("a Rehearse run is already in progress", 0)
		end
		task.spawn(execute, opts)
		return "started"
	end
	fn("List").OnInvoke = function(opts: RunOptions?)
		return Launcher.plan(opts)
	end
	folder.Parent = ServerStorage

	local toolbar = plugin:CreateToolbar("Rehearse")
	local b = toolbar:CreateButton(
		"RehearseRunAll",
		"Run every spec in ServerStorage.RehearseSpecs",
		"", -- text-only button
		"Run tests"
	)
	b.ClickableWhenViewportHidden = true
	b.Click:Connect(function()
		if not running then
			task.spawn(execute, nil)
		end
	end)
	button = b

	plugin.Unloading:Connect(function()
		progress = nil
		onHung = nil
		folder:Destroy()
	end)
end

return Launcher
