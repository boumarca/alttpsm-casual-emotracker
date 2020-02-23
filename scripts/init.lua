--  Load configuration options up front
ScriptHost:LoadScript("scripts/constants.lua")
ScriptHost:LoadScript("scripts/settings.lua")

-- TODO: Access logic scripts
ScriptHost:LoadScript("scripts/logic/common.lua")
ScriptHost:LoadScript("scripts/logic/alttp/dungeons.lua")
ScriptHost:LoadScript("scripts/logic/sm/wreckedship.lua")

-- Items
Tracker:AddItems("items/items.json")

-- Maps
Tracker:AddMaps("maps/maps.json")

-- TODO: Locations
Tracker:AddLocations("locations/sm/wreckedship.json")

-- Layouts
Tracker:AddLayouts("layouts/tracker.json")
Tracker:AddLayouts("layouts/broadcast.json")

-- Autotracking if supported
if _VERSION == "Lua 5.3" then
    ScriptHost:LoadScript("scripts/autotracking.lua")
else
    print("Autotracking is unsupported by your EmoTracker version, please update to the latest version!")
end
