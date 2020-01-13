--  Load configuration options up front
ScriptHost:LoadScript("scripts/settings.lua")

ScriptHost:LoadScript("scripts/logic.lua")

if _VERSION == "Lua 5.3" then
    ScriptHost:LoadScript("scripts/autotracking.lua")
else
    print("Auto-tracker is unsupported by your tracker version")
end
