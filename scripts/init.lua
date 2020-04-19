-- Load configuration options up front
ScriptHost:LoadScript("scripts/settings.lua")

-- Are we using a keysanity variant?
IS_KEYSANITY = string.find(Tracker.ActiveVariantUID, "keys") ~= nil

-- Access logic
ScriptHost:LoadScript("scripts/logic.lua")

-- Items
Tracker:AddItems("items/common.json")
if IS_KEYSANITY then
    Tracker:AddItems("items/dungeon_items_keysanity.json")
else
    Tracker:AddItems("items/dungeon_items_standard.json")
end
Tracker:AddItems("items/keys.json")
Tracker:AddItems("items/labels.json")

-- Maps
Tracker:AddMaps("maps/maps.json")

-- Locations (load doors first for portal logic)
if IS_KEYSANITY then
    Tracker:AddLocations("locations/sm/doors_keysanity.json")
else
    Tracker:AddLocations("locations/sm/doors_standard.json")
end
Tracker:AddLocations("locations/portals.json")
Tracker:AddLocations("locations/alttp/lightworld.json")
Tracker:AddLocations("locations/alttp/darkworld.json")
Tracker:AddLocations("locations/alttp/bothworlds.json")
if IS_KEYSANITY then
    Tracker:AddLocations("locations/alttp/dungeons_keysanity.json")
else
    Tracker:AddLocations("locations/alttp/dungeons_standard.json")
end
Tracker:AddLocations("locations/sm/wreckedship.json")
Tracker:AddLocations("locations/sm/crateria.json")
Tracker:AddLocations("locations/sm/brinstar.json")
Tracker:AddLocations("locations/sm/norfairupper.json")
Tracker:AddLocations("locations/sm/norfairlower.json")
Tracker:AddLocations("locations/sm/maridia.json")

-- Layouts
Tracker:AddLayouts("layouts/common.json")
if IS_KEYSANITY then
    Tracker:AddLayouts("layouts/tracker_keysanity.json")
    Tracker:AddLayouts("layouts/broadcast_keysanity.json")
else
    Tracker:AddLayouts("layouts/tracker_standard.json")
    Tracker:AddLayouts("layouts/broadcast_standard.json")
end

-- Autotracking if supported
if _VERSION == "Lua 5.3" then
    ScriptHost:LoadScript("scripts/autotracking.lua")
else
    print("Autotracking is unsupported by your EmoTracker version, please update to the latest version!")
end
