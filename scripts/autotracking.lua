-- Configuration --------------------------------------
AUTOTRACKER_ENABLE_DEBUG_LOGGING = false
AUTOTRACKER_ENABLE_DEBUG_DUNGEON_LOGGING = false
AUTOTRACKER_ENABLE_DEBUG_ERROR_LOGGING = false
SHOW_DUNGEON_DEBUG_LOGGING = AUTOTRACKER_ENABLE_DEBUG_LOGGING or AUTOTRACKER_ENABLE_DEBUG_DUNGEON_LOGGING
SHOW_ERROR_DEBUG_LOGGING = AUTOTRACKER_ENABLE_DEBUG_LOGGING or AUTOTRACKER_ENABLE_DEBUG_ERROR_LOGGING

-- Are we using a Bizhawk-specific variant?  This matters for memory addressing, until we get a new connectorlib.
BIZHAWK_MODE = string.find(Tracker.ActiveVariantUID, "bizhawk") ~= nil
-------------------------------------------------------

-- Some useful stuff for reference from Z3SM ASM GitHub repo: https://github.com/tewtal/alttp_sm_combo_randomizer_rom
-- !SRAM_ALTTP_START = $a06000
-- !SRAM_SM_START = $a16010
--
-- LTTP SRAM in bank 0xa06000
-- SM SRAM in bank 0xa16000, file 1 starts $10 bytes after the beginning!
--
-- For mapping the SRAM address for SD2SNES, the usb2snes protocol works differently!
-- See: https://github.com/Skarsnik/QUsb2snes/blob/master/docs/Procotol.md#usb2snes-address
-- ROM starts at 0x000000
-- WRAM starts at 0xF50000
-- SRAM starts at 0xE00000
--
-- For WRAM, we can address banks 0x7e and 0x7f directly with connectorlib currently.  In a future update, we *should*
-- be able to directly address the SRAM banks but currently we have to use the bank 0xe0 mapping instead.
-- See the getSRAMAddressLTTP() and getSRAMAddressSM() functions below for the mapping math.

print("")
print("Active Auto-Tracker Configuration")
print("---------------------------------------------------------------------")
if IS_KEYSANITY then
    print("Keysanity Mode enabled")
end
if BIZHAWK_MODE then
    print("Bizhawk Mode enabled")
end
if AUTOTRACKER_ENABLE_ITEM_TRACKING then
    print("Item Tracking enabled")
end
if AUTOTRACKER_ENABLE_LOCATION_TRACKING then
    print("Location Tracking enabled")
end
if AUTOTRACKER_ENABLE_DUNGEON_TRACKING then
    print("Dungeon Tracking enabled")
end
if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
    print("Debug Logging enabled")
end
if AUTOTRACKER_ENABLE_DEBUG_DUNGEON_LOGGING then
    print("Debug Dungeon Logging enabled")
end
if AUTOTRACKER_ENABLE_DEBUG_ERROR_LOGGING then
    print("Debug Error Logging enabled")
end
print("---------------------------------------------------------------------")
print("")

-- Offset for different memory addressing for LUA vs SD2SNES.
if BIZHAWK_MODE then
    LUA_EXTRA_RAM_OFFSET = 0x0  -- Bizhawk uses the same memory addressing as SD2SNES for now even though it's LUA!
else
    LUA_EXTRA_RAM_OFFSET = 0x314000
end

CONNECTOR_NAME_SD2SNES = "SD2SNES"

AUTOTRACKER_IS_IN_LTTP = false
AUTOTRACKER_IS_IN_SM = false

-- Constants
LTTP = "LTTP"
SM = "SM"

U8_READ_CACHE = 0
U8_READ_CACHE_ADDRESS = 0

U16_READ_CACHE = 0
U16_READ_CACHE_ADDRESS = 0

-- Save memory watch segments in table so we can clear them when switching games.
GAME_WATCH = nil
MEMORY_WATCHES = {}

-- Cached data for doing dungeon tracking logic without cheating.
-- Track inventory data for small keys and dungeon items, plus room data for collected floor keys and opened doors.
OPENED_DOORS = {}
OPENED_CHESTS = {}
DUNGEON_ITEMS = {}
REMAINING_KEYS = {}
FLOOR_KEYS = {}

CURRENT_ROOM_ID = 0
CURRENT_ROOM_DATA = 0x0
SAVED_ROOM_DATA = {}

DUNGEON_DATA_LAST_UPDATE = nil

-- Dungeon room indexes so we can tell what dungeon we're in by the room number.
DUNGEON_ROOMS = {
    hc = { 1, 2, 17, 18, 33, 34, 50, 65, 66, 80, 81, 82, 96, 97, 98, 112, 113, 114, 128, 129, 130 },
    ep = { 153, 168, 169, 170, 184, 185, 186, 200, 201, 216, 217, 218 },
    dp = { 51, 67, 83, 99, 115, 116, 117, 131, 132, 133 },
    toh = { 7, 23, 39, 49, 119, 135, 167 },
    at = { 32, 48, 64, 176, 192, 208, 224 },
    pod = { 9, 10, 11, 25, 26, 27, 42, 43, 58, 59, 74, 75, 90, 106, 137 },
    sp = { 6, 22, 38, 40, 52, 53, 54, 55, 56, 70, 84, 102, 118 },
    sw = { 41, 57, 73, 86, 87, 88, 89, 103, 104 },
    tt = { 68, 69, 100, 101, 171, 172, 187, 188, 203, 204, 219, 220 },
    ip = { 14, 30, 31, 46, 62, 63, 78, 79, 94, 95, 110, 126, 127, 142, 158, 159, 174, 175, 190, 191, 206, 222 },
    mm = { 144, 145, 146, 147, 151, 152, 160, 161, 162, 163, 177, 178, 179, 193, 194, 195, 209, 210 },
    tr = { 4, 19, 20, 21, 35, 36, 164, 180, 181, 182, 183, 196, 197, 198, 199, 213, 214 },
    gt = { 12, 13, 28, 29, 61, 76, 77, 91, 92, 93, 107, 108, 109, 123, 124, 125, 139, 140, 141, 149, 150, 155, 156, 157, 165, 166 },
}

-- ************************** Table helper functions for debug printing

function table.val_to_str ( v )
    if "string" == type( v ) then
        v = string.gsub( v, "\n", "\\n" )
        if string.match( string.gsub(v,"[^'\"]",""), '^"+$' ) then
            return "'" .. v .. "'"
        end
        return '"' .. string.gsub(v,'"', '\\"' ) .. '"'
    else
        return "table" == type( v ) and table.tostring( v ) or
                tostring( v )
    end
end

function table.key_to_str ( k )
    if "string" == type( k ) and string.match( k, "^[_%a][_%a%d]*$" ) then
        return k
    else
        return "[" .. table.val_to_str( k ) .. "]"
    end
end

function table.tostring( tbl )
    local result, done = {}, {}
    for k, v in ipairs( tbl ) do
        table.insert( result, table.val_to_str( v ) )
        done[ k ] = true
    end
    for k, v in pairs( tbl ) do
        if not done[ k ] then
            table.insert( result,
                    table.key_to_str( k ) .. "=" .. table.val_to_str( v ) )
        end
    end
    return "{" .. table.concat( result, "," ) .. "}"
end

function table.has_value(tbl, value)
    for _, v in ipairs(tbl) do
        if v == value then
            return true
        end
    end
    return false
end

-- ************************** Memory reading helper functions

function InvalidateReadCaches()
    U8_READ_CACHE_ADDRESS = 0
    U16_READ_CACHE_ADDRESS = 0
end

function ReadU8(segment, address)
    if U8_READ_CACHE_ADDRESS ~= address then
        -- Convert read value to integer.
        U8_READ_CACHE = math.floor(segment:ReadUInt8(address))
        U8_READ_CACHE_ADDRESS = address
    end

    return U8_READ_CACHE
end

function ReadU16(segment, address)
    if U16_READ_CACHE_ADDRESS ~= address then
        -- Convert read value to integer.
        U16_READ_CACHE = math.floor(segment:ReadUInt16(address))
        U16_READ_CACHE_ADDRESS = address
    end

    return U16_READ_CACHE
end

function clearMemoryWatches()
    for _, watch in ipairs(MEMORY_WATCHES) do
        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("Removing previous memory watch:", watch)
        end
        ScriptHost:RemoveMemoryWatch(watch)
    end
    -- Remove all elements from the table to clear it.
    for k in pairs(MEMORY_WATCHES) do
        MEMORY_WATCHES[k] = nil
    end
end

function getSRAMAddressLTTP(offset)
    -- Map SRAM offset to address for LTTP based on which connector we're using.
    -- LTTP SRAM is in bank 0xa06000
    -- SD2SNES connector currently uses usb2snes protocol mapping for SRAM until we can address directly in future!
    -- Bizhawk is...even weirder.  SRAM is mapped to bank 0x700000 in the system bus for whatever reason.
    if AutoTracker.SelectedConnectorType.Name == CONNECTOR_NAME_SD2SNES then
        return 0xe00000 + offset
    elseif BIZHAWK_MODE then
        return 0x700000 + offset
    else
        return 0xa06000 + offset
    end
end

function getSRAMAddressSM(offset)
    -- Map SRAM offset to address for SM based on which connector we're using.
    -- SM SRAM is in bank 0xa16000, and file 1 starts 0x10 bytes after the beginning.
    -- SD2SNES connector currently uses usb2snes protocol mapping for SRAM until we can address directly in future!
    -- Bizhawk is...even weirder.  SRAM is mapped to bank 0x700000 in the system bus for whatever reason.
    if AutoTracker.SelectedConnectorType.Name == CONNECTOR_NAME_SD2SNES then
        return 0xe02010 + offset
    elseif BIZHAWK_MODE then
        return 0x702010 + offset
    else
        return 0xa16010 + offset
    end
end

-- *************************** Game status and memory watches

function updateGame()
    -- Figure out which game we're in.
    InvalidateReadCaches()

    -- Offset for memory addressing of between game mirrored data that is outside the working RAM and save RAM ranges.
    -- The usb2snes connector uses a different mapping than LUA for this currently, but hopefully this will change.
    local cross_game_offset = 0x0
    if AutoTracker.SelectedConnectorType.Name ~= CONNECTOR_NAME_SD2SNES then
        cross_game_offset = LUA_EXTRA_RAM_OFFSET
    end

    local game = whichGameAreWeIn()

    local changingGame = false
    if (game == SM) then
        changingGame = not AUTOTRACKER_IS_IN_SM
        AUTOTRACKER_IS_IN_LTTP = false
        AUTOTRACKER_IS_IN_SM = true
    elseif (game == LTTP) then
        changingGame = not AUTOTRACKER_IS_IN_LTTP
        AUTOTRACKER_IS_IN_LTTP = true
        AUTOTRACKER_IS_IN_SM = false
    else
        -- If we got a bad game value, assume we reset or something and clear all the watches.
        changingGame = true
        AUTOTRACKER_IS_IN_LTTP = false
        AUTOTRACKER_IS_IN_SM = false
    end

    -- If we're changing games, update the memory watches accordingly.  This forces all the data to be refreshed.
    if changingGame then
        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("**** Game change detected: ", game)
        end

        clearMemoryWatches()

        CURRENT_ROOM_ID = nil
        CURRENT_ROOM_DATA = 0x0

        -- Link to the Past
        if AUTOTRACKER_IS_IN_LTTP then
            -- WRAM watches
            -- This first one is a bit of a hack, it's basically a way to get a time interval check on this function.
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP Dungeon Location Update Check", 0x7e0000, 0x1, updateDungeonLocationsFromTimestamp))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP Current Room Data", 0x7e0401, 0x8, updateCurrentRoomDataLTTP))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP Item Data", 0x7ef340, 0x90, updateItemsActiveLTTP))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP NPC Item Data", 0x7ef410, 0x2, updateNPCItemFlagsActiveLTTP))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP Room Data", 0x7ef000, 0x250, updateRoomsActiveLTTP))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP Overworld Event Data", 0x7ef280, 0x82, updateOverworldEventsActiveLTTP))

            -- Extra cross-game RAM watches specifically for items.
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Item Data In LTTP", 0x703900 + cross_game_offset, 0x10, updateItemsInactiveSM))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Ammo Data In LTTP", 0x703920 + cross_game_offset, 0x16, updateAmmoInactiveSM))
            if IS_KEYSANITY then
                table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Key Data In LTTP", 0x703970 + cross_game_offset, 0x02, updateKeycardsInactiveSM))
            end

            -- SRAM watches for things that aren't in cross-game extra RAM.
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Boss Data In LTTP", getSRAMAddressSM(0x68), 0x08, updateSMBossesInactive))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Room Data In LTTP", getSRAMAddressSM(0xb0), 0x20, updateRoomsInactiveSM))

            -- Game completion checks
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP DONE", 0x703506 + cross_game_offset, 0x01, updateLTTPcompletionInLTTP))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM DONE", 0x703402 + cross_game_offset, 0x01, updateSMcompletionInLTTP))

        -- Super Metroid
        elseif AUTOTRACKER_IS_IN_SM then
            -- WRAM watches
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Item Data", 0x7e09a0, 0x10, updateItemsActiveSM))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Ammo Data", 0x7e09c2, 0x16, updateAmmoActiveSM))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Boss Data", 0x7ed828, 0x08, updateSMBossesActive))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Room Data", 0x7ed870, 0x20, updateRoomsActiveSM))
            if IS_KEYSANITY then
                table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Key Data In LTTP", 0x7ed830, 0x02, updateKeycardsActiveSM))
            end

            -- Extra cross-game RAM watches specifically for items.
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP Item Data In SM", 0x703b40 + cross_game_offset, 0x90, updateItemsInactiveLTTP))

            -- SRAM watches for things that aren't in cross-game extra RAM.
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP NPC Item Data In SM", getSRAMAddressLTTP(0x410), 0x2, updateNPCItemFlagsInactiveLTTP))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP Room In SM", getSRAMAddressLTTP(0x0), 0x250, updateRoomsInactiveLTTP))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP Overworld Event Data In SM", getSRAMAddressLTTP(0x280), 0x82, updateOverworldEventsInactiveLTTP))

            -- Game completion checks
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP DONE", 0x703506 + cross_game_offset, 0x01, updateLTTPcompletionInSM))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM DONE", 0x703402 + cross_game_offset, 0x01, updateSMcompletionInSM))

        end
    end

    return true
end

function whichGameAreWeIn()
    local address = 0x7033fe
    if AutoTracker.SelectedConnectorType.Name ~= CONNECTOR_NAME_SD2SNES then
        address = address + LUA_EXTRA_RAM_OFFSET
    end

    local value = AutoTracker:ReadU8(address, 0)
    if (value == 0xFF) then
        return SM
    elseif (value == 0x00) then
        return LTTP
    else
        return nil
    end
end

function isInLTTP()
    return whichGameAreWeIn() == LTTP
end

function isInGameLTTP()
    if not AUTOTRACKER_IS_IN_LTTP then
        return false
    else
        local mainModuleIdx = AutoTracker:ReadU8(0x7e0010, 0)

        local isInGame = (mainModuleIdx > 0x05 and mainModuleIdx < 0x1b and mainModuleIdx ~= 0x14 and mainModuleIdx ~= 0x17)
        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("** LTTP Status:", "0x7e0010", string.format('0x%x', mainModuleIdx), isInGame)
        end
        return isInGame
    end
end

function isInSM()
    return whichGameAreWeIn() == SM
end

function isInGameSM()
    if not AUTOTRACKER_IS_IN_SM then
        return false
    else
        local mainModuleIdx = AutoTracker:ReadU8(0x7e0998, 0)

        local isInGame = (mainModuleIdx >= 0x07 and mainModuleIdx <= 0x12)
        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("** SM status:", '0x7e0998', string.format('0x%x', mainModuleIdx), isInGame)
        end
        return isInGame
    end
end

function updateLTTPcompletionInLTTP(segment)
    if not (isInLTTP() and isInGameLTTP()) then
        return false
    end
    updateLTTPcompletion(segment)
    return true
end

function updateLTTPcompletionInSM(segment)
    if not (isInSM() and isInGameSM()) then
        return false
    end
    updateLTTPcompletion(segment)
    return true
end

function updateLTTPcompletion(segment)
    InvalidateReadCaches()

    local address = 0x703506
    if AutoTracker.SelectedConnectorType.Name ~= CONNECTOR_NAME_SD2SNES then
        address = address + LUA_EXTRA_RAM_OFFSET
    end
    updateToggleItemFromByte(segment, "ganon", address)
end

function updateSMcompletionInLTTP(segment)
    if not (isInLTTP() and isInGameLTTP()) then
        return false
    end
    updateSMcompletion(segment)
    return true
end

function updateSMcompletionInSM(segment)
    if not (isInSM() and isInGameSM()) then
        return false
    end
    updateSMcompletion(segment)
    return true
end

function updateSMcompletion(segment)
    InvalidateReadCaches()

    local address = 0x703402
    if AutoTracker.SelectedConnectorType.Name ~= CONNECTOR_NAME_SD2SNES then
        address = address + LUA_EXTRA_RAM_OFFSET
    end
    updateToggleItemFromByte(segment, "brain", address)
end

-- ******************** Helper functions for updating items and locations

function updateToggleFromRoomSlot(segment, address, code, slot)
    local item = Tracker:FindObjectForCode(code)
    if item then
        local roomData = ReadU16(segment, address + (slot[1] * 2))
        local value = 1 << slot[2]
        local check = roomData & value

        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("Room data:", code, slot[1], string.format('0x%x', roomData),
                    string.format('0x%x', value), check ~= 0)
        end

        item.Active = check ~= 0
    elseif SHOW_ERROR_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find item: ", code)
    end
end

function updateSectionChestCountFromRoomSlotList(segment, address, locationRef, roomSlots, callback)
    local location = Tracker:FindObjectForCode(locationRef)
    if location then
        -- Do not auto-track this if the user has manually modified it
        if location.Owner.ModifiedByUser then
            if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
                print("* Skipping user modified location: ", locationRef)
            end
            return
        end

        local clearedCount = 0
        for _, slot in ipairs(roomSlots) do
            local roomData = ReadU16(segment, address + (slot[1] * 2))
            local flag = 1 << slot[2]
            local check = roomData & flag

            if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
                print("Updating chest count: ", locationRef, slot[1], string.format('0x%x', roomData),
                        string.format('0x%x', flag), check ~= 0)
            end

            if check ~= 0 then
                clearedCount = clearedCount + 1
            end
        end

        location.AvailableChestCount = location.ChestCount - clearedCount
        if callback then
            callback(clearedCount > 0)
        end
    elseif SHOW_ERROR_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find location: ", locationRef)
    end
end

function updateProgressiveItemFromByte(segment, code, address, offset)
    local item = Tracker:FindObjectForCode(code)
    if item then
        local value = ReadU8(segment, address)
        local newStage = value + (offset or 0)

        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("Progressive item: ", code, string.format('0x%x', address),
                    string.format('0x%x', value), newStage)
        end

        item.CurrentStage = newStage
    elseif SHOW_ERROR_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find item: ", code)
    end
end

function updateSectionChestCountFromByteAndFlag(segment, locationRef, address, flag, callback)
    local location = Tracker:FindObjectForCode(locationRef)
    if location then
        -- Do not auto-track this if the user has manually modified it
        if location.Owner.ModifiedByUser then
            if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
                print("* Skipping user modified location: ", locationRef)
            end
            return
        end

        local value = ReadU8(segment, address)
        local check = value & flag

        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("Updating chest count:", locationRef, string.format('0x%x', address),
                    string.format('0x%x', value), string.format('0x%x', flag), check ~= 0)
        end

        if check ~= 0 then
            location.AvailableChestCount = 0
            if callback then
                callback(true)
            end
        else
            location.AvailableChestCount = location.ChestCount
            if callback then
                callback(false)
            end
        end
    elseif SHOW_ERROR_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find location:", locationRef)
    end
end

function updateToggleItemFromByte(segment, code, address)
    local item = Tracker:FindObjectForCode(code)
    if item then
        local value = ReadU8(segment, address)

        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("Item: ", code, string.format('0x%x', address), string.format('0x%x', value), value >= 1)
        end

        if value >= 1 then
            item.Active = true
        elseif value == 0 then
            item.Active = false
        end
    elseif SHOW_ERROR_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find item: ", code)
    end
end

function updateAmmoFrom2Bytes(segment, code, address)
    local item = Tracker:FindObjectForCode(code)
    local value = ReadU8(segment, address+1)*256 + ReadU8(segment, address)

    if item then
        if code == "etank" then
            if value > 1499 then
                item.AcquiredCount = 14
            else
                item.AcquiredCount = value/100
            end
        elseif code == "reservetank" then
            if value > 400 then
                item.AcquiredCount = 4
            else
                item.AcquiredCount = value/100
            end
        else
            item.AcquiredCount = value
        end

        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("Ammo:", item.Name, string.format("0x%x", address), value, item.AcquiredCount)
        end
    elseif SHOW_ERROR_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find item: ", code)
    end
end

function updateToggleItemFromByteAndFlag(segment, code, address, flag)
    local item = Tracker:FindObjectForCode(code)
    if item then
        local value = ReadU8(segment, address)

        local flagTest = value & flag

        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("Item:", item.Name, string.format("0x%x", address), string.format("0x%x", value),
                    string.format("0x%x", flag), flagTest ~= 0)
        end

        if flagTest ~= 0 then
            item.Active = true
        else
            item.Active = false
        end
    elseif SHOW_ERROR_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find item: ", code)
    end
end

-- ************************* LTTP functions

function updateAga1(segment, address)
    InvalidateReadCaches()
    local item = Tracker:FindObjectForCode("aga1")
    local value = ReadU8(segment, address)

    if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
        print("Aga1:", string.format('0x%x', address), string.format('0x%x', value), value >= 3)
    end

    if value >= 3 then
        item.Active = true
    else
        item.Active = false
    end
end

function updateBottles(segment, address)
    local item = Tracker:FindObjectForCode("bottle")
    local count = 0
    for i = 0, 3, 1 do
        if ReadU8(segment, address + i) > 0 then
            count = count + 1
        end
    end
    item.CurrentStage = count
end

function updateFlute(segment, address)
    local item = Tracker:FindObjectForCode("flute")
    local value = ReadU8(segment, address)

    local fluteAcquired = value & 0x02
    local gooseLoose = value & 0x01

    if gooseLoose ~= 0 then
        item.CurrentStage = 2
    elseif fluteAcquired ~= 0 then
        item.CurrentStage = 1
    else
        item.CurrentStage = 0
    end
end

function updateMirror(segment, address)
    local item = Tracker:FindObjectForCode("mirror")
    if item then
        local value = ReadU8(segment, address)
        if value == 1 or value == 2 then
            item.Active = true
        elseif value == 0 then
            item.Active = false
        end
    elseif SHOW_ERROR_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find item: ", code)
    end
end

function checkDungeonCacheTableChanged(cacheTable, newTable, label)
    -- Check if the cached dungeon data has changed, and set last update timestamp if so.
    local changed = false
    for key, count in pairs(newTable) do
        if cacheTable[key] ~= count then
            if SHOW_DUNGEON_DEBUG_LOGGING then
                print(label .. " changed for: ", key, "Old: ", tostring(cacheTable[key]), "New: ", count)
            end
            cacheTable[key] = count
            changed = true
        end
    end

    if changed then
        DUNGEON_DATA_LAST_UPDATE = os.time()
        if SHOW_DUNGEON_DEBUG_LOGGING then
            print(label .. ": ", table.tostring(cacheTable))
        end
    end
end

function updateDungeonCacheTableFromByteAndFlag(segment, cacheTable, code, address, flag)
    -- Initialize key if not set.
    if cacheTable[code] == nil then
        cacheTable[code] = 0
    end

    local value = ReadU8(segment, address)
    local check = value & flag
    if check ~= 0 then
        cacheTable[code] = cacheTable[code] + 1
        return true
    else
        return false
    end
end

function getRoomDataById(roomId, inLTTP)
    -- If we're in LTTP in this room, use the live room data.  Otherwise use the saved room data.
    local roomData
    if inLTTP and CURRENT_ROOM_ID == roomId then
        roomData = CURRENT_ROOM_DATA
    else
        roomData = SAVED_ROOM_DATA[roomId]
    end
    if roomData == nil then
        roomData = 0
    end
    return roomData
end

function updateDungeonCacheTableFromRoomSlot(cacheTable, code, slot, inLTTP)
    -- For keysanity, we have separate section chest counts for dungeons.  For non-keysanity, combine these into a
    -- single entry by stripping the number off the extra section codes.
    -- ex. Hyrule Castle has "hc", "hc2", "hc3" in keysanity, but just "hc" in regular.
    local codeToUse = code
    if not IS_KEYSANITY then
        codeToUse = string.gsub(code, "%d", "")
    end

    -- Initialize key if not set.
    if cacheTable[codeToUse] == nil then
        cacheTable[codeToUse] = 0
    end

    local roomData = getRoomDataById(slot[1], inLTTP)
    local flag = 1 << slot[2]
    local check = roomData & flag
    if check ~= 0 then
        cacheTable[codeToUse] = cacheTable[codeToUse] + 1
    end
end

-- Update opened door cache for a door with two separate room slots in case they only opened one side.
-- Most small key doors have both sides in a single room, but some have the two sides in two different rooms.
function updateDungeonDoorCacheFromTwoRooms(cacheTable, code, slot1, slot2, inLTTP)
    -- Initialize key if not set.
    if cacheTable[code] == nil then
        cacheTable[code] = 0
    end

    local roomData1 = getRoomDataById(slot1[1], inLTTP)
    local flag1 = 1 << slot1[2]
    local roomData2 = getRoomDataById(slot2[1], inLTTP)
    local flag2 = 1 << slot2[2]
    local check = (roomData1 & flag1) + (roomData2 & flag2)
    if check ~= 0 then
        cacheTable[code] = cacheTable[code] + 1
    end
end

function updateDungeonLocationFromCache(locationRef, code)
    local location = Tracker:FindObjectForCode(locationRef)
    if location then
        -- Do not auto-track this if the user has manually modified it
        if location.Owner.ModifiedByUser then
            if SHOW_DUNGEON_DEBUG_LOGGING then
                print("* Skipping user modified location: ", locationRef)
            end
            return
        end

        -- Get variables.
        local remainingKeys = REMAINING_KEYS[code] or 0
        local openedDoors = OPENED_DOORS[code] or 0
        local floorKeys = FLOOR_KEYS[code] or 0
        local openedChests = OPENED_CHESTS[code] or 0
        local dungeonItems = DUNGEON_ITEMS[code] or 0

        local keysFromChests = math.max(0, remainingKeys + openedDoors - floorKeys)

        -- For keysanity, items found is just number of opened chests.  Otherwise subtract dungeon items and small keys.
        local itemsFound
        if IS_KEYSANITY then
            itemsFound = math.floor(math.min(location.ChestCount, math.max(0, openedChests)))
        else
            itemsFound = math.floor(math.min(location.ChestCount, math.max(0, openedChests - dungeonItems - keysFromChests)))
        end

        if SHOW_DUNGEON_DEBUG_LOGGING then
            print("Dungeon item count: ", locationRef, "Remaining keys: " .. remainingKeys,
                    "Opened doors: " .. openedDoors, "Floor keys: " .. floorKeys,
                    "Opened chests: " .. openedChests, "Dungeon items: " .. dungeonItems,
                    "Keys from chests: " .. keysFromChests, "Items found: " .. itemsFound)
        end
        location.AvailableChestCount = location.ChestCount - itemsFound

    elseif SHOW_DUNGEON_DEBUG_LOGGING or SHOW_ERROR_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find location:", locationRef)
    end
end

function getCurrentKeysForDungeon(cacheTable, segment, address, code, currentKeys, currentDungeon)
    -- If we're in this dungeon, use the current keys value.  Otherwise read the dungeon-specific value from memory.
    if code == currentDungeon then
        cacheTable[code] = currentKeys
    else
        cacheTable[code] = ReadU8(segment, address)
    end
end

function updateGanonsTowerFromCache()
    local dungeon = Tracker:FindObjectForCode("@Ganon's Tower/Dungeon")
    local tower = Tracker:FindObjectForCode("@Ganon's Tower/Tower")

    -- Get variables.
    local remainingKeys = REMAINING_KEYS.gt or 0
    local openedDoors = OPENED_DOORS.gt or 0
    local floorKeys = FLOOR_KEYS.gt or 0
    local openedChests1 = OPENED_CHESTS.gt or 0
    local openedChests2 = OPENED_CHESTS.gt_up or 0
    local dungeonItems = DUNGEON_ITEMS.gt or 0

    local keysFromChests = math.max(0, remainingKeys + openedDoors - floorKeys)
    local itemsFound1 = math.floor(math.min(dungeon.ChestCount, openedChests1))
    local itemsFound2 = math.floor(math.min(tower.ChestCount, openedChests2))

    if SHOW_DUNGEON_DEBUG_LOGGING then
        print("Dungeon item count: Ganon's Tower", "Remaining keys: " .. remainingKeys,
                "Opened doors: " .. openedDoors, "Floor keys: " .. floorKeys,
                "Opened chests downstairs: " .. openedChests1, "Opened chests upstairs: " .. openedChests2,
                "Dungeon items: " .. dungeonItems, "Keys from chests: " .. keysFromChests,
                "Items found downstars: " .. itemsFound1, "Items found upstairs: " .. itemsFound2)
    end
    dungeon.AvailableChestCount = dungeon.ChestCount - itemsFound1
    tower.AvailableChestCount = tower.ChestCount - itemsFound2
end

function updateDungeonSmallKeysFromCache(code)
    -- Update small key items for a single dungeon in the keysanity tracker.
    local item = Tracker:FindObjectForCode(code .. "_smallkey")
    if item then
        -- Get variables.
        local remainingKeys = REMAINING_KEYS[code] or 0
        local openedDoors = OPENED_DOORS[code] or 0
        local floorKeys = FLOOR_KEYS[code] or 0

        local keysFromChests = math.max(0, remainingKeys + openedDoors - floorKeys)
        if SHOW_DUNGEON_DEBUG_LOGGING then
            print("Dungeon small key count: ", code, keysFromChests)
        end
        item.AcquiredCount = keysFromChests
    elseif SHOW_DUNGEON_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find small key item: ", code)
    end
end

function updateAllDungeonLocationsFromCache()
    -- Update all dungeon locations in the tracker based on the inventory/room data caches.
    if IS_KEYSANITY then
        -- Light World
        updateDungeonLocationFromCache("@Hyrule Castle/Dungeon", "hc")
        updateDungeonLocationFromCache("@Hyrule Castle/Dark Cross", "hc2")
        updateDungeonLocationFromCache("@Hyrule Castle/Back of Escape", "hc3")
        updateDungeonLocationFromCache("@Hyrule Castle/Sanctuary", "hc4")
        updateDungeonSmallKeysFromCache("hc")

        updateDungeonLocationFromCache("@Eastern Palace/Front", "ep")
        updateDungeonLocationFromCache("@Eastern Palace/Big Key Chest", "ep2")
        updateDungeonLocationFromCache("@Eastern Palace/Big Chest", "ep3")
        updateDungeonLocationFromCache("@Eastern Palace/Armos Knights", "ep4")
        -- Eastern Palace has no small keys in chests.

        updateDungeonLocationFromCache("@Desert Palace/Map Chest", "dp")
        updateDungeonLocationFromCache("@Desert Palace/Torch", "dp2")
        updateDungeonLocationFromCache("@Desert Palace/Right Side", "dp3")
        updateDungeonLocationFromCache("@Desert Palace/Big Chest", "dp4")
        updateDungeonLocationFromCache("@Desert Palace/Lanmolas", "dp5")
        updateDungeonSmallKeysFromCache("dp")

        updateDungeonLocationFromCache("@Tower of Hera/Entrance", "toh")
        updateDungeonLocationFromCache("@Tower of Hera/Basement", "toh2")
        updateDungeonLocationFromCache("@Tower of Hera/Upper", "toh3")
        updateDungeonLocationFromCache("@Tower of Hera/Moldorm", "toh4")
        updateDungeonSmallKeysFromCache("toh")

        updateDungeonLocationFromCache("@Castle Tower/Foyer", "at")
        updateDungeonLocationFromCache("@Castle Tower/Dark Maze", "at2")
        updateDungeonSmallKeysFromCache("at")

        -- Dark World
        updateDungeonLocationFromCache("@Palace of Darkness/Entrance", "pod")
        updateDungeonLocationFromCache("@Palace of Darkness/Front", "pod2")
        updateDungeonLocationFromCache("@Palace of Darkness/Right Side", "pod3")
        updateDungeonLocationFromCache("@Palace of Darkness/Back", "pod4")
        updateDungeonLocationFromCache("@Palace of Darkness/Big Chest", "pod5")
        updateDungeonLocationFromCache("@Palace of Darkness/Helmasaur King", "pod6")
        updateDungeonSmallKeysFromCache("pod")

        updateDungeonLocationFromCache("@Swamp Palace/Entrance", "sp")
        updateDungeonLocationFromCache("@Swamp Palace/Bomb Wall", "sp2")
        updateDungeonLocationFromCache("@Swamp Palace/Front", "sp3")
        updateDungeonLocationFromCache("@Swamp Palace/Big Chest", "sp4")
        updateDungeonLocationFromCache("@Swamp Palace/Back", "sp5")
        updateDungeonLocationFromCache("@Swamp Palace/Arrgus", "sp6")
        updateDungeonSmallKeysFromCache("sp")

        updateDungeonLocationFromCache("@Skull Woods/Front", "sw")
        updateDungeonLocationFromCache("@Skull Woods/Big Chest", "sw2")
        updateDungeonLocationFromCache("@Skull Woods/Back", "sw3")
        updateDungeonLocationFromCache("@Skull Woods/Mothula", "sw4")
        updateDungeonSmallKeysFromCache("sw")

        updateDungeonLocationFromCache("@Thieves Town/Front", "tt")
        updateDungeonLocationFromCache("@Thieves Town/Back", "tt2")
        updateDungeonLocationFromCache("@Thieves Town/Big Chest", "tt3")
        updateDungeonLocationFromCache("@Thieves Town/Blind", "tt4")
        updateDungeonSmallKeysFromCache("tt")

        updateDungeonLocationFromCache("@Ice Palace/Left Side", "ip")
        updateDungeonLocationFromCache("@Ice Palace/Big Chest", "ip2")
        updateDungeonLocationFromCache("@Ice Palace/Right Side", "ip3")
        updateDungeonLocationFromCache("@Ice Palace/Kholdstare", "ip4")
        updateDungeonSmallKeysFromCache("ip")

        updateDungeonLocationFromCache("@Misery Mire/Right Side", "mm")
        updateDungeonLocationFromCache("@Misery Mire/Big Chest", "mm2")
        updateDungeonLocationFromCache("@Misery Mire/Left Side", "mm3")
        updateDungeonLocationFromCache("@Misery Mire/Vitreous", "mm4")
        updateDungeonSmallKeysFromCache("mm")

        updateDungeonLocationFromCache("@Turtle Rock/Entrance", "tr")
        updateDungeonLocationFromCache("@Turtle Rock/Roller Room", "tr2")
        updateDungeonLocationFromCache("@Turtle Rock/Chain Chomps", "tr3")
        updateDungeonLocationFromCache("@Turtle Rock/Big Key Chest", "tr4")
        updateDungeonLocationFromCache("@Turtle Rock/Big Chest", "tr5")
        updateDungeonLocationFromCache("@Turtle Rock/Crystaroller Room", "tr6")
        updateDungeonLocationFromCache("@Turtle Rock/Laser Bridge", "tr7")
        updateDungeonLocationFromCache("@Turtle Rock/Trinexx", "tr8")
        updateDungeonSmallKeysFromCache("tr")

        updateDungeonSmallKeysFromCache("gt")

    else
        -- Light World
        updateDungeonLocationFromCache("@Hyrule Castle/Escape", "hc")
        updateDungeonLocationFromCache("@Eastern Palace/Dungeon", "ep")
        updateDungeonLocationFromCache("@Desert Palace/Dungeon", "dp")
        updateDungeonLocationFromCache("@Tower of Hera/Dungeon", "toh")

        -- Dark World
        updateDungeonLocationFromCache("@Palace of Darkness/Dungeon", "pod")
        updateDungeonLocationFromCache("@Swamp Palace/Dungeon", "sp")
        updateDungeonLocationFromCache("@Skull Woods/Dungeon", "sw")
        updateDungeonLocationFromCache("@Thieves Town/Dungeon", "tt")
        updateDungeonLocationFromCache("@Ice Palace/Dungeon", "ip")
        updateDungeonLocationFromCache("@Misery Mire/Dungeon", "mm")
        updateDungeonLocationFromCache("@Turtle Rock/Dungeon", "tr")
    end

    -- Ganon's Tower has its own special logic since it's in two main parts.
    updateGanonsTowerFromCache()
end

function updateDungeonLocationsFromTimestamp()
    -- Check if the dungeon cache data has been updated in the last few seconds.  If so, wait for it to stabilize.
    -- If it's been stable for more than a couple seconds, perform the location update from the cached data.
    -- This should hopefully avoid a "flickering" of incorrect counts on the locations which may cause pinned locations
    -- to be accidentally cleared if the count goes 1 -> 0 -> 1 again very quickly.
    -- Set last update timestamp to nil so we don't update again until data changes.
    if DUNGEON_DATA_LAST_UPDATE ~= nil then
        local howLongAgo = os.time() - DUNGEON_DATA_LAST_UPDATE
        if howLongAgo > 2 then
            if SHOW_DUNGEON_DEBUG_LOGGING then
                print(string.format("Dungeon data updated %d seconds ago, updating locations", howLongAgo))
            end
            updateAllDungeonLocationsFromCache()
            DUNGEON_DATA_LAST_UPDATE = nil
        end
    end

    -- This is intentional.  Return false so this function will keep firing periodically like a setInterval().
    return false
end

function updateCurrentRoomDataLTTP(segment)
    if not (isInLTTP() and isInGameLTTP()) then
        return false
    end
    if AUTOTRACKER_ENABLE_DUNGEON_TRACKING then
        local newRoomId
        local newRoomData
        local currentKeys = math.floor(AutoTracker:ReadU8(0x7ef36f, 0))

        if currentKeys ~= 0xff then
            newRoomId = math.floor(AutoTracker:ReadU8(0x7e00a0, 0))
            local val1 = ReadU8(segment, 0x7e0401)
            local val2 = ReadU8(segment, 0x7e0403)
            local val3 = ReadU8(segment, 0x7e0408)
            -- Room data: 0x7e0401 high byte, 0x7e0403 both bytes, 0x7e0408 low byte
            newRoomData = ((val1 & 0xf0) | ((val2 & 0xf0) >> 4)) << 8
            newRoomData = newRoomData | (((val2 & 0x0f) << 4) | (val3 & 0x0f))
        else
            newRoomId = 0
            newRoomData = 0x0
        end

        local changed = (newRoomId ~= CURRENT_ROOM_ID) or (newRoomData ~= CURRENT_ROOM_DATA)
        CURRENT_ROOM_ID = newRoomId
        CURRENT_ROOM_DATA = newRoomData

        if SHOW_DUNGEON_DEBUG_LOGGING and changed then
            print("LTTP current room data: ", CURRENT_ROOM_ID, string.format("0x%x", CURRENT_ROOM_DATA))
        end

        -- Update keys and door data from the cache.
        updateRoomDataFromCache(true)
    end
    return true
end

function updateRoomDataFromCache(inLTTP)
    -- Update dungeon room data cache for counting dungeon items without cheating.
    local newFloorKeys = {}
    local newOpenedDoors = {}
    local newOpenedChests = {}

    -- *** Hyrule Castle
    -- Room 114 offset 0xE4 (First basement room with blue key guard, locked door, and chest)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "hc", { 114, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "hc", { 114, 15 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "hc", { 114, 4 }, inLTTP)

    -- Room 113 offset 0xE2 (Room before stairs to prison)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "hc", { 113, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "hc", { 113, 15 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "hc", { 113, 4 }, inLTTP)

    -- Room 128 offset 0x100 (Zelda's cell)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "hc", { 128, 4 }, inLTTP)

    -- Room 50 offset 0x64 (Dark cross)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "hc2", { 50, 4 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "hc", { 50, 15 }, { 34, 15 }, inLTTP)

    -- Room 33 offset 0x42 (Dark room with key on rat)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "hc", { 33, 10 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "hc", { 33, 15 }, { 17, 13 }, inLTTP)

    -- Room 17 offset 0x22 (Escape secret side room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "hc3", { 17, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "hc3", { 17, 5 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "hc3", { 17, 6 }, inLTTP)

    -- Room 18 offset 0x24 (Sanctuary)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "hc4", { 18, 4 }, inLTTP)


    -- *** Eastern Palace
    -- Room 186 offset 0x174 (Small key under pot)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "ep", { 186, 10 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "ep", { 186, 15 }, { 185, 15 }, inLTTP)

    -- Room 185 offset 0x172 (Rolling ball entrance room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "ep", { 185, 4 }, inLTTP)

    -- Room 170 offset 0x154 (Map chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "ep", { 170, 4 }, inLTTP)

    -- Room 168 offset 0x150 (Compass chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "ep", { 168, 4 }, inLTTP)

    -- Room 184 offset 0x170 (Big key chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "ep2", { 184, 4 }, inLTTP)

    -- Room 153 offset 0x132 (Small key on mimic)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "ep", { 153, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "ep", { 153, 15 }, inLTTP)

    -- Room 169 offset 0x152 (Big chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "ep3", { 169, 4 }, inLTTP)

    -- Room 200 offset 0x190 (Armos Knights)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "ep4", { 200, 11 }, inLTTP)


    -- *** Desert Palace
    -- Room 115 offset 0xE6 (Big chest and torch item)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "dp4", { 115, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "dp2", { 115, 10 }, inLTTP)

    -- Room 116 offset 0xE8 (Map chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "dp", { 116, 4 }, inLTTP)

    -- Room 117 offset 0xE9 (Big key chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "dp3", { 117, 4 }, inLTTP)

    -- Room 133 offset 0x10A (Room before big key chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "dp3", { 133, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "dp", { 133, 14 }, inLTTP)

    -- Room 99 offset 0xC6 (First flying tile room in back)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "dp", { 99, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "dp", { 99, 15 }, inLTTP)

    -- Room 83 offset 0xA6 (Long room with beamos)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "dp", { 83, 10 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "dp", { 83, 13 }, { 67, 13 }, inLTTP)

    -- Room 67 offset 0x86 (Second flying tile room before boss)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "dp", { 67, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "dp", { 67, 14 }, inLTTP)

    -- Room 51 offset 0x66 (Lanmolas)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "dp5", { 51, 11 }, inLTTP)


    -- *** Tower of Hera
    -- Room 119 offset 0xEE (Entrance)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "toh", { 119, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "toh", { 119, 15 }, inLTTP)

    -- Room 135 offset 0x10E (Basement)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "toh", { 135, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "toh2", { 135, 4 }, inLTTP)

    -- Room 39 offset 0x4E (Big chest room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "toh3", { 39, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "toh3", { 39, 5 }, inLTTP)

    -- Room 7 offset 0xE (Trolldorm)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "toh4", { 7, 11 }, inLTTP)


    -- *** Agahnim's Tower (keysanity only)
    if IS_KEYSANITY then
        -- Room 224 offset 0x1C0 (First chest)
        updateDungeonCacheTableFromRoomSlot(newOpenedChests, "at", { 224, 4 }, inLTTP)
        updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "at", { 224, 13 }, inLTTP)

        -- Room 208 offset 0x1A0 (Dark maze)
        updateDungeonCacheTableFromRoomSlot(newOpenedChests, "at2", { 208, 4 }, inLTTP)
        updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "at", { 208, 15 }, inLTTP)

        -- Room 192 offset 0x180 (Guards after pit room)
        updateDungeonCacheTableFromRoomSlot(newFloorKeys, "at", { 192, 10 }, inLTTP)
        updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "at", { 192, 13 }, inLTTP)

        -- Room 176 offset 0x160 (Red guard with last key)
        updateDungeonCacheTableFromRoomSlot(newFloorKeys, "at", { 176, 10 }, inLTTP)
        updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "at", { 176, 13 }, inLTTP)
    end


    -- *** Palace of Darkness
    -- Room 9 offset 0x12 (Left entrance basement room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "pod", { 9, 4 }, inLTTP)

    -- Room 74 offset 0x94 (Entrance area locked door, double-sided)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "pod", { 74, 13 }, { 58, 15 }, inLTTP)

    -- Room 58 offset 0x74 (Big key chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "pod2", { 58, 4 }, inLTTP)

    -- Room 10 offset 0x14 (Basement teleporter room with locked door stairs to big key)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "pod2", { 10, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "pod", { 10, 15 }, inLTTP)

    -- Room 43 offset 0x56 (Coming up from basement, bombable wall to second chest in bouncy room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "pod3", { 43, 4 }, inLTTP)

    -- Room 42 offset 0x54 (Bouncy enemy room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "pod3", { 42, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "pod2", { 42, 5 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "pod", { 42, 14 }, { 26, 12 }, inLTTP)

    -- Room 26 offset 0x34 (Crumble bridge room and adjacent)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "pod5", { 26, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "pod4", { 26, 5 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "pod4", { 26, 6 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "pod", { 26, 15 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "pod", { 26, 14 }, { 25, 14 }, inLTTP)

    -- Room 25 offset 0x32 (Dark maze)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "pod4", { 25, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "pod4", { 25, 5 }, inLTTP)

    -- Room 106 offset 0xD4 (Room before boss)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "pod4", { 106, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "pod4", { 106, 5 }, inLTTP)

    -- Room 11 offset 0x16 (Basement locked door leading to boss)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "pod", { 11, 13 }, inLTTP)

    -- Room 90 offset 0xB4 (Helmasaur King)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "pod6", { 90, 11 }, inLTTP)


    -- *** Swamp Palace
    -- Room 40 offset 0x50 (Entrance)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sp", { 40, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "sp", { 40, 15 }, inLTTP)

    -- Room 56 offset 0x70 (First basement room with key under pot)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "sp", { 56, 10 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "sp", { 56, 14 }, { 55, 12 }, inLTTP)

    -- Room 55 offset 0x6E (First water valve and key)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sp2", { 55, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "sp", { 55, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "sp", { 55, 13 }, inLTTP)

    -- Room 70 offset 0x8C (Map chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sp3", { 70, 4 }, inLTTP)

    -- Room 54 offset 0x6C (Central big chest room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sp4", { 54, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "sp", { 54, 10 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "sp", { 54, 14 }, { 38, 15 }, inLTTP)  -- Top locked door
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "sp", { 54, 13 }, { 53, 15 }, inLTTP)  -- Left locked door

    -- Room 53 offset 0x6A (Second water valve, pot key, and big key chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sp3", { 53, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "sp", { 53, 10 }, inLTTP)

    -- Room 52 offset 0x68 (Left side chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sp3", { 52, 4 }, inLTTP)

    -- Room 118 offset 0xEC (Underwater chests)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sp5", { 118, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sp5", { 118, 5 }, inLTTP)

    -- Room 102 offset 0xCC (Last chest before boss)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sp5", { 102, 4 }, inLTTP)

    -- Room 22 offset 0x2C (Room before boss)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "sp", { 22, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "sp", { 22, 14 }, inLTTP)

    -- Room 6 offset 0xC (Arrghus)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sp6", { 6, 11 }, inLTTP)


    -- *** Skull Woods
    -- Room 103 offset 0xCE (Bottom left drop down room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sw", { 103, 4 }, inLTTP)

    -- Room 87 offset 0xAE (Drag the statue room and corner chest from first entrance)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sw", { 87, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sw", { 87, 5 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "sw", { 87, 13 }, { 88, 14 }, inLTTP)

    -- Room 88 offset 0xB0 (First entrance with big chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sw2", { 88, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sw", { 88, 5 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "sw", { 88, 13 }, { 104, 14 }, inLTTP)

    -- Room 104 offset 0xD0 (Soft-lock potential room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sw", { 104, 4 }, inLTTP)

    -- Room 86 offset 0xAC (Exit towards boss area)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "sw", { 86, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "sw", { 86, 15 }, inLTTP)

    -- Room 89 offset 0xB2 (Back area entrance)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sw3", { 89, 4 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "sw", { 89, 15 }, { 73, 13 }, inLTTP)

    -- Room 57 offset 0x72 (Drop down to boss)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "sw", { 57, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "sw", { 57, 14 }, inLTTP)

    -- Room 41 offset 0x52 (Mothula)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "sw4", { 41, 11 }, inLTTP)


    -- *** Thieves Town
    -- Room 219 offset 0x1B6 (Entrance, SW main area)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tt", { 219, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tt", { 219, 5 }, inLTTP)

    -- Room 203 offset 0x196 (NW main area)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tt", { 203, 4 }, inLTTP)

    -- Room 220 offset 0x1B8 (SE main area)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tt", { 220, 4 }, inLTTP)

    -- Room 188 offset 0x178 (Room before boss)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "tt", { 188, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "tt", { 188, 15 }, inLTTP)

    -- Room 171 offset 0x156 (Locked door to 2F)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "tt", { 171, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "tt", { 171, 15 }, inLTTP)

    -- Room 101 offset 0xCA (2F attic)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tt2", { 101, 4 }, inLTTP)

    -- Room 69 (nice) offset 0x8A ("Maiden" cell)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tt2", { 69, 4 }, inLTTP)

    -- Room 68 offset 0x88 (Big chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tt3", { 68, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "tt", { 68, 14 }, inLTTP)

    -- Room 172 offset 0x158 (Blind)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tt4", { 172, 11 }, inLTTP)


    -- *** Ice Palace
    -- Room 14 offset 0x1C (Entrance)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "ip", { 14, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "ip", { 14, 15 }, inLTTP)

    -- Room 46 offset 0x5C (Penguin ice room with first chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "ip", { 46, 4 }, inLTTP)

    -- Room 62 offset 0x7C (Conveyor room before bomb jump)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "ip", { 62, 10 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "ip", { 62, 14 }, { 78, 14 }, inLTTP)

    -- Room 126 offset 0xFC (Room above big chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "ip", { 126, 4 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "ip", { 126, 15 }, { 142, 15 }, inLTTP)

    -- Room 158 offset 0x13C (Big chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "ip2", { 158, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "ip", { 158, 15 }, inLTTP)

    -- Room 159 offset 0x13E (Ice room key in pot east of block pushing room)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "ip", { 159, 10 }, inLTTP)

    -- Room 174 offset 0x15C (Ice T room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "ip", { 174, 4 }, inLTTP)

    -- Room 95 offset 0xBE (Hookshot over spikes)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "ip3", { 95, 4 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "ip", { 95, 15 }, { 94, 15 }, inLTTP)

    -- Room 63 offset 0x7E (Pulling tongues before big key)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "ip3", { 63, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "ip", { 63, 10 }, inLTTP)

    -- Room 31 offset 0x3E (Big key chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "ip3", { 31, 4 }, inLTTP)

    -- Room 190 offset 0x17C (Block switch room)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "ip", { 190, 14 }, { 191, 15 }, inLTTP)

    -- Room 222 offset 0x1BC (Kholdstare)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "ip4", { 222, 11 }, inLTTP)


    -- *** Misery Mire
    -- Room 162 offset 0x144 (Map chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "mm", { 162, 4 }, inLTTP)

    -- Room 179 offset 0x166 (Right side spike room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "mm", { 179, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "mm", { 179, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "mm", { 179, 15 }, inLTTP)

    -- Room 161 offset 0x142 (Top left crystal switch + pot key)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "mm", { 161, 10 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "mm", { 161, 15 }, { 177, 14 }, inLTTP)

    -- Room 194 offset 0x184 (Central room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "mm", { 194, 4 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "mm", { 194, 15 }, { 195, 15 }, inLTTP)

    -- Room 195 offset 0x186 (Big chest and small chest next door)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "mm2", { 195, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "mm", { 195, 5 }, inLTTP)

    -- Room 193 offset 0x182 (Conveyor belt and tile room, compass chest)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "mm", { 194, 14 }, { 193, 14 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "mm3", { 193, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "mm", { 193, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "mm", { 193, 15 }, inLTTP)

    -- Room 209 offset 0x1A2 (Big key chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "mm3", { 209, 4 }, inLTTP)

    -- Room 147 offset 0x126 (Basement locked rupee room)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "mm", { 147, 14 }, inLTTP)

    -- Room 144 offset 0x120 (Vitreous)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "mm4", { 144, 11 }, inLTTP)


    -- *** Turtle Rock
    -- Room 214 offset 0x1AC (Map chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tr", { 214, 4 }, inLTTP)

    -- Room 183 offset 0x16E (Double spike rollers)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tr2", { 183, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tr2", { 183, 5 }, inLTTP)

    -- Room 198 offset 0x18C (1F central room)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "tr", { 198, 15 }, { 182, 13 }, inLTTP)

    -- Room 182 offset 0x16C (Chain Chomp room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tr3", { 182, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "tr", { 182, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "tr", { 182, 12 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "tr", { 182, 15 }, inLTTP)

    -- Room 19 offset 0x26 (Quad anti-fairy room)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "tr", { 19, 10 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "tr", { 19, 15 }, { 20, 14 }, inLTTP)

    -- Room 20 offset 0x28 (Central tube room with big key chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tr4", { 20, 4 }, inLTTP)

    -- Room 36 offset 0x48 (Big chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tr5", { 36, 4 }, inLTTP)

    -- Room 4 offset 0x8 (Spike roller after big key door)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tr6", { 4, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "tr", { 4, 15 }, inLTTP)

    -- Room 213 offset 0x1AA (Laser bridge)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tr7", { 213, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tr7", { 213, 5 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tr7", { 213, 6 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tr7", { 213, 7 }, inLTTP)

    -- Room 197 offset 0x18A (Door to crystal switch room before boss)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "tr", { 197, 15 }, { 196, 15 }, inLTTP)

    -- Room 164 offset 0x148 (Trinexx)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "tr8", { 164, 11 }, inLTTP)


    -- *** Ganon's Tower (dungeon)
    -- Room 140 offset 0x118 (First two rooms with torch, plus Bob's chest and big chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 140, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 140, 5 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 140, 6 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 140, 7 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 140, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "gt", { 140, 13 }, inLTTP)

    -- Room 139 offset 0x116 (Hookshot block room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 139, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "gt", { 139, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "gt", { 139, 14 }, inLTTP)

    -- Room 155 offset 0x136 (Pot key below hookshot room with locked door)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "gt", { 155, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "gt", { 155, 15 }, inLTTP)

    -- Room 125 offset 0xFA (Entrance to warp maze)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 125, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "gt", { 125, 13 }, inLTTP)

    -- Room 123 offset 0xF6 (Four chests on left side above hookshot room, plus end of right side)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 123, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 123, 5 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 123, 6 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 123, 7 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "gt", { 123, 10 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "gt", { 123, 14 }, { 124, 13 }, inLTTP)

    -- Room 124 offset 0xF8 (Rando room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 124, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 124, 5 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 124, 6 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 124, 7 }, inLTTP)

    -- Room 28 offset 0x38 (Big key chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 28, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 28, 5 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 28, 6 }, inLTTP)

    -- Room 141 offset 0x11A (Tile room)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 141, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "gt", { 141, 14 }, inLTTP)

    -- Room 157 offset 0x13A (Last four chests on right side)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 157, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 157, 5 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 157, 6 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt", { 157, 7 }, inLTTP)


    -- *** Ganon's Tower (tower)
    -- Room 61 offset 0x7A (Mini helmasaur room before Moldorm 2)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt_up", { 61, 4 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt_up", { 61, 5 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt_up", { 61, 6 }, inLTTP)
    -- Floor key and opened doors need to be in the main GT count for the math!
    updateDungeonCacheTableFromRoomSlot(newFloorKeys, "gt", { 61, 10 }, inLTTP)
    updateDungeonCacheTableFromRoomSlot(newOpenedDoors, "gt", { 61, 14 }, inLTTP)
    updateDungeonDoorCacheFromTwoRooms(newOpenedDoors, "gt", { 61, 13 }, { 77, 15 }, inLTTP)

    -- Room 77 offset 0x9A (Validation chest)
    updateDungeonCacheTableFromRoomSlot(newOpenedChests, "gt_up", { 77, 4 }, inLTTP)


    -- Check if any of the values changed.
    checkDungeonCacheTableChanged(FLOOR_KEYS, newFloorKeys, "Floor keys count")
    checkDungeonCacheTableChanged(OPENED_DOORS, newOpenedDoors, "Opened door count")
    checkDungeonCacheTableChanged(OPENED_CHESTS, newOpenedChests, "Opened chest count")

    -- If we're not in LTTP, update dungeon locations immediately.  Otherwise wait for stable data.
    if not inLTTP then
        updateAllDungeonLocationsFromCache()
    end
end

function updateItemsActiveLTTP(segment)
    if not (isInLTTP() and isInGameLTTP()) then
        return false
    end
    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateItemsLTTP(segment, 0x7ef300, true)
    end
    return true
end

function updateItemsInactiveLTTP(segment)
    if not (isInSM() and isInGameSM()) then
        return false
    end

    local address = 0x703b00
    if AutoTracker.SelectedConnectorType.Name ~= CONNECTOR_NAME_SD2SNES then
        address = address + LUA_EXTRA_RAM_OFFSET
    end

    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateItemsLTTP(segment, address, false)
    end
    return true
end

function updateItemsLTTP(segment, address, inLTTP)
    InvalidateReadCaches()

    updateProgressiveItemFromByte(segment, "owsword",  address + 0x59)
    updateProgressiveItemFromByte(segment, "shield",  address + 0x5A)
    updateProgressiveItemFromByte(segment, "armor",  address + 0x5B)
    updateProgressiveItemFromByte(segment, "gloves", address + 0x54)

    updateToggleItemFromByte(segment, "hookshot",  address + 0x42)
    updateToggleItemFromByte(segment, "bombs",     address + 0x43)
    updateToggleItemFromByte(segment, "firerod",   address + 0x45)
    updateToggleItemFromByte(segment, "icerod",    address + 0x46)
    updateToggleItemFromByte(segment, "bombos",    address + 0x47)
    updateToggleItemFromByte(segment, "ether",     address + 0x48)
    updateToggleItemFromByte(segment, "quake",     address + 0x49)
    updateToggleItemFromByte(segment, "lamp",      address + 0x4a)
    updateToggleItemFromByte(segment, "hammer",    address + 0x4b)
    updateToggleItemFromByte(segment, "net",       address + 0x4d)
    updateToggleItemFromByte(segment, "book",      address + 0x4e)
    updateToggleItemFromByte(segment, "somaria",   address + 0x50)
    updateToggleItemFromByte(segment, "byrna",     address + 0x51)
    updateToggleItemFromByte(segment, "cape",      address + 0x52)
    updateToggleItemFromByte(segment, "boots",     address + 0x55)
    updateToggleItemFromByte(segment, "flippers",  address + 0x56)
    updateToggleItemFromByte(segment, "pearl",     address + 0x57)
    updateToggleItemFromByte(segment, "halfmagic", address + 0x7b)

    updateToggleItemFromByteAndFlag(segment, "blueboomerang", address + 0x8c, 0x80)
    updateToggleItemFromByteAndFlag(segment, "redboomerang",  address + 0x8c, 0x40)
    updateToggleItemFromByteAndFlag(segment, "shovel", address + 0x8c, 0x04)
    updateToggleItemFromByteAndFlag(segment, "powder", address + 0x8c, 0x10)
    updateToggleItemFromByteAndFlag(segment, "mushroom", address + 0x8c, 0x20)
    updateToggleItemFromByte(segment, "bow", address + 0x40)
    updateToggleItemFromByteAndFlag(segment, "silvers", address + 0x8e, 0x40)

    updateBottles(segment, address + 0x5c)
    updateFlute(segment, address + 0x8c)
    updateMirror(segment, address + 0x53)
    updateAga1(segment, address + 0xc5)

    -- Big keys for keysanity.
    updateToggleItemFromByteAndFlag(segment, "gt_bigkey",  address + 0x66, 0x04)
    updateToggleItemFromByteAndFlag(segment, "tr_bigkey",  address + 0x66, 0x08)
    updateToggleItemFromByteAndFlag(segment, "tt_bigkey",  address + 0x66, 0x10)
    updateToggleItemFromByteAndFlag(segment, "toh_bigkey", address + 0x66, 0x20)
    updateToggleItemFromByteAndFlag(segment, "ip_bigkey",  address + 0x66, 0x40)
    updateToggleItemFromByteAndFlag(segment, "sw_bigkey",  address + 0x66, 0x80)
    updateToggleItemFromByteAndFlag(segment, "mm_bigkey",  address + 0x67, 0x01)
    updateToggleItemFromByteAndFlag(segment, "pod_bigkey", address + 0x67, 0x02)
    updateToggleItemFromByteAndFlag(segment, "sp_bigkey",  address + 0x67, 0x04)
    updateToggleItemFromByteAndFlag(segment, "dp_bigkey",  address + 0x67, 0x10)
    updateToggleItemFromByteAndFlag(segment, "ep_bigkey",  address + 0x67, 0x20)

    --  It may seem unintuitive, but these locations are controlled by flags stored adjacent to the item data,
    --  which makes it more efficient to update them here.
    updateSectionChestCountFromByteAndFlag(segment, "@Secret Passage/Link's Uncle", address + 0xc6, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Hobo/Under The Bridge", address + 0xc9, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Bottle Merchant/Bottle Merchant", address + 0xc9, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Purple Chest/Purple Chest", address + 0xc9, 0x10)

    -- Update remaining small keys and dungeon item (map/compass/big key) data caches from item data.
    if AUTOTRACKER_ENABLE_DUNGEON_TRACKING then
        -- If we're in LTTP, check if we're inside a dungeon.  If so, read the remaining keys from the common variable
        -- used for all dungeons.  This is because the dungeon-specific key spots don't update all the time.  They only
        -- update for sure when you leave the dungeon.  We can tell what dungeon we're in by the current room index, and
        -- the common key spot will read 0xff if we're outside.
        local currentDungeon = ''
        local currentKeys = ReadU8(segment, address + 0x6f)
        local currentRoom = 0
        if inLTTP and currentKeys ~= 0xff then
            currentRoom = math.floor(AutoTracker:ReadU8(0x7e00a0, 0))
            for key, rooms in pairs(DUNGEON_ROOMS) do
                if table.has_value(rooms, currentRoom) then
                    currentDungeon = key
                    break
                end
            end
        end

        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("Current room ID: ", currentRoom, "Current dungeon: ", currentDungeon, "Current keys: ", currentKeys)
        end

        -- Remaining keys.
        local newRemainingKeys = {}

        getCurrentKeysForDungeon(newRemainingKeys, segment, address + 0x7c, "hc", currentKeys, currentDungeon)
        getCurrentKeysForDungeon(newRemainingKeys, segment, address + 0x7e, "ep", currentKeys, currentDungeon)
        getCurrentKeysForDungeon(newRemainingKeys, segment, address + 0x7f, "dp", currentKeys, currentDungeon)
        getCurrentKeysForDungeon(newRemainingKeys, segment, address + 0x86, "toh", currentKeys, currentDungeon)
        getCurrentKeysForDungeon(newRemainingKeys, segment, address + 0x80, "at", currentKeys, currentDungeon)

        getCurrentKeysForDungeon(newRemainingKeys, segment, address + 0x82, "pod", currentKeys, currentDungeon)
        getCurrentKeysForDungeon(newRemainingKeys, segment, address + 0x81, "sp", currentKeys, currentDungeon)
        getCurrentKeysForDungeon(newRemainingKeys, segment, address + 0x84, "sw", currentKeys, currentDungeon)
        getCurrentKeysForDungeon(newRemainingKeys, segment, address + 0x87, "tt", currentKeys, currentDungeon)
        getCurrentKeysForDungeon(newRemainingKeys, segment, address + 0x85, "ip", currentKeys, currentDungeon)
        getCurrentKeysForDungeon(newRemainingKeys, segment, address + 0x83, "mm", currentKeys, currentDungeon)
        getCurrentKeysForDungeon(newRemainingKeys, segment, address + 0x88, "tr", currentKeys, currentDungeon)
        getCurrentKeysForDungeon(newRemainingKeys, segment, address + 0x89, "gt", currentKeys, currentDungeon)

        checkDungeonCacheTableChanged(REMAINING_KEYS, newRemainingKeys, "Remaining key count")

        local newDungeonItems = {}

        -- Compasses
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "gt", address + 0x64, 0x04)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "tr", address + 0x64, 0x08)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "tt", address + 0x64, 0x10)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "toh", address + 0x64, 0x20)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "ip", address + 0x64, 0x40)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "sw", address + 0x64, 0x80)

        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "mm", address + 0x65, 0x01)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "pod", address + 0x65, 0x02)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "sp", address + 0x65, 0x04)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "dp", address + 0x65, 0x10)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "ep", address + 0x65, 0x20)

        -- Big keys
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "gt", address + 0x66, 0x04)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "tr", address + 0x66, 0x08)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "tt", address + 0x66, 0x10)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "toh", address + 0x66, 0x20)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "ip", address + 0x66, 0x40)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "sw", address + 0x66, 0x80)

        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "mm", address + 0x67, 0x01)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "pod", address + 0x67, 0x02)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "sp", address + 0x67, 0x04)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "dp", address + 0x67, 0x10)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "ep", address + 0x67, 0x20)

        -- Maps
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "gt", address + 0x68, 0x04)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "tr", address + 0x68, 0x08)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "tt", address + 0x68, 0x10)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "toh", address + 0x68, 0x20)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "ip", address + 0x68, 0x40)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "sw", address + 0x68, 0x80)

        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "mm", address + 0x69, 0x01)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "pod", address + 0x69, 0x02)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "sp", address + 0x69, 0x04)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "dp", address + 0x69, 0x10)
        updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "ep", address + 0x69, 0x20)

        -- Map for Hyrule Castle/Escape is weird.  There are two separate addresses for HC and sewers, check both.
        if not updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "hc", address + 0x69, 0x40) then
            updateDungeonCacheTableFromByteAndFlag(segment, newDungeonItems, "hc", address + 0x69, 0x80)
        end

        -- Check if any of the dungeon item counts actually changed.  Set last update timestamp if so.
        checkDungeonCacheTableChanged(DUNGEON_ITEMS, newDungeonItems, "Dungeon item count")

        -- If we're not in LTTP, update dungeon locations immediately.  Otherwise wait for stable data.
        if not inLTTP then
            updateAllDungeonLocationsFromCache()
        end
    end
end

function updateRoomsActiveLTTP(segment)
    if not (isInLTTP() and isInGameLTTP()) then
        return false
    end
    updateRoomsLTTP(segment, 0x7ef000, true)
    return true
end

function updateRoomsInactiveLTTP(segment)
    if not (isInSM() and isInGameSM()) then
        return false
    end
    updateRoomsLTTP(segment, getSRAMAddressLTTP(0x0), false)
    return true
end

function updateRoomsLTTP(segment, address, inLTTP)
    InvalidateReadCaches()

    -- Update dungeon clear markers.
    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateToggleFromRoomSlot(segment, address, "ep", { 200, 11 })
        updateToggleFromRoomSlot(segment, address, "dp", { 51, 11 })
        updateToggleFromRoomSlot(segment, address, "toh", { 7, 11 })
        updateToggleFromRoomSlot(segment, address, "pod", { 90, 11 })
        updateToggleFromRoomSlot(segment, address, "sp", { 6, 11 })
        updateToggleFromRoomSlot(segment, address, "sw", { 41, 11 })
        updateToggleFromRoomSlot(segment, address, "tt", { 172, 11 })
        updateToggleFromRoomSlot(segment, address, "ip", { 222, 11 })
        updateToggleFromRoomSlot(segment, address, "mm", { 144, 11 })
        updateToggleFromRoomSlot(segment, address, "tr", { 164, 11 })
    end

    if AUTOTRACKER_ENABLE_LOCATION_TRACKING then
        updateSectionChestCountFromRoomSlotList(segment, address, "@Kakariko Well/Cave",
                { { 47, 5 }, { 47, 6 }, { 47, 7 }, { 47, 8 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Kakariko Well/Bombable Wall", { { 47, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Hookshot Cave/Bonkable Chest", { { 60, 7 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Hookshot Cave/Back", { { 60, 4 }, { 60, 5 }, { 60, 6 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Secret Passage/Hallway", { { 85, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Lost Woods Hideout/Lost Woods Hideout", { { 225, 9 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Lumberjack Tree/Lumberjack Tree", { { 226, 9 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Spectacle Rock Cave/Cave", { { 234, 10 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Paradox Cave/Top",
                { { 239, 4 }, { 239, 5 }, { 239, 6 }, { 239, 7 }, { 239, 8 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Super-Bunny Cave/Cave", { { 248, 4 }, { 248, 5 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Spiral Cave/Spiral Cave", { { 254, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Paradox Cave/Bottom", { { 255, 4 }, { 255, 5 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Kakariko Tavern/Back Room", { { 259, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Link's House/Link's House", { { 260, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Sahasrahla's Hut/Back Room",
                { { 261, 4 }, { 261, 5 }, { 261, 6 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Brewery/Brewery", { { 262, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Chest Game/Chest Game", { { 262, 10 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Chicken House/Bombable Wall", { { 264, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Aginah's Cave/Aginah's Cave", { { 266, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@The Dam/Floodgate Chest", { { 267, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Mimic Cave/Mimic Cave", { { 268, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Mire Shed/Shack", { { 269, 4 }, { 269, 5 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@King's Tomb/The Crypt", { { 275, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Waterfall Fairy/Waterfall Fairy", { { 276, 4 }, { 276, 5 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Pyramid Fairy/Big Bomb Spot",
                { { 278, 4 }, { 278, 5 } }, updateBombIndicatorStatus)
        updateSectionChestCountFromRoomSlotList(segment, address, "@Spike Cave/Spike Cave", { { 279, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Graveyard Ledge/Cave", { { 283, 9 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@South of Grove/Cave", { { 283, 10 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@C-Shaped House/House", { { 284, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Blind's Hideout/Basement",
                { { 285, 5 }, { 285, 6 }, { 285, 7 }, { 285, 8 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Blind's Hideout/Bombable Wall", { { 285, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Hype Cave/Cave",
                { { 286, 4 }, { 286, 5 }, { 286, 6 }, { 286, 7 }, { 286, 10 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Ice Rod Cave/Ice Rod Cave", { { 288, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Mini Moldorm Cave/Mini Moldorm Cave",
                { { 291, 4 }, { 291, 5 }, { 291, 6 }, { 291, 7 }, { 291, 10 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Pegasus Rocks/Pegasus Rocks", { { 292, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Checkerboard Cave/Checkerboard Cave", { { 294, 9 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Hammer Pegs/Cave", { { 295, 10 } })
    end

    if AUTOTRACKER_ENABLE_DUNGEON_TRACKING then
        -- Read room data for data cache update.
        local changed = false
        local newRoomData
        for _, rooms in pairs(DUNGEON_ROOMS) do
            for _, room in ipairs(rooms) do
                newRoomData = ReadU16(segment, address + (room * 2))
                if SAVED_ROOM_DATA[room] ~= newRoomData then
                    changed = true
                end
                SAVED_ROOM_DATA[room] = newRoomData
            end
        end

        -- Update keys and door data from the cache.
        updateRoomDataFromCache(inLTTP)
    end
end

function updateItemIndicatorStatus(code, status)
    local item = Tracker:FindObjectForCode(code)
    if item then
        if status then
            item.CurrentStage = 1
        else
            item.CurrentStage = 0
        end
    elseif SHOW_ERROR_DEBUG_LOGGING then
        print(string.format("***ERROR*** Couldn't find %s for status update", code))
    end
end

function updateBombIndicatorStatus(status)
    updateItemIndicatorStatus("bombs", status)
end

function updateBatIndicatorStatus(status)
    updateItemIndicatorStatus("powder", status)
end

function updateShovelIndicatorStatus(status)
    updateItemIndicatorStatus("shovel", status)
end

function updateMushroomStatus(status)
    updateItemIndicatorStatus("mushroom", status)
end

function updateNPCItemFlagsActiveLTTP(segment)
    if not (isInLTTP() and isInGameLTTP()) then
        return false
    end
    if AUTOTRACKER_ENABLE_LOCATION_TRACKING then
        updateNPCItemFlagsLTTP(segment, 0x7ef410)
    end
    return true
end

function updateNPCItemFlagsInactiveLTTP(segment)
    if not (isInSM() and isInGameSM()) then
        return false
    end
    if AUTOTRACKER_ENABLE_LOCATION_TRACKING then
        updateNPCItemFlagsLTTP(segment, getSRAMAddressLTTP(0x410))
    end
    return true
end

function updateNPCItemFlagsLTTP(segment, address)
    InvalidateReadCaches()

    updateSectionChestCountFromByteAndFlag(segment, "@Old Man/Old Man", address, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Zora Area/King Zora", address, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Sick Kid/By The Bed", address, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Stumpy/Stumpy", address, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Sahasrahla's Hut/Sahasrahla", address, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Catfish/Catfish", address, 0x20)
    -- 0x40 is unused
    updateSectionChestCountFromByteAndFlag(segment, "@Library/On The Shelf", address, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Ether Tablet/Tablet", address + 0x1, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Bombos Tablet/Tablet", address + 0x1, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Blacksmith/Bring Him Home", address + 0x1, 0x04)
    -- 0x08 is no longer relevant
    updateSectionChestCountFromByteAndFlag(segment, "@Mushroom/Mushroom", address + 0x1, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Potion Shop/Potion Shop", address + 0x1, 0x20, updateMushroomStatus)
    -- 0x40 is unused
    updateSectionChestCountFromByteAndFlag(segment, "@Magic Bat/Magic Bowl", address + 0x1, 0x80, updateBatIndicatorStatus)
end

function updateSectionChestCountFromOverworldIndexAndFlag(segment, locationRef, address, index, callback)
    updateSectionChestCountFromByteAndFlag(segment, locationRef, address + index, 0x40, callback)
end

function updateOverworldEventsActiveLTTP(segment)
    if not (isInLTTP() and isInGameLTTP()) then
        return false
    end
    if AUTOTRACKER_ENABLE_LOCATION_TRACKING then
        updateOverworldEventsLTTP(segment, 0x7ef280)
    end
    return true
end

function updateOverworldEventsInactiveLTTP(segment)
    if not (isInSM() and isInGameSM()) then
        return false
    end
    if AUTOTRACKER_ENABLE_LOCATION_TRACKING then
        updateOverworldEventsLTTP(segment, getSRAMAddressLTTP(0x280))
    end
    return true
end

function updateOverworldEventsLTTP(segment, address)
    InvalidateReadCaches()

    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Spectacle Rock/Spectacle Rock", address, 3)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Floating Island/Island", address, 5)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Maze Race/Maze Race", address, 40)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Flute Spot/Flute Spot", address, 42, updateShovelIndicatorStatus)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Desert Ledge/Desert Ledge", address, 48)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Lake Hylia Island/Lake Hylia Island", address, 53)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@The Dam/Sunken Treasure", address, 59)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Bumper Cave/Ledge", address, 74)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Pyramid/Ledge", address, 91)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Digging Game/Dig For Treasure", address, 104)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Master Sword Pedestal/Pedestal", address, 128)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Zora Area/Zora's Ledge", address, 129)
end

-- ************************* SM functions

function updateItemsActiveSM(segment)
    if not (isInSM() and isInGameSM()) then
        return false
    end
    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateItemsSM(segment, 0x7e09a2)
    end
    return true
end

function updateItemsInactiveSM(segment)
    if not (isInLTTP() and isInGameLTTP()) then
        return false
    end

    local address = 0x703900
    if AutoTracker.SelectedConnectorType.Name ~= CONNECTOR_NAME_SD2SNES then
        address = address + LUA_EXTRA_RAM_OFFSET
    end

    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateItemsSM(segment, address)
    end
    return true
end

function updateItemsSM(segment, address)
    InvalidateReadCaches()

    updateToggleItemFromByteAndFlag(segment, "varia", address + 0x02, 0x01)
    updateToggleItemFromByteAndFlag(segment, "spring", address + 0x02, 0x02)
    updateToggleItemFromByteAndFlag(segment, "morph", address + 0x02, 0x04)
    updateToggleItemFromByteAndFlag(segment, "screw", address + 0x02, 0x08)
    updateToggleItemFromByteAndFlag(segment, "gravity", address + 0x02, 0x20)

    updateToggleItemFromByteAndFlag(segment, "hijump", address + 0x03, 0x01)
    updateToggleItemFromByteAndFlag(segment, "space", address + 0x03, 0x02)
    updateToggleItemFromByteAndFlag(segment, "bomb", address + 0x03, 0x10)
    updateToggleItemFromByteAndFlag(segment, "speed", address + 0x03, 0x20)
    updateToggleItemFromByteAndFlag(segment, "grapple", address + 0x03, 0x40)
    updateToggleItemFromByteAndFlag(segment, "xray", address + 0x03, 0x80)

    updateToggleItemFromByteAndFlag(segment, "wave", address + 0x06, 0x01)
    updateToggleItemFromByteAndFlag(segment, "ice", address + 0x06, 0x02)
    updateToggleItemFromByteAndFlag(segment, "spazer", address + 0x06, 0x04)
    updateToggleItemFromByteAndFlag(segment, "plasma", address + 0x06, 0x08)
    updateToggleItemFromByteAndFlag(segment, "charge", address + 0x07, 0x10)
end

function updateKeycardsActiveSM(segment)
    if not (isInSM() and isInGameSM()) then
        return false
    end
    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateKeycardsSM(segment, 0x7ed830)
    end
    return true
end

function updateKeycardsInactiveSM(segment)
    if not (isInLTTP() and isInGameLTTP()) then
        return false
    end

    local address = 0x703970
    if AutoTracker.SelectedConnectorType.Name ~= CONNECTOR_NAME_SD2SNES then
        address = address + LUA_EXTRA_RAM_OFFSET
    end

    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateKeycardsSM(segment, address)
    end
    return true
end

function updateKeycardsSM(segment, address)
    InvalidateReadCaches()

    updateToggleItemFromByteAndFlag(segment, "crateria_key1", address + 0x00, 0x01)
    updateToggleItemFromByteAndFlag(segment, "crateria_key2", address + 0x00, 0x02)
    updateToggleItemFromByteAndFlag(segment, "crateria_bosskey", address + 0x00, 0x04)
    updateToggleItemFromByteAndFlag(segment, "brinstar_key1", address + 0x00, 0x08)
    updateToggleItemFromByteAndFlag(segment, "brinstar_key2", address + 0x00, 0x10)
    updateToggleItemFromByteAndFlag(segment, "brinstar_bosskey", address + 0x00, 0x20)
    updateToggleItemFromByteAndFlag(segment, "un_key1", address + 0x00, 0x40)
    updateToggleItemFromByteAndFlag(segment, "un_key2", address + 0x00, 0x80)

    updateToggleItemFromByteAndFlag(segment, "un_bosskey", address + 0x01, 0x01)
    updateToggleItemFromByteAndFlag(segment, "maridia_key1", address + 0x01, 0x02)
    updateToggleItemFromByteAndFlag(segment, "maridia_key2", address + 0x01, 0x04)
    updateToggleItemFromByteAndFlag(segment, "maridia_bosskey", address + 0x01, 0x08)
    updateToggleItemFromByteAndFlag(segment, "ws_key1", address + 0x01, 0x10)
    updateToggleItemFromByteAndFlag(segment, "ws_bosskey", address + 0x01, 0x20)
    updateToggleItemFromByteAndFlag(segment, "ln_key1", address + 0x01, 0x40)
    updateToggleItemFromByteAndFlag(segment, "ln_bosskey", address + 0x01, 0x80)

end

function updateAmmoActiveSM(segment)
    if not (isInSM() and isInGameSM()) then
        return false
    end
    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateAmmoSM(segment, 0x7e09c2)
    end
    return true
end

function updateAmmoInactiveSM(segment)
    if not (isInLTTP() and isInGameLTTP()) then
        return false
    end

    local address = 0x703920
    if AutoTracker.SelectedConnectorType.Name ~= CONNECTOR_NAME_SD2SNES then
        address = address + LUA_EXTRA_RAM_OFFSET
    end

    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateAmmoSM(segment, address)
    end
    return true
end

function updateAmmoSM(segment, address)
    InvalidateReadCaches()

    updateAmmoFrom2Bytes(segment, "etank", address + 0x02)
    updateAmmoFrom2Bytes(segment, "missile", address + 0x06)
    updateAmmoFrom2Bytes(segment, "super", address + 0x0a)
    updateAmmoFrom2Bytes(segment, "pb", address + 0x0e)
    updateAmmoFrom2Bytes(segment, "reservetank", address + 0x12)
end

function updateSMBossesActive(segment)
    if not (isInSM() and isInGameSM()) then
        return false
    end
    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateSMBosses(segment, 0x7ed828)
    end
    return true
end

function updateSMBossesInactive(segment)
    if not (isInLTTP() and isInGameLTTP()) then
        return false
    end
    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateSMBosses(segment, getSRAMAddressSM(0x68))
    end
    return true
end

function updateSMBosses(segment, address)
    InvalidateReadCaches()

    updateToggleItemFromByteAndFlag(segment, "kraid", address + 0x1, 0x01)
    updateToggleItemFromByteAndFlag(segment, "ridley", address + 0x2, 0x01)
    updateToggleItemFromByteAndFlag(segment, "phantoon", address + 0x3, 0x01)
    updateToggleItemFromByteAndFlag(segment, "draygon", address + 0x4, 0x01)
end

function updateRoomsActiveSM(segment)
    if not (isInSM() and isInGameSM()) then
        return false
    end
    if AUTOTRACKER_ENABLE_LOCATION_TRACKING then
        updateRoomsSM(segment, 0x7ed870)
    end
    return true
end

function updateRoomsInactiveSM(segment)
    if not (isInLTTP() and isInGameLTTP()) then
        return false
    end
    if AUTOTRACKER_ENABLE_LOCATION_TRACKING then
        updateRoomsSM(segment, getSRAMAddressSM(0xb0))
    end
    return true
end

function updateRoomsSM(segment, address)
    InvalidateReadCaches()

    updateSectionChestCountFromByteAndFlag(segment, "@Power Bomb (Crateria surface)/Power Bomb (Crateria surface)", address + 0x0, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (outside Wrecked Ship bottom)/Missile (outside Wrecked Ship bottom)", address + 0x0, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (outside Wrecked Ship top)/Missile (outside Wrecked Ship top)", address + 0x0, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (outside Wrecked Ship middle)/Missile (outside Wrecked Ship middle)", address + 0x0, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Crateria moat)/Missile (Crateria moat)", address + 0x0, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Gauntlet/Energy Tank, Gauntlet", address + 0x0, 0x20)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Crateria bottom)/Missile (Crateria bottom)", address + 0x0, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Bombs/Bombs", address + 0x0, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Terminator/Energy Tank, Terminator", address + 0x1, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@After Gauntlet/Missile (Crateria gauntlet right)", address + 0x1, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@After Gauntlet/Missile (Crateria gauntlet left)", address + 0x1, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Super Missile (Crateria)/Super Missile (Crateria)", address + 0x1, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Crateria middle)/Missile (Crateria middle)", address + 0x1, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Power Bomb (green Brinstar bottom)/Power Bomb (green Brinstar bottom)", address + 0x1, 0x20)
    updateSectionChestCountFromByteAndFlag(segment, "@Super Missile (Pink Brinstar)/Super Missile (Pink Brinstar)", address + 0x1, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (green Brinstar below super missile)/Missile (green Brinstar below super missile)", address + 0x1, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Super Missile (green Brinstar top)/Super Missile (green Brinstar top)", address + 0x2, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Reserve Tank, Brinstar/Reserve Tank, Brinstar", address + 0x2, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Missiles (green Brinstar behind reserve tank)/Missile (green Brinstar behind missile)", address + 0x2, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Missiles (green Brinstar behind reserve tank)/Missile (green Brinstar behind reserve tank)", address + 0x2, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (pink Brinstar top)/Missile (pink Brinstar top)", address + 0x2, 0x20)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (pink Brinstar bottom)/Missile (pink Brinstar bottom)", address + 0x2, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Charge Beam/Charge Beam", address + 0x2, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Power Bomb (pink Brinstar)/Power Bomb (pink Brinstar)", address + 0x3, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (green Brinstar pipe)/Missile (green Brinstar pipe)", address + 0x3, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Morphing Ball/Morphing Ball", address + 0x3, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Power Bomb (blue Brinstar)/Power Bomb (blue Brinstar)", address + 0x3, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (blue Brinstar middle)/Missile (blue Brinstar middle)", address + 0x3, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Brinstar Ceiling/Energy Tank, Brinstar Ceiling", address + 0x3, 0x20)
    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Etecoons/Energy Tank, Etecoons", address + 0x3, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Super Missile (green Brinstar bottom)/Super Missile (green Brinstar bottom)", address + 0x3, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Waterway/Energy Tank, Waterway", address + 0x4, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (blue Brinstar bottom)/Missile (blue Brinstar bottom)", address + 0x4, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Brinstar Gate/Energy Tank, Brinstar Gate", address + 0x4, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Billy Mays Room/Missile (blue Brinstar top)", address + 0x4, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Billy Mays Room/Missile (blue Brinstar behind missile)", address + 0x4, 0x20)
    updateSectionChestCountFromByteAndFlag(segment, "@X-Ray Scope/X-Ray Scope", address + 0x4, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Power Bomb (red Brinstar sidehopper room)/Power Bomb (red Brinstar sidehopper room)", address + 0x4, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Power Bomb (red Brinstar spike room)/Power Bomb (red Brinstar spike room)", address + 0x5, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (red Brinstar spike room)/Missile (red Brinstar spike room)", address + 0x5, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Spazer/Spazer", address + 0x5, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Kraid/Energy Tank, Kraid", address + 0x5, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Kraid)/Missile (Kraid)", address + 0x5, 0x10)

    updateSectionChestCountFromByteAndFlag(segment, "@Varia Suit/Varia Suit", address + 0x6, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (lava room)/Missile (lava room)", address + 0x6, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Ice Beam/Ice Beam", address + 0x6, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (below Ice Beam)/Missile (below Ice Beam)", address + 0x6, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Crocomire/Energy Tank, Crocomire", address + 0x6, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Hi-Jump Boots/Hi-Jump Boots", address + 0x6, 0x20)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (above Crocomire)/Missile (above Crocomire)", address + 0x6, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Hi-Jump Boots)/Missile (Hi-Jump Boots)", address + 0x6, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank (Hi-Jump Boots)/Energy Tank (Hi-Jump Boots)", address + 0x7, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Power Bomb (Crocomire)/Power Bomb (Crocomire)", address + 0x7, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (below Crocomire)/Missile (below Crocomire)", address + 0x7, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Grappling Beam)/Missile (Grappling Beam)", address + 0x7, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Grappling Beam/Grappling Beam", address + 0x7, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Norfair Reserve Tank Room/Reserve Tank, Norfair", address + 0x7, 0x20)
    updateSectionChestCountFromByteAndFlag(segment, "@Norfair Reserve Tank Room/Missile (Norfair Reserve Tank)", address + 0x7, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (bubble Norfair green door)/Missile (bubble Norfair green door)", address + 0x7, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Missile (bubble Norfair)/Missile (bubble Norfair)", address + 0x8, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Speed Booster)/Missile (Speed Booster)", address + 0x8, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Speed Booster/Speed Booster", address + 0x8, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Wave Beam)/Missile (Wave Beam)", address + 0x8, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Wave Beam/Wave Beam", address + 0x8, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Gold Torizo)/Missile (Gold Torizo)", address + 0x8, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Super Missile (Gold Torizo)/Super Missile (Gold Torizo)", address + 0x8, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Mickey Mouse room)/Missile (Mickey Mouse room)", address + 0x9, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (lower Norfair above fire flea room)/Missile (lower Norfair above fire flea room)", address + 0x9, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Power Bomb (lower Norfair above fire flea room)/Power Bomb (lower Norfair above fire flea room)", address + 0x9, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Power Bomb (Power Bombs of shame)/Power Bomb (Power Bombs of shame)", address + 0x9, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (lower Norfair near Wave Beam)/Missile (lower Norfair near Wave Beam)", address + 0x9, 0x20)
    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Ridley/Energy Tank, Ridley", address + 0x9, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Screw Attack/Screw Attack", address + 0x9, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Firefleas/Energy Tank, Firefleas", address + 0xa, 0x01)

    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Wrecked Ship middle)/Missile (Wrecked Ship middle)", address + 0x10, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Reserve Tank, Wrecked Ship/Reserve Tank, Wrecked Ship", address + 0x10, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Gravity Suit)/Missile (Gravity Suit)", address + 0x10, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Wrecked Ship top)/Missile (Wrecked Ship top)", address + 0x10, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Wrecked Ship/Energy Tank, Wrecked Ship", address + 0x10, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Super Missile (Wrecked Ship left)/Super Missile (Wrecked Ship left)", address + 0x10, 0x20)
    updateSectionChestCountFromByteAndFlag(segment, "@Right Super, Wrecked Ship/Right Super, Wrecked Ship", address + 0x10, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Gravity Suit/Gravity Suit", address + 0x10, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Missile (green Maridia shinespark)/Missile (green Maridia shinespark)", address + 0x11, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Super Missile (green Maridia)/Super Missile (green Maridia)", address + 0x11, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Mama turtle/Energy Tank, Mama turtle", address + 0x11, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (green Maridia tatori)/Missile (green Maridia tatori)", address + 0x11, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Watering Hole/Super Missile (yellow Maridia)", address + 0x11, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Watering Hole/Missile (yellow Maridia super missile)", address + 0x11, 0x20)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (yellow Maridia false wall)/Missile (yellow Maridia false wall)", address + 0x11, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Plasma Beam/Plasma Beam", address + 0x11, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@West Sand Hole/Missile (left Maridia sand pit room)", address + 0x12, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@West Sand Hole/Reserve Tank, Maridia", address + 0x12, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (right Maridia sand pit room)/Missile (right Maridia sand pit room)", address + 0x12, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Power Bomb (right Maridia sand pit room)/Power Bomb (right Maridia sand pit room)", address + 0x12, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (pink Maridia)/Missile (pink Maridia)", address + 0x12, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Super Missile (pink Maridia)/Super Missile (pink Maridia)", address + 0x12, 0x20)
    updateSectionChestCountFromByteAndFlag(segment, "@Spring Ball/Spring Ball", address + 0x12, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Draygon)/Missile (Draygon)", address + 0x12, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Botwoon/Energy Tank, Botwoon", address + 0x13, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Space Jump/Space Jump", address + 0x13, 0x04)
end

-- *************************** Setup/startup stuff

function cleanup()
    -- Clean up existing memory watches and cache data.
    if GAME_WATCH then
        ScriptHost:RemoveMemoryWatch(GAME_WATCH)
    end
    GAME_WATCH = nil

    clearMemoryWatches()

    AUTOTRACKER_IS_IN_LTTP = false
    AUTOTRACKER_IS_IN_SM = false

    OPENED_DOORS = {}
    OPENED_CHESTS = {}
    DUNGEON_ITEMS = {}
    REMAINING_KEYS = {}
    FLOOR_KEYS = {}
end

-- Invoked when the auto-tracker is activated/connected
function autotracker_started()
    if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
        print("**** Auto-Tracker started ****")
    end
    cleanup()

    -- Initialize watch for when the game changes.  Everything else happens in there.
    local address = 0x7033fe
    if AutoTracker.SelectedConnectorType.Name ~= CONNECTOR_NAME_SD2SNES then
        address = address + LUA_EXTRA_RAM_OFFSET
    end
    GAME_WATCH = ScriptHost:AddMemoryWatch("Which Game Is It Anyways", address, 0x02, updateGame, 250)
end

--Invoked when the auto-tracker is stopped.
function autotracker_stopped()
    if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
        print("**** Auto-Tracker stopped ****")
    end
    cleanup()
end

-- This is kind of hacky, but the tracker needs at least one memory watch set up in order to detect that the package
-- uses auto-tracking.  The only one that is active all the time is the "Which Game Is It Anyways" watch, but until we
-- get proper native addressing we can't initialize it until we know what connector is selected.
-- This is a dummy entry that will do nothing, the actual watches will be set when it starts above.
-- Set this watch interval to 60 seconds so it fires infrequently.
function noop()
    return true
end

ScriptHost:AddMemoryWatch("Dummy Auto-Tracking Marker", 0x7e0000, 0x01, noop, 60 * 1000)
