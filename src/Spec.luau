--!strict
-- Loads a spec module and collects its declarations without running test bodies.
--
-- A spec module returns a function that receives a declaration API:
--
--   return function(s)
--       s.players(2)
--       s.test("both players see the menu", function(t) ... end)
--   end

export type TestFn = (any) -> ()
export type TestDecl = { name: string, fn: TestFn, timeout: number }
export type SpecDecl = { name: string, players: number, tests: { TestDecl } }

local Spec = {}

Spec.DEFAULT_TIMEOUT = 30

function Spec.load(module: ModuleScript): SpecDecl
	-- Clone before requiring so edits made since the last run are picked up
	-- (require caches by instance).
	local copy = module:Clone()
	local ok, specFn = pcall(require, copy)
	copy:Destroy()
	if not ok then
		error(`failed to load spec {module.Name}: {specFn}`, 0)
	end
	if type(specFn) ~= "function" then
		error(`spec {module.Name} must return a function`, 0)
	end

	local decl: SpecDecl = { name = module.Name, players = 1, tests = {} }
	local api = {}
	function api.players(n: number)
		assert(type(n) == "number" and n >= 1 and n <= 8, "players(n) must be between 1 and 8")
		decl.players = n
	end
	function api.test(name: string, a: any, b: any?)
		-- s.test(name, fn) or s.test(name, { timeout = 10 }, fn)
		local opts, fn = {}, a
		if type(a) == "table" then
			opts, fn = a, b
		end
		assert(type(fn) == "function", `test "{name}" needs a function`)
		table.insert(decl.tests, { name = name, fn = fn, timeout = opts.timeout or Spec.DEFAULT_TIMEOUT })
	end
	specFn(api)
	return decl
end

function Spec.folder(): Folder?
	local f = game:GetService("ServerStorage"):FindFirstChild("RehearseSpecs")
	return if f and f:IsA("Folder") then f else nil
end

function Spec.modules(filter: string?): { ModuleScript }
	local out = {}
	local f = Spec.folder()
	if not f then
		return out
	end
	for _, m in f:GetDescendants() do
		if m:IsA("ModuleScript") and (filter == nil or string.find(m.Name, filter, 1, true)) then
			table.insert(out, m)
		end
	end
	table.sort(out, function(a, b)
		return a:GetFullName() < b:GetFullName()
	end)
	return out
end

return Spec
