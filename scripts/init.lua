-- Load configuration options up front
ScriptHost:LoadScript("scripts/constants.lua")
ScriptHost:LoadScript("scripts/settings.lua")

-- Access logic
ScriptHost:LoadScript("scripts/logic.lua")

-- Items
Tracker:AddItems("items/common.json")
Tracker:AddItems("items/dungeon_items.json")
Tracker:AddItems("items/keys.json")
Tracker:AddItems("items/labels.json")

-- Maps
Tracker:AddMaps("maps/maps.json")

-- Locations
Tracker:AddLocations("locations/portals.json")
Tracker:AddLocations("locations/alttp/lightworld.json")
Tracker:AddLocations("locations/alttp/darkworld.json")
Tracker:AddLocations("locations/alttp/dungeons.json")
Tracker:AddLocations("locations/sm/crateria.json")
Tracker:AddLocations("locations/sm/brinstar.json")
Tracker:AddLocations("locations/sm/norfairupper.json")
Tracker:AddLocations("locations/sm/norfairlower.json")
Tracker:AddLocations("locations/sm/maridia.json")
Tracker:AddLocations("locations/sm/wreckedship.json")

-- Layouts
Tracker:AddLayouts("layouts/common.json")
Tracker:AddLayouts("layouts/tracker.json")
Tracker:AddLayouts("layouts/broadcast.json")

-- Autotracking if supported
if _VERSION == "Lua 5.3" then
    ScriptHost:LoadScript("scripts/autotracking.lua")
else
    print("Autotracking is unsupported by your EmoTracker version, please update to the latest version!")
end
