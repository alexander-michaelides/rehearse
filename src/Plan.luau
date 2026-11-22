--!strict
--[=[
	@class Plan

	Turns declared specs into the list of test sessions to launch. Pure, so it is
	unit-tested under Lune.

	- Tests in a spec share one session by default (one ~10s startup per spec).
	- `s.isolated()` or `{ isolated = true }` gives a test its own fresh session.
	- `s.devices({...})` repeats the spec once per device.
	- `skip`, `only` and the run's `grep` decide which tests run at all.
]=]

local Plan = {}

export type Device = { id: string, orientation: string? }
export type PlannedTest = { index: number, name: string, timeout: number }
export type Session = {
	specIndex: number,
	spec: string,
	players: number,
	device: Device?,
	tests: { PlannedTest },
}
export type Skipped = { spec: string, name: string, device: Device?, reason: string }
export type PlanResult = { sessions: { Session }, skipped: { Skipped } }

local function matches(grep: string?, specName: string, testName: string): boolean
	if grep == nil or grep == "" then
		return true
	end
	local haystack = string.lower(specName .. " > " .. testName)
	return string.find(haystack, string.lower(grep), 1, true) ~= nil
end

--[=[
	`specs` is a list of declarations (see Spec.SpecDecl; only the fields used here are required).
]=]
function Plan.build(specs: { any }, opts: { grep: string? }?): PlanResult
	local grep = opts and opts.grep
	local anyOnly = false
	for _, decl in specs do
		for _, t in decl.tests do
			if t.only and not t.skip then
				anyOnly = true
			end
		end
	end

	local sessions: { Session } = {}
	local skipped: { Skipped } = {}

	for specIndex, decl in specs do
		local devices: { Device? } = if #decl.devices > 0 then table.clone(decl.devices) else { false :: any }
		for _, d in devices do
			local device: Device? = if d then d else nil
			local shared: Session? = nil
			for index, t in decl.tests do
				local reason = if t.skip
					then "skipped"
					elseif anyOnly and not t.only then "not marked only"
					elseif not matches(grep, decl.name, t.name) then "filtered out"
					else nil
				if reason then
					table.insert(skipped, { spec = decl.name, name = t.name, device = device, reason = reason })
					continue
				end
				local planned = { index = index, name = t.name, timeout = t.timeout or 30 }
				if decl.isolated or t.isolated then
					table.insert(sessions, {
						specIndex = specIndex,
						spec = decl.name,
						players = decl.players,
						device = device,
						tests = { planned },
					})
				else
					if not shared then
						local s: Session = {
							specIndex = specIndex,
							spec = decl.name,
							players = decl.players,
							device = device,
							tests = {},
						}
						shared = s
						table.insert(sessions, s)
					end
					table.insert((shared :: Session).tests, planned)
				end
			end
		end
	end

	return { sessions = sessions, skipped = skipped }
end

function Plan.deviceLabel(device: Device?): string?
	if not device then
		return nil
	end
	return if device.orientation then `{device.id}, {device.orientation}` else device.id
end

return Plan
