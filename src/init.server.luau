--!strict
-- Rehearse plugin entry point.
-- Studio loads plugins into every DataModel, so the same plugin plays three roles:
--   Edit   -> Launcher: finds specs, starts multiplayer test sessions, collects reports
--   Server -> Runner:   runs the spec inside the test session and drives clients
--   Client -> Agent:    performs input (VirtualInput) and reads client-side state

local RunService = game:GetService("RunService")

if RunService:IsEdit() then
	require(script.Launcher).start(plugin)
elseif RunService:IsServer() then
	require(script.Runner).start()
elseif RunService:IsClient() then
	require(script.Agent).start()
end
