--!strict
--[=[
	@class Report

	Formats a run report as human-readable text or JUnit XML. Pure (no Roblox
	APIs), so the plugin and the Lune CLI share it.

	Report shape:
	```
	{
		ok, passed, failed, errors, skipped, seconds, runId, error?,
		sessions = { { spec, players, device?, status = "ran" | "error", error?, attempts,
		               sessionSeconds, joinSeconds?, tests = { { name, status = "pass" | "fail" | "error", ms, error?, logs? } } } },
		skippedTests = { { spec, name, device?, reason } },
	}
	```
]=]

local Report = {}

local function deviceLabel(device: any): string?
	if type(device) ~= "table" then
		return nil
	end
	return if device.orientation then `{device.id}, {device.orientation}` else device.id
end

function Report.sessionLabel(session: any): string
	local d = deviceLabel(session.device)
	return if d then `{session.spec} [{d}]` else session.spec
end

local ICON = { pass = "✓", fail = "✗", error = "!" }

function Report.text(report: any): string
	local verdict = if report.ok then "PASSED" else "FAILED"
	local lines = {
		`Rehearse {verdict}: {report.passed or 0} passed, {report.failed or 0} failed, {report.errors or 0} errors, {report.skipped or 0} skipped ({report.seconds or 0}s)`,
	}
	if report.error then
		table.insert(lines, `  error: {report.error}`)
	end
	for _, s in report.sessions or {} do
		local meta = `{s.players or "?"}p, {s.sessionSeconds or "?"}s`
		if (s.attempts or 1) > 1 then
			meta ..= `, {s.attempts} attempts`
		end
		if s.replacedClients then
			meta ..= `, {s.replacedClients} client(s) replaced`
		end
		table.insert(lines, `  {Report.sessionLabel(s)} [{meta}]{if s.error then " ERROR: " .. s.error else ""}`)
		for _, t in s.tests or {} do
			if t.status == "error" and s.error then
				table.insert(lines, `    {ICON.error} {t.name} (not run)`)
				continue
			end
			local errCount = if t.gameErrors then #t.gameErrors else 0
			local suffix = if errCount > 0 and t.status == "pass" then `, {errCount} game error(s)` else ""
			table.insert(lines, `    {ICON[t.status] or "?"} {t.name} ({t.ms or 0}ms{suffix})`)
			if t.error then
				table.insert(lines, `        {t.error}`)
			end
			if t.status ~= "pass" and t.gameErrors then
				for _, e in t.gameErrors do
					table.insert(lines, `        script error: {e}`)
				end
			end
			if t.status ~= "pass" and t.logs then
				for _, l in t.logs do
					table.insert(lines, `        | {l}`)
				end
			end
		end
	end
	return table.concat(lines, "\n")
end

local function xmlEscape(s: any): string
	local str = tostring(s)
	str = string.gsub(str, "&", "&amp;")
	str = string.gsub(str, "<", "&lt;")
	str = string.gsub(str, ">", "&gt;")
	str = string.gsub(str, '"', "&quot;")
	str = string.gsub(str, "'", "&apos;")
	-- Strip control characters that are illegal in XML 1.0.
	str = string.gsub(str, "[%z\1-\8\11\12\14-\31]", "")
	return str
end

function Report.junit(report: any): string
	local out = {
		'<?xml version="1.0" encoding="UTF-8"?>',
		`<testsuites name="Rehearse" tests="{(report.passed or 0) + (report.failed or 0) + (report.errors or 0) + (report.skipped or 0)}" failures="{report.failed or 0}" errors="{report.errors or 0}" skipped="{report.skipped or 0}" time="{report.seconds or 0}">`,
	}
	local skippedBySuite: { [string]: { any } } = {}
	for _, t in report.skippedTests or {} do
		local label = Report.sessionLabel(t)
		skippedBySuite[label] = skippedBySuite[label] or {}
		table.insert(skippedBySuite[label], t)
	end

	local function suite(label: string, session: any?, tests: { any }, skippedTests: { any })
		local failures, errors = 0, 0
		for _, t in tests do
			if t.status == "fail" then
				failures += 1
			elseif t.status == "error" then
				errors += 1
			end
		end
		table.insert(
			out,
			`  <testsuite name="{xmlEscape(label)}" tests="{#tests + #skippedTests}" failures="{failures}" errors="{errors}" skipped="{#skippedTests}" time="{if session
				then session.sessionSeconds or 0
				else 0}">`
		)
		for _, t in tests do
			local attrs = `classname="{xmlEscape(label)}" name="{xmlEscape(t.name)}" time="{(t.ms or 0) / 1000}"`
			if t.status == "pass" then
				table.insert(out, `    <testcase {attrs}/>`)
			else
				local tag = if t.status == "fail" then "failure" else "error"
				local message = t.error or (session and session.error) or t.status
				table.insert(out, `    <testcase {attrs}>`)
				table.insert(out, `      <{tag} message="{xmlEscape(message)}">{xmlEscape(message)}</{tag}>`)
				if t.logs then
					table.insert(out, `      <system-out>{xmlEscape(table.concat(t.logs, "\n"))}</system-out>`)
				end
				if t.gameErrors then
					table.insert(out, `      <system-err>{xmlEscape(table.concat(t.gameErrors, "\n"))}</system-err>`)
				end
				table.insert(out, `    </testcase>`)
			end
		end
		for _, t in skippedTests do
			table.insert(
				out,
				`    <testcase classname="{xmlEscape(label)}" name="{xmlEscape(t.name)}" time="0"><skipped message="{xmlEscape(
					t.reason
				)}"/></testcase>`
			)
		end
		table.insert(out, "  </testsuite>")
	end

	local seen: { [string]: boolean } = {}
	for _, s in report.sessions or {} do
		local label = Report.sessionLabel(s)
		local skippedTests = if seen[label] then {} else (skippedBySuite[label] or {})
		seen[label] = true
		suite(label, s, s.tests or {}, skippedTests)
	end
	for label, skippedTests in skippedBySuite do
		if not seen[label] then
			suite(label, nil, {}, skippedTests)
		end
	end
	if report.error then
		suite("Rehearse", nil, { { name = "run", status = "error", error = report.error } }, {})
	end
	table.insert(out, "</testsuites>")
	return table.concat(out, "\n") .. "\n"
end

--[=[
	Recomputes the counters and `ok` from sessions, skipped tests and the run error.
]=]
function Report.tally(report: any)
	local passed, failed, errors = 0, 0, 0
	for _, s in report.sessions or {} do
		for _, t in s.tests or {} do
			if t.status == "pass" then
				passed += 1
			elseif t.status == "fail" then
				failed += 1
			else
				errors += 1
			end
		end
	end
	if report.error then
		errors += 1
	end
	report.passed, report.failed, report.errors = passed, failed, errors
	report.skipped = #(report.skippedTests or {})
	report.ok = failed == 0 and errors == 0
end

return Report
