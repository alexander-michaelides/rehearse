--!strict
-- Unit tests for the pure modules (Spec.declare, Plan, Report, Expect). Run: lune run tests/run
local process = require("@lune/process")

local Spec = require("../src/Spec")
local Plan = require("../src/Plan")
local Report = require("../src/Report")
local Expect = require("../src/Expect")

local passed, failed = 0, 0

-- assert() without a message, so tests stay short (selene wants a message on assert).
local function check(cond: any, msg: string?)
	if not cond then
		error(msg or "check failed", 2)
	end
end
local function test(name: string, fn: () -> ())
	local ok, err = pcall(fn)
	if ok then
		passed += 1
	else
		failed += 1
		print(`FAIL {name}\n  {err}`)
	end
end

local function throws(fn: () -> (), pattern: string?)
	local ok, err = pcall(fn)
	check(not ok, "expected an error")
	if pattern then
		check(string.find(tostring(err), pattern, 1, true), `error "{err}" does not contain "{pattern}"`)
	end
end

local noop = function() end

-- Spec.declare ------------------------------------------------------------------------

test("declare collects players, tests and options", function()
	local d = Spec.declare("Lobby", function(s)
		s.players(3)
		s.test("a", noop)
		s.test("b", { timeout = 5, isolated = true }, noop)
		s.skip("c", noop)
		s.only("d", noop)
	end)
	check(d.players == 3)
	check(#d.tests == 4)
	check(d.tests[1].timeout == Spec.DEFAULT_TIMEOUT)
	check(d.tests[2].timeout == 5 and d.tests[2].isolated)
	check(d.tests[3].skip and not d.tests[3].only)
	check(d.tests[4].only)
end)

test("declare validates input", function()
	throws(function()
		Spec.declare("X", function(s)
			s.players(9)
		end)
	end, "players(n)")
	throws(function()
		Spec.declare("X", function(s)
			s.test("dup", noop)
			s.test("dup", noop)
		end)
	end, "declared twice")
	throws(function()
		Spec.declare("X", function(s)
			s.devices({ { id = "iphone_7", orientation = "Sideways" } })
		end)
	end, "orientation")
	throws(function()
		Spec.declare("X", 42)
	end, "must return a function")
end)

test("declare collects error options", function()
	local d = Spec.declare("X", function(s)
		s.failOnErrors()
		s.ignoreErrors({ "^Known noise", "Deprecated" })
		s.test("t", noop)
	end)
	check(d.failOnErrors)
	check(#d.ignoreErrors == 2 and d.ignoreErrors[1] == "^Known noise")
	throws(function()
		Spec.declare("X", function(s)
			s.ignoreErrors({ 42 })
		end)
	end, "patterns must be strings")
end)

test("plan carries test timeouts for the session watchdog", function()
	local p = Plan.build({
		Spec.declare("A", function(s)
			s.test("slow", { timeout = 90 }, noop)
			s.test("fast", noop)
		end),
	})
	check(p.sessions[1].tests[1].timeout == 90 and p.sessions[1].tests[2].timeout == Spec.DEFAULT_TIMEOUT)
end)

test("declare collects hooks, devices and client functions", function()
	local d = Spec.declare("X", function(s)
		s.isolated()
		s.devices({ "iphone_7", { id = "ipad_a16", orientation = "Portrait" } })
		s.beforeEach(noop)
		s.afterEach(noop)
		s.client("read", noop)
		s.test("t", noop)
	end)
	check(d.isolated)
	check(#d.devices == 2 and d.devices[1].id == "iphone_7" and d.devices[2].orientation == "Portrait")
	check(#d.beforeEach == 1 and #d.afterEach == 1)
	check(d.clientFns.read == noop)
end)

-- Plan --------------------------------------------------------------------------------

local function decl(name: string, body: (any) -> ())
	return Spec.declare(name, body)
end

test("plan shares one session per spec by default", function()
	local p = Plan.build({
		decl("A", function(s)
			s.players(2)
			s.test("one", noop)
			s.test("two", noop)
		end),
	})
	check(#p.sessions == 1)
	check(p.sessions[1].players == 2)
	check(#p.sessions[1].tests == 2 and p.sessions[1].tests[2].index == 2)
end)

test("plan gives isolated tests their own sessions", function()
	local p = Plan.build({
		decl("A", function(s)
			s.test("one", noop)
			s.test("two", { isolated = true }, noop)
			s.test("three", noop)
		end),
		decl("B", function(s)
			s.isolated()
			s.test("x", noop)
			s.test("y", noop)
		end),
	})
	check(#p.sessions == 4, `got {#p.sessions}`)
	check(#p.sessions[1].tests == 2) -- one + three share
	check(p.sessions[2].tests[1].name == "two")
	check(p.sessions[3].spec == "B" and p.sessions[4].spec == "B")
end)

test("plan repeats a spec per device", function()
	local p = Plan.build({
		decl("M", function(s)
			s.devices({ "iphone_7", "ipad_a16" })
			s.test("fits", noop)
		end),
	})
	check(#p.sessions == 2)
	check(p.sessions[1].device.id == "iphone_7" and p.sessions[2].device.id == "ipad_a16")
end)

test("plan honours skip, only and grep", function()
	local specs = {
		decl("A", function(s)
			s.test("alpha", noop)
			s.skip("beta", noop)
		end),
		decl("B", function(s)
			s.test("gamma", noop)
		end),
	}
	local p = Plan.build(specs, { grep = "GAMMA" })
	check(#p.sessions == 1 and p.sessions[1].spec == "B")
	check(#p.skipped == 2)

	local withOnly = Plan.build({
		decl("A", function(s)
			s.test("alpha", noop)
			s.only("focus", noop)
		end),
	})
	check(#withOnly.sessions == 1 and #withOnly.sessions[1].tests == 1)
	check(withOnly.skipped[1].reason == "not marked only")
end)

-- Report ------------------------------------------------------------------------------

local function sample()
	local r = {
		runId = "r1",
		seconds = 12.5,
		sessions = {
			{
				spec = "Lobby",
				players = 2,
				status = "ran",
				sessionSeconds = 11,
				tests = {
					{ name = "ok", status = "pass", ms = 10 },
					{ name = 'bad <"&">', status = "fail", ms = 20, error = "expected: 1 to be 2", logs = { "hi" } },
				},
			},
			{
				spec = "Mobile",
				device = { id = "iphone_7" },
				players = 1,
				status = "error",
				error = "timed out waiting for 1 client agent(s)",
				tests = { { name = "fits", status = "error" } },
			},
		},
		skippedTests = { { spec = "Lobby", name = "later", reason = "skipped" } },
	}
	Report.tally(r)
	return r
end

test("tally counts statuses", function()
	local r = sample()
	check(r.passed == 1 and r.failed == 1 and r.errors == 1 and r.skipped == 1)
	check(r.ok == false)
end)

test("reports include game script errors", function()
	local r = sample()
	r.sessions[1].tests[2].gameErrors = { "client(1): boom" }
	r.sessions[1].tests[1].gameErrors = { "server: noisy" }
	local text = Report.text(r)
	check(string.find(text, "script error: client(1): boom", 1, true), text)
	check(string.find(text, "ok (10ms, 1 game error(s))", 1, true), text)
	check(string.find(Report.junit(r), "<system-err>client(1): boom</system-err>", 1, true))
end)

test("text report shows failures and session errors", function()
	local text = Report.text(sample())
	check(string.find(text, "Rehearse FAILED: 1 passed, 1 failed, 1 errors, 1 skipped", 1, true), text)
	check(string.find(text, "Mobile [iphone_7]", 1, true), text)
	check(string.find(text, "expected: 1 to be 2", 1, true), text)
	check(string.find(text, "| hi", 1, true), text)
end)

test("junit report escapes and counts", function()
	local xml = Report.junit(sample())
	check(string.find(xml, 'tests="4" failures="1" errors="1" skipped="1"', 1, true), xml)
	check(string.find(xml, "bad &lt;&quot;&amp;&quot;&gt;", 1, true), xml)
	check(string.find(xml, '<skipped message="skipped"/>', 1, true), xml)
	check(string.find(xml, '<testsuite name="Mobile [iphone_7]"', 1, true), xml)
	check(not string.find(xml, '<"&">', 1, true))
end)

-- Expect ------------------------------------------------------------------------------

test("expect matchers", function()
	Expect(1).toBe(1)
	Expect({ a = { 1, 2 } }).toEqual({ a = { 1, 2 } })
	Expect("hello").toContain("ell")
	Expect(1.0001).toBeNear(1, 0.01)
	Expect(nil).toBeFalsy()
	Expect(1).never.toBe(2)
	throws(function()
		Expect(1).toBe(2)
	end, "expected: 1 to be 2")
	throws(function()
		Expect(1).never.toBe(1)
	end, "expected NOT")
end)

print(`{passed} passed, {failed} failed`)
process.exit(if failed == 0 then 0 else 1)
