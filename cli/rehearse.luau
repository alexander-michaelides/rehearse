--!strict
--[=[
	Rehearse command-line runner (Lune).

	Launches Roblox Studio in RunScript mode on a place file, triggers the Rehearse
	plugin through its bridge, reads the report back out of Studio's log, closes
	Studio, and exits with a meaningful code.

	  lune run cli/rehearse run build/Game.rbxl [--filter Lobby] [--grep "match"] [--json]
	      [--junit results.xml] [--report results.json] [--retries 1] [--timeout 900]
	      [--studio /path/to/RobloxStudio] [--keep-open]
	  lune run cli/rehearse list build/Game.rbxl [--filter ...] [--grep ...] [--json]

	Exit codes: 0 all passed · 1 tests failed or errored · 2 could not run (usage, Studio, plugin).
]=]

local fs = require("@lune/fs")
local process = require("@lune/process")
local serde = require("@lune/serde")
local stdio = require("@lune/stdio")
local task = require("@lune/task")
local DateTime = require("@lune/datetime")

local Report = require("../src/Report")

local VERSION = "0.2.0"

local USAGE = [[
Usage:
  rehearse run <place.rbxl|.rbxlx> [options]    Run specs and report results
  rehearse list <place.rbxl|.rbxlx> [options]   Show the planned sessions without running them

Options:
  --filter <text>     Only specs whose module name contains <text>
  --grep <text>       Only tests whose "Spec > test" name contains <text> (case-insensitive)
  --retries <n>       Extra attempts for sessions that fail to start (default 1)
  --fail-on-errors    Fail a test if any game script logs an error during it
  --json              Print the JSON report to stdout instead of text
  --junit <file>      Also write a JUnit XML report
  --report <file>     Also write the JSON report
  --timeout <sec>     Give up after this many seconds (default 900)
  --stall <sec>       Give up if no new progress for this long (default 180)
  --studio <path>     Path to the Roblox Studio executable (or set REHEARSE_STUDIO)
  --keep-open         Leave Studio running afterwards (for debugging)
  --quiet             No progress output on stderr
  --version           Print the CLI version

Exit codes: 0 passed, 1 failed, 2 could not run.]]

local EXIT_PASS, EXIT_FAIL, EXIT_INFRA = 0, 1, 2

local function eprint(msg: string)
	stdio.ewrite(msg .. "\n")
end

local function die(msg: string): never
	eprint("rehearse: " .. msg)
	process.exit(EXIT_INFRA)
	error("unreachable")
end

-- Argument parsing --------------------------------------------------------------------

local FLAGS =
	{ json = true, ["keep-open"] = true, quiet = true, version = true, help = true, ["fail-on-errors"] = true }
local VALUES = {
	filter = true,
	grep = true,
	retries = true,
	junit = true,
	report = true,
	timeout = true,
	studio = true,
	stall = true,
}

local function parseArgs(argv: { string }): ({ string }, { [string]: any })
	local positional, opts = {}, {}
	local i = 1
	while i <= #argv do
		local a = argv[i]
		local name = string.match(a, "^%-%-([%w%-]+)$")
		if name and FLAGS[name] then
			opts[name] = true
		elseif name and VALUES[name] then
			local v = argv[i + 1]
			if v == nil then
				die(`--{name} needs a value`)
			end
			opts[name] = v
			i += 1
		elseif a == "-h" then
			opts.help = true
		elseif string.sub(a, 1, 2) == "--" then
			die(`unknown option {a}\n\n{USAGE}`)
		else
			table.insert(positional, a)
		end
		i += 1
	end
	return positional, opts
end

-- Paths and platform ------------------------------------------------------------------

local function join(...: string): string
	return table.concat({ ... }, if process.os == "windows" then "\\" else "/")
end

local function absolute(path: string): string
	if string.sub(path, 1, 1) == "/" or string.match(path, "^%a:[\\/]") then
		return path
	end
	local cwd = string.gsub(process.cwd, "[\\/]+$", "")
	return join(cwd, path)
end

local function home(): string
	return process.env.HOME or process.env.USERPROFILE or die("cannot find the home directory")
end

local function newestDir(root: string): string?
	if not fs.isDir(root) then
		return nil
	end
	local best, bestTime = nil, -1
	for _, name in fs.readDir(root) do
		local p = join(root, name)
		if fs.isDir(p) then
			local t = fs.metadata(p).modifiedAt
			local ts = if t then t.unixTimestampMillis else 0
			if ts > bestTime then
				best, bestTime = p, ts
			end
		end
	end
	return best
end

local function findStudio(explicit: string?): string
	local candidate = explicit or process.env.REHEARSE_STUDIO
	if candidate then
		if not fs.isFile(candidate) then
			die(`Studio executable not found at {candidate}`)
		end
		return candidate
	end
	if process.os == "macos" then
		local mac = "/Applications/RobloxStudio.app/Contents/MacOS/RobloxStudio"
		if fs.isFile(mac) then
			return mac
		end
	elseif process.os == "windows" then
		local versions = newestDir(join(process.env.LOCALAPPDATA or "", "Roblox", "Versions"))
		if versions then
			local exe = join(versions, "RobloxStudioBeta.exe")
			if fs.isFile(exe) then
				return exe
			end
		end
	end
	return die("could not find Roblox Studio; pass --studio <path> or set REHEARSE_STUDIO")
end

local function logDir(): string
	if process.os == "windows" then
		return join(process.env.LOCALAPPDATA or "", "Roblox", "logs")
	end
	return join(home(), "Library", "Logs", "Roblox")
end

local function pluginsDir(): string
	if process.os == "windows" then
		return join(process.env.LOCALAPPDATA or "", "Roblox", "Plugins")
	end
	return join(home(), "Documents", "Roblox", "Plugins")
end

-- The script Studio runs --------------------------------------------------------------

local function runScript(token: string, mode: string, runOpts: { [string]: any }): string
	return string.format(
		[==[
-- Generated by the Rehearse CLI. Safe to delete.
local TOKEN = %q
local MODE = %q
local OPTS = game:GetService("HttpService"):JSONDecode(%q)
local HttpService = game:GetService("HttpService")

local function emit(kind, text)
	local CHUNK = 700
	local n = math.max(1, math.ceil(#text / CHUNK))
	for i = 1, n do
		print(string.format("@@REHEARSE %%s %%s %%d/%%d %%s", TOKEN, kind, i, n, string.sub(text, (i - 1) * CHUNK + 1, i * CHUNK)))
	end
end

local ok, err = pcall(function()
	local bridge = game:GetService("ServerStorage"):WaitForChild("RehearseBridge", 60)
	if not bridge then
		error("the Rehearse plugin did not load (no ServerStorage.RehearseBridge after 60s); is Rehearse.rbxm in your Plugins folder?", 0)
	end
	emit("version", tostring(bridge:GetAttribute("Version")))
	if MODE == "list" then
		emit("plan", HttpService:JSONEncode(bridge.List:Invoke(OPTS)))
		return
	end
	-- Starting a test session the moment Studio opens is unreliable; let it settle first.
	task.wait(2)
	bridge.Start:Invoke(OPTS)
	local last = nil
	local beats, lastBeat = 0, os.clock()
	local lastHung = nil
	while bridge:GetAttribute("Status") ~= "done" do
		local p = bridge:GetAttribute("Progress")
		if p and p ~= last then
			emit("progress", p)
			last = p
		end
		local hung = bridge:GetAttribute("Hung")
		if hung and hung ~= lastHung then
			emit("hung", hung)
		end
		lastHung = hung
		if os.clock() - lastBeat > 10 then
			beats += 1
			lastBeat = os.clock()
			emit("heartbeat", string.format("%%d %%s", beats, tostring(bridge:GetAttribute("Status"))))
		end
		task.wait(0.5)
	end
	emit("report", bridge:GetAttribute("LastReport"))
end)
if not ok then
	emit("fatal", tostring(err))
end
]==],
		token,
		mode,
		serde.encode("json", runOpts)
	)
end

-- Reading Studio's log ----------------------------------------------------------------

type Collector = {
	chunks: { [string]: { [number]: string } },
	totals: { [string]: number },
	seenProgress: { [string]: boolean },
	done: { [string]: string },
}

local function collect(c: Collector, logText: string, token: string, onProgress: (string, string) -> ())
	local marker = "@@REHEARSE " .. token .. " "
	local start = 1
	while true do
		local s, e = string.find(logText, marker, start, true)
		if not s then
			break
		end
		local lineEnd = string.find(logText, "\n", e + 1, true) or (#logText + 1)
		local rest = string.sub(logText, (e :: number) + 1, lineEnd - 1)
		start = lineEnd
		local kind, i, n, payload = string.match(rest, "^(%a+) (%d+)/(%d+) (.*)$")
		if kind and i and n then
			local key = kind
			if kind == "progress" or kind == "heartbeat" or kind == "hung" then
				-- Single-line events; report each distinct one once.
				local text = kind .. " " .. (payload or "")
				if not c.seenProgress[text] then
					c.seenProgress[text] = true
					onProgress(kind, payload or "")
				end
			else
				c.chunks[key] = c.chunks[key] or {}
				c.chunks[key][tonumber(i) :: number] = string.gsub(payload or "", "\r$", "")
				c.totals[key] = tonumber(n) :: number
				local total = c.totals[key]
				local parts = {}
				for k = 1, total do
					local part = c.chunks[key][k]
					if part == nil then
						parts = nil :: any
						break
					end
					parts[k] = part
				end
				if parts then
					c.done[key] = table.concat(parts)
				end
			end
		end
	end
end

local function findLog(dir: string, since: number, scriptPath: string): string?
	if not fs.isDir(dir) then
		return nil
	end
	for _, name in fs.readDir(dir) do
		if string.find(name, "Studio", 1, true) and string.sub(name, -4) == ".log" then
			local p = join(dir, name)
			local meta = fs.metadata(p)
			local t = meta.createdAt or meta.modifiedAt
			if t and t.unixTimestampMillis >= since - 2000 then
				local ok, text = pcall(fs.readFile, p)
				if ok and string.find(string.sub(text, 1, 20000), scriptPath, 1, true) then
					return p
				end
			end
		end
	end
	return nil
end

-- Process cleanup ---------------------------------------------------------------------

local function studioPids(scriptPath: string): { string }
	if process.os == "windows" then
		return {}
	end
	local pids = {}
	local found = process.exec("pgrep", { "-f", scriptPath })
	for pid in string.gmatch(found.stdout, "%d+") do
		table.insert(pids, pid)
	end
	return pids
end

-- Closes the Studio we launched plus every test-session server/client under it.
-- Session processes name their parent with "-parentPid <pid>" or "-editpid <pid>",
-- and clients of a test server point at the server, so walk the tree.
local function studioTree(roots: { string }): { string }
	local ps = process.exec("ps", { "-axo", "pid=,command=" })
	local children: { [string]: { string } } = {}
	for line in string.gmatch(ps.stdout, "[^\n]+") do
		local pid, cmd = string.match(line, "^%s*(%d+)%s+(.*)$")
		if pid and cmd and string.find(cmd, "RobloxStudio", 1, true) then
			for _, flag in { "%-parentPid (%d+)", "%-editpid (%d+)" } do
				local parent = string.match(cmd, flag)
				if parent then
					children[parent] = children[parent] or {}
					table.insert(children[parent], pid)
				end
			end
		end
	end
	local out, seen = {}, {}
	local function visit(pid: string)
		if seen[pid] then
			return
		end
		seen[pid] = true
		table.insert(out, pid)
		for _, c in children[pid] or {} do
			visit(c)
		end
	end
	for _, r in roots do
		visit(r)
	end
	return out
end

local function cleanup(roots: { string })
	if process.os == "windows" or #roots == 0 then
		return -- untested on Windows; Studio is left for the user to close
	end
	local pids = studioTree(roots)
	-- Studio ignores SIGTERM while busy, so ask politely, then force it.
	for _, pid in pids do
		process.exec("kill", { "-TERM", pid })
	end
	task.wait(2)
	for _, pid in pids do
		process.exec("kill", { "-KILL", pid })
	end
end

-- Main --------------------------------------------------------------------------------

local positional, opts = parseArgs(process.args)
if opts.version then
	print(VERSION)
	process.exit(0)
end
local command = positional[1]
if opts.help or command == nil or command == "help" then
	print(USAGE)
	process.exit(if command == nil and not opts.help then EXIT_INFRA else 0)
end
if command ~= "run" and command ~= "list" then
	die(`unknown command "{command}"\n\n{USAGE}`)
end
local placeArg = positional[2] or die("missing place file (a .rbxl or .rbxlx built with `rojo build`)")
local place = absolute(placeArg)
if not fs.isFile(place) then
	die(`place file not found: {place}`)
end
local timeout = tonumber(opts.timeout or "900") or die("--timeout must be a number of seconds")
local quiet = opts.quiet == true
local stall = tonumber(opts.stall or "180") or die("--stall must be a number of seconds")

local studio = findStudio(opts.studio)
if not fs.isFile(join(pluginsDir(), "Rehearse.rbxm")) and not fs.isFile(join(pluginsDir(), "Rehearse.rbxmx")) then
	eprint(`rehearse: warning: Rehearse.rbxm not found in {pluginsDir()}; install it with:`)
	eprint(`  rojo build -o "{join(pluginsDir(), "Rehearse.rbxm")}"`)
end

local token = string.format("%x%x", math.random(0, 0x7fffffff), DateTime.now().unixTimestampMillis % 0x7fffffff)
local scriptPath = join(process.env.TMPDIR or process.env.TEMP or "/tmp", `rehearse-{token}.luau`)
scriptPath = string.gsub(scriptPath, "//", "/")
local runOpts = {
	filter = opts.filter,
	grep = opts.grep,
	retries = if opts.retries then tonumber(opts.retries) else nil,
	failOnErrors = opts["fail-on-errors"] == true,
}
fs.writeFile(scriptPath, runScript(token, command, runOpts))

local function log(msg: string)
	if not quiet then
		eprint(msg)
	end
end

log(`rehearse: opening {placeArg} in Studio...`)
local launchedAt = DateTime.now().unixTimestampMillis
local child = process.create(studio, { "-task", "RunScript", "-localPlaceFile", place, "-runScriptFile", scriptPath })

-- Studio writes its whole log to stdout/stderr. Keep draining both pipes, or
-- Studio blocks on a full pipe and its main thread hangs.
local function drain(reader: any)
	task.spawn(function()
		pcall(function()
			while true do
				local chunk = reader:read()
				if chunk == nil then
					break
				elseif chunk == "" then
					task.wait(0.05)
				end
			end
		end)
	end)
end
drain(child.stdout)
drain(child.stderr)

local studioExited = false
task.spawn(function()
	pcall(function()
		child:status() -- yields until the process exits
	end)
	studioExited = true
end)

local collector: Collector = { chunks = {}, totals = {}, seenProgress = {}, done = {} }
local logPath: string? = nil
local deadline = os.clock() + timeout
local outcome: string? = nil
local lastSign = os.clock() -- last time Studio showed any sign of life (progress or heartbeat)
local lastProgress: string? = nil
local lastProgressAt = os.clock()

while os.clock() < deadline do
	task.wait(1)
	if not logPath then
		logPath = findLog(logDir(), launchedAt, scriptPath)
	end
	if logPath then
		local ok, text = pcall(fs.readFile, logPath)
		if ok then
			collect(collector, text, token, function(kind, p)
				lastSign = os.clock()
				if kind == "progress" then
					lastProgress = p
					lastProgressAt = os.clock()
					log(`rehearse: {p}`)
				elseif kind == "hung" then
					-- Kill only the stuck session's server/clients; Studio and the run carry on.
					local roots = studioPids(scriptPath)
					local victims = {}
					for _, pid in studioTree(roots) do
						if not table.find(roots, pid) then
							table.insert(victims, pid)
						end
					end
					log(`rehearse: {p} is stuck; closing its {#victims} test process(es) so it can be retried`)
					for _, pid in victims do
						process.exec("kill", { "-KILL", pid })
					end
					lastProgressAt = os.clock()
				end
			end)
		end
	end
	if collector.done.fatal or collector.done.report or collector.done.plan then
		outcome = "done"
		break
	end
	if collector.done.version and os.clock() - lastProgressAt > stall then
		outcome = "stalled"
		break
	end
	if studioExited then
		-- Studio exited on its own before reporting (it may have handed off to an existing window).
		outcome = "exited"
		break
	end
end

if not opts["keep-open"] then
	local pids = studioPids(scriptPath)
	pcall(function()
		child:kill()
	end)
	cleanup(pids)
end
pcall(fs.removeFile, scriptPath)

if collector.done.fatal then
	die(collector.done.fatal)
end
if not outcome then
	die(
		`timed out after {timeout}s{if logPath then " (Studio log: " .. logPath .. ")" else " before Studio wrote a log"}`
	)
end
if outcome == "stalled" then
	die(
		`no progress for {stall}s (last: {lastProgress or "none"}; Studio heartbeat {math.floor(os.clock() - lastSign)}s ago){if logPath
			then " (Studio log: " .. logPath .. ")"
			else ""}`
	)
end
if outcome == "exited" and not (collector.done.report or collector.done.plan) then
	die(`Studio exited before reporting{if logPath then " (Studio log: " .. logPath .. ")" else ""}`)
end

if command == "list" then
	local plan = serde.decode("json", collector.done.plan)
	if opts.json then
		print(serde.encode("json", plan, true))
	else
		for _, s in plan.sessions do
			local label = Report.sessionLabel(s)
			print(`{label} [{s.players}p]`)
			for _, name in s.tests do
				print(`  - {name}`)
			end
		end
		for _, t in plan.skippedTests or {} do
			print(`  (skip) {Report.sessionLabel(t)} > {t.name}: {t.reason}`)
		end
		for _, le in plan.loadErrors or {} do
			print(`  (error) {le.spec}: {le.error}`)
		end
	end
	process.exit(if #(plan.loadErrors or {}) > 0 then EXIT_FAIL else EXIT_PASS)
end

local report = serde.decode("json", collector.done.report)
if opts.report then
	fs.writeFile(opts.report, serde.encode("json", report, true))
end
if opts.junit then
	fs.writeFile(opts.junit, Report.junit(report))
end
if opts.json then
	print(serde.encode("json", report, true))
else
	print(Report.text(report))
end
process.exit(if report.ok then EXIT_PASS else EXIT_FAIL)
