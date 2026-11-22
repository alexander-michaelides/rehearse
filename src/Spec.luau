--!strict
--[=[
	@class Spec

	Loads a spec module and collects its declarations without running test bodies.

	A spec module returns a function that receives a declaration API:

	```lua
	return function(s)
		s.players(2)
		s.beforeEach(function(t) ... end)
		s.test("both players see the menu", function(t) ... end)
		s.client("readCoins", function() ... end) -- runs on the client via client:call("readCoins")
	end
	```

	`Spec.declare` is pure (no Roblox APIs), so it is unit-tested under Lune.
]=]

export type TestFn = (any) -> ()
export type TestDecl = {
	name: string,
	fn: TestFn,
	timeout: number,
	skip: boolean,
	only: boolean,
	isolated: boolean,
}
export type DeviceDecl = { id: string, orientation: string? }
export type SpecDecl = {
	name: string,
	players: number,
	isolated: boolean,
	devices: { DeviceDecl },
	beforeEach: { TestFn },
	afterEach: { TestFn },
	clientFns: { [string]: (...any) -> ...any },
	tests: { TestDecl },
}

local Spec = {}

Spec.DEFAULT_TIMEOUT = 30

local ORIENTATIONS = { Portrait = true, LandscapeLeft = true, LandscapeRight = true }

local function parseDevice(d: any): DeviceDecl
	if type(d) == "string" then
		return { id = d }
	end
	assert(
		type(d) == "table" and type(d.id) == "string",
		"device must be an id string or { id = ..., orientation = ... }"
	)
	if d.orientation ~= nil then
		assert(
			ORIENTATIONS[d.orientation],
			`orientation must be Portrait, LandscapeLeft or LandscapeRight (got {d.orientation})`
		)
	end
	return { id = d.id, orientation = d.orientation }
end

--[=[
	Runs a spec function against the declaration API and returns what it declared.
	Test bodies, hooks and client functions are collected, not run.
]=]
function Spec.declare(name: string, specFn: any): SpecDecl
	if type(specFn) ~= "function" then
		error(`spec {name} must return a function`, 0)
	end
	local decl: SpecDecl = {
		name = name,
		players = 1,
		isolated = false,
		devices = {},
		beforeEach = {},
		afterEach = {},
		clientFns = {},
		tests = {},
	}
	local api = {}

	function api.players(n: number)
		assert(
			type(n) == "number" and n >= 1 and n <= 8 and n % 1 == 0,
			"players(n) must be a whole number from 1 to 8"
		)
		decl.players = n
	end

	-- Every test in this spec gets a fresh test session (slower, but no shared state).
	function api.isolated()
		decl.isolated = true
	end

	-- Run the spec once per device. Accepts device ids from
	-- StudioDeviceSimulatorService:GetDeviceListAsync() or { id = ..., orientation = "Portrait" }.
	function api.devices(list: { any })
		assert(type(list) == "table" and #list > 0, "devices(list) needs at least one device")
		decl.devices = {}
		for _, d in list do
			table.insert(decl.devices, parseDevice(d))
		end
	end

	function api.device(d: any)
		api.devices({ d })
	end

	function api.beforeEach(fn: TestFn)
		assert(type(fn) == "function", "beforeEach needs a function")
		table.insert(decl.beforeEach, fn)
	end

	function api.afterEach(fn: TestFn)
		assert(type(fn) == "function", "afterEach needs a function")
		table.insert(decl.afterEach, fn)
	end

	-- Registers a function that runs inside a client, called with client:call(fnName, ...).
	function api.client(fnName: string, fn: (...any) -> ...any)
		assert(type(fnName) == "string" and type(fn) == "function", "client(name, fn) needs a name and a function")
		assert(decl.clientFns[fnName] == nil, `client function "{fnName}" is declared twice`)
		decl.clientFns[fnName] = fn
	end

	local function addTest(testName: string, a: any, b: any?, flags: { skip: boolean?, only: boolean? })
		-- (name, fn) or (name, { timeout = 10, isolated = true, skip = true, only = true }, fn)
		local opts, fn = {}, a
		if type(a) == "table" then
			opts, fn = a, b
		end
		assert(type(testName) == "string", "test name must be a string")
		assert(type(fn) == "function", `test "{testName}" needs a function`)
		for _, existing in decl.tests do
			assert(existing.name ~= testName, `test "{testName}" is declared twice in {name}`)
		end
		local timeout = opts.timeout or Spec.DEFAULT_TIMEOUT
		assert(type(timeout) == "number" and timeout > 0, `test "{testName}": timeout must be a positive number`)
		table.insert(decl.tests, {
			name = testName,
			fn = fn,
			timeout = timeout,
			skip = flags.skip or opts.skip == true,
			only = flags.only or opts.only == true,
			isolated = opts.isolated == true,
		})
	end

	function api.test(testName: string, a: any, b: any?)
		addTest(testName, a, b, {})
	end
	function api.skip(testName: string, a: any, b: any?)
		addTest(testName, a, b, { skip = true })
	end
	function api.only(testName: string, a: any, b: any?)
		addTest(testName, a, b, { only = true })
	end

	specFn(api)
	return decl
end

--[=[
	Requires a spec ModuleScript (fresh copy, so edits since the last run are picked up)
	and declares it.
]=]
function Spec.load(module: ModuleScript, inPlace: boolean?): SpecDecl
	-- require caches by instance, so require a clone to pick up edits.
	-- Inside a test session (a throwaway DataModel) the clone is parented next to
	-- the original so `script.Parent` requires work. In Edit it stays unparented,
	-- so the user's place is never modified.
	local copy = module:Clone()
	if inPlace then
		copy.Parent = module.Parent
	end
	local ok, specFn = pcall(require, copy)
	copy:Destroy()
	if not ok then
		error(`failed to load spec {module.Name}: {specFn}`, 0)
	end
	return Spec.declare(module.Name, specFn)
end

function Spec.folder(): Folder?
	local f = game:GetService("ServerStorage"):FindFirstChild("RehearseSpecs")
	return if f and f:IsA("Folder") then f else nil
end

--[=[
	Spec ModuleScripts under ServerStorage.RehearseSpecs, sorted by full name.
	`filter` is a plain substring match on the module name. ModuleScripts whose
	name starts with "_" are treated as helpers, not specs.
]=]
function Spec.modules(filter: string?): { ModuleScript }
	local out = {}
	local f = Spec.folder()
	if not f then
		return out
	end
	for _, m in f:GetDescendants() do
		if
			m:IsA("ModuleScript")
			and string.sub(m.Name, 1, 1) ~= "_"
			and not (m.Parent and m.Parent:IsA("ModuleScript")) -- children of a spec are its helpers
			and (filter == nil or string.find(m.Name, filter, 1, true) ~= nil)
		then
			table.insert(out, m)
		end
	end
	table.sort(out, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)
	return out
end

return Spec
