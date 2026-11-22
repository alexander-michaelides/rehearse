--!strict
-- Minimal Jest-style assertions: expect(actual).toBe(expected), .never.toBe(...), etc.

local function fmt(v: any): string
	if type(v) == "string" then
		return string.format("%q", v)
	end
	return tostring(v)
end

local function deepEqual(a: any, b: any): boolean
	if a == b then
		return true
	end
	if type(a) ~= "table" or type(b) ~= "table" then
		return false
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

local function build(actual: any, negate: boolean)
	local m = {}
	local function check(pass: boolean, msg: string)
		if pass == negate then
			error((if negate then "expected NOT: " else "expected: ") .. msg, 3)
		end
	end
	function m.toBe(expected: any)
		check(actual == expected, `{fmt(actual)} to be {fmt(expected)}`)
	end
	function m.toEqual(expected: any)
		check(deepEqual(actual, expected), `{fmt(actual)} to deep-equal {fmt(expected)}`)
	end
	function m.toBeTruthy()
		check(not not actual, `{fmt(actual)} to be truthy`)
	end
	function m.toBeFalsy()
		check(not actual, `{fmt(actual)} to be falsy`)
	end
	function m.toBeNear(expected: number, tolerance: number?)
		check(math.abs(actual - expected) <= (tolerance or 1e-3), `{fmt(actual)} to be within {tolerance or 1e-3} of {fmt(expected)}`)
	end
	function m.toContain(item: any)
		local found = false
		if type(actual) == "string" then
			found = string.find(actual, item, 1, true) ~= nil
		elseif type(actual) == "table" then
			found = table.find(actual, item) ~= nil
		end
		check(found, `{fmt(actual)} to contain {fmt(item)}`)
	end
	return m
end

return function(actual: any)
	local m = build(actual, false)
	m.never = build(actual, true)
	return m
end
