--!strict
-- Edit DataModel: starts one multiplayer test session per spec and collects reports.
--
-- Agents and command-bar code trigger runs through a non-archivable bridge:
--   local bridge = game.ServerStorage.RehearseBridge
--   bridge.Start:Invoke({ filter = "Lobby" })     -- returns runId immediately
--   bridge:GetAttribute("Status")                 -- "running" | "done"
--   bridge:GetAttribute("LastReport")             -- JSON report
--   bridge.Run:Invoke({ filter = "Lobby" })       -- same, but yields and returns the report table

local HttpService = game:GetService("HttpService")
local ServerStorage = game:GetService("ServerStorage")
local StudioTestService = game:GetService("StudioTestService")

local Spec = require(script.Parent.Spec)

local Launcher = {}

local running = false

local function now(): number
	return os.clock()
end

local function runSpec(module: ModuleScript, runId: string): { [string]: any }
	local started = now()
	local ok, decl = pcall(Spec.load, module)
	if not ok then
		return { spec = module.Name, status = "error", error = tostring(decl), tests = {} }
	end
	if #decl.tests == 0 then
		return { spec = decl.name, status = "skipped", tests = {} }
	end

	local args = { rehearse = true, runId = runId, spec = module:GetFullName() }
	local callOk, raw = pcall(function()
		return StudioTestService:ExecuteMultiplayerTestAsync(decl.players, args)
	end)

	local result: { [string]: any }
	if not callOk then
		result = { spec = decl.name, status = "error", error = `session failed to start: {raw}`, tests = {} }
	elseif type(raw) ~= "string" then
		result = {
			spec = decl.name,
			status = "error",
			error = `session ended without a report (got {typeof(raw)}); the test may have been stopped manually`,
			tests = {},
		}
	else
		local decodeOk, decoded = pcall(HttpService.JSONDecode, HttpService, raw)
		result = if decodeOk then decoded else { spec = decl.name, status = "error", error = "bad report JSON", tests = {} }
	end
	result.players = decl.players
	result.sessionSeconds = math.floor((now() - started) * 100) / 100
	return result
end

function Launcher.run(opts: { filter: string? }?): { [string]: any }
	if running then
		error("a Rehearse run is already in progress", 0)
	end
	running = true
	local filter = opts and opts.filter
	local runId = HttpService:GenerateGUID(false)
	local started = now()
	local report = { runId = runId, specs = {}, passed = 0, failed = 0, errors = 0 }

	local ok, err = pcall(function()
		local modules = Spec.modules(filter)
		if #modules == 0 then
			error("no specs found in ServerStorage.RehearseSpecs" .. (if filter then ` matching "{filter}"` else ""), 0)
		end
		for _, m in modules do
			local r = runSpec(m, runId)
			table.insert(report.specs, r)
			if r.status == "error" then
				report.errors += 1
			end
			for _, t in r.tests or {} do
				if t.status == "pass" then
					report.passed += 1
				else
					report.failed += 1
				end
			end
		end
	end)
	running = false
	if not ok then
		report.errors += 1
		report.error = tostring(err)
	end
	report.ok = report.failed == 0 and report.errors == 0
	report.seconds = math.floor((now() - started) * 100) / 100
	return report
end

local function printReport(report: { [string]: any })
	local lines = { `Rehearse {if report.ok then "PASSED" else "FAILED"}: {report.passed} passed, {report.failed} failed, {report.errors} errors ({report.seconds}s)` }
	if report.error then
		table.insert(lines, `  error: {report.error}`)
	end
	for _, s in report.specs do
		table.insert(lines, `  {s.spec} [{s.players or "?"}p, {s.sessionSeconds or "?"}s]{if s.error then " ERROR: " .. s.error else ""}`)
		for _, t in s.tests or {} do
			table.insert(lines, `    {if t.status == "pass" then "✓" else "✗"} {t.name} ({t.ms}ms){if t.error then "\n        " .. t.error else ""}`)
		end
	end
	print(table.concat(lines, "\n"))
end

function Launcher.start(plugin: Plugin)
	local bridge = ServerStorage:FindFirstChild("RehearseBridge")
	if bridge then
		bridge:Destroy()
	end
	local folder = Instance.new("Folder")
	folder.Name = "RehearseBridge"
	folder.Archivable = false
	local runFn = Instance.new("BindableFunction")
	runFn.Name = "Run"
	runFn.Parent = folder
	local startFn = Instance.new("BindableFunction")
	startFn.Name = "Start"
	startFn.Parent = folder
	folder:SetAttribute("Status", "idle")

	local function execute(opts)
		folder:SetAttribute("Status", "running")
		local report = Launcher.run(opts)
		folder:SetAttribute("LastReport", HttpService:JSONEncode(report))
		folder:SetAttribute("Status", "done")
		printReport(report)
		return report
	end
	runFn.OnInvoke = execute
	startFn.OnInvoke = function(opts)
		if running then
			error("a Rehearse run is already in progress", 0)
		end
		task.spawn(execute, opts)
		return "started"
	end
	folder.Parent = ServerStorage

	local toolbar = plugin:CreateToolbar("Rehearse")
	local button = toolbar:CreateButton("RehearseRunAll", "Run all Rehearse specs", "rbxasset://textures/StudioToolbox/AssetPreview/play.png", "Run tests")
	button.ClickableWhenViewportHidden = true
	button.Click:Connect(function()
		if not running then
			task.spawn(execute, nil)
		end
	end)

	plugin.Unloading:Connect(function()
		folder:Destroy()
	end)
end

return Launcher
