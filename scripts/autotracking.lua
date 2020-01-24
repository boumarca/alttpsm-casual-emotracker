-- Configuration --------------------------------------
AUTOTRACKER_ENABLE_DEBUG_LOGGING = false
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
if AUTOTRACKER_ENABLE_ITEM_TRACKING then
    print("Item Tracking enabled")
end
if AUTOTRACKER_ENABLE_LOCATION_TRACKING then
    print("Location Tracking enabled")
end
if AUTOTRACKER_ENABLE_DUNGEON_TRACKING then
    print("Dungeon Tracking enabled **EXPERIMENTAL**")
end
if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
    print("Debug Logging enabled")
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
AUTOTRACKER_IS_IN_GAME_LTTP = false
AUTOTRACKER_IS_IN_SM = false
AUTOTRACKER_IS_IN_GAME_SM = false

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

function updateGame(segment)
    -- Figure out which game we're in.
    InvalidateReadCaches()

    -- Offset for memory addressing of between game mirrored data that is outside the working RAM and save RAM ranges.
    -- The usb2snes connector uses a different mapping than LUA for this currently, but hopefully this will change.
    local cross_game_offset = 0x0
    if AutoTracker.SelectedConnectorType.Name ~= CONNECTOR_NAME_SD2SNES then
        cross_game_offset = LUA_EXTRA_RAM_OFFSET
    end

    local address = 0x7033fe + cross_game_offset
    local value = ReadU8(segment, address)
    if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
        print("**** Game value:", string.format('0x%x', address), string.format('0x%x', value))
    end

    local changingGame = false
    if (value == 0xFF) then
        changingGame = not AUTOTRACKER_IS_IN_SM
        AUTOTRACKER_IS_IN_LTTP = false
        AUTOTRACKER_IS_IN_SM = true
    elseif (value == 0x00) then
        changingGame = not AUTOTRACKER_IS_IN_LTTP
        AUTOTRACKER_IS_IN_LTTP = true
        AUTOTRACKER_IS_IN_SM = false
    else
        AUTOTRACKER_IS_IN_LTTP = false
        AUTOTRACKER_IS_IN_SM = false
    end

    -- If we're changing games, update the memory watches accordingly.  This forces all the data to be refreshed.
    if changingGame then
        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("**** Game change detected")
        end
        clearMemoryWatches()

        -- Start not in-game when switch occurs, let data refresh occur when in-game state is updated.
        AUTOTRACKER_IS_IN_GAME_LTTP = false
        AUTOTRACKER_IS_IN_GAME_SM = false

        -- Link to the Past
        if AUTOTRACKER_IS_IN_LTTP then
            -- WRAM watches
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP In-Game status", 0x7e0010, 0x01, updateInGameStatusLTTP, 250))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP Item Data", 0x7ef340, 0x90, updateItemsActiveLTTP))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP NPC Item Data", 0x7ef410, 0x2, updateNPCItemFlagsActiveLTTP))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP Room Data", 0x7ef000, 0x250, updateRoomsActiveLTTP))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP Overworld Event Data", 0x7ef280, 0x82, updateOverworldEventsActiveLTTP))

            -- Extra cross-game RAM watches specifically for items.
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Item Data In LTTP", 0x703900 + cross_game_offset, 0x10, updateItemsInactiveSM))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Ammo Data In LTTP", 0x703920 + cross_game_offset, 0x16, updateAmmoInactiveSM))

            -- SRAM watches for things that aren't in cross-game extra RAM.
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Boss Data In LTTP", getSRAMAddressSM(0x68), 0x08, updateSMBossesInactive))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Room Data In LTTP", getSRAMAddressSM(0xb0), 0x20, updateRoomsInactiveSM))

        -- Super Metroid
        elseif AUTOTRACKER_IS_IN_SM then
            -- WRAM watches
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM In-Game status", 0x7e0998, 0x01, updateInGameStatusSM, 250))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Item Data", 0x7e09a0, 0x10, updateItemsActiveSM))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Ammo Data", 0x7e09c2, 0x16, updateAmmoActiveSM))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Boss Data", 0x7ed828, 0x08, updateSMBossesActive))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("SM Room Data", 0x7ed870, 0x20, updateRoomsActiveSM))

            -- Extra cross-game RAM watches specifically for items.
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP Item Data In SM", 0x703b40 + cross_game_offset, 0x90, updateItemsInactiveLTTP))

            -- SRAM watches for things that aren't in cross-game extra RAM.
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP NPC Item Data In SM", getSRAMAddressLTTP(0x410), 0x2, updateNPCItemFlagsInactiveLTTP))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP Room In SM", getSRAMAddressLTTP(0x0), 0x250, updateRoomsInactiveLTTP))
            table.insert(MEMORY_WATCHES, ScriptHost:AddMemoryWatch("LTTP Overworld Event Data In SM", getSRAMAddressLTTP(0x280), 0x82, updateOverworldEventsInactiveLTTP))

        end

        -- Watches for both games all the time.
        -- This tracker has no completion item for each game yet, uncomment if it gets added in future...
        --table.insert(sramWatches, ScriptHost:AddMemoryWatch("LTTP DONE", 0X703506 + cross_game_offset, 0x01, updateLTTPcompletion))
        --table.insert(sramWatches, ScriptHost:AddMemoryWatch("SM DONE", 0X703402 + cross_game_offset, 0x02, updateSMcompletion))
    end

    return true
end

function updateInGameStatusLTTP(segment)
    if not AUTOTRACKER_IS_IN_LTTP then
        AUTOTRACKER_IS_IN_GAME_LTTP = false
        return false
    else
        InvalidateReadCaches()
        local mainModuleIdx = ReadU8(segment, 0x7e0010)

        AUTOTRACKER_IS_IN_GAME_LTTP = (mainModuleIdx > 0x05 and mainModuleIdx < 0x1b and mainModuleIdx ~= 0x14 and mainModuleIdx ~= 0x17)
        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("** LTTP Status:", "0x7e0010", string.format('0x%x', mainModuleIdx), AUTOTRACKER_IS_IN_GAME_LTTP)
        end
        return true
    end
end

function updateInGameStatusSM(segment)
    if not AUTOTRACKER_IS_IN_SM then
        AUTOTRACKER_IS_IN_GAME_SM = false
        return false
    else
        InvalidateReadCaches()

        local mainModuleIdx = ReadU8(segment, 0x7e0998)

        AUTOTRACKER_IS_IN_GAME_SM = (mainModuleIdx >= 0x07 and mainModuleIdx <= 0x12)
        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("** SM status:", '0x7e0998', string.format('0x%x', mainModuleIdx), AUTOTRACKER_IS_IN_GAME_SM)
        end
        return true
    end
end

function updateLTTPcompletion(segment)
    if not (AUTOTRACKER_IS_IN_LTTP and AUTOTRACKER_IS_IN_GAME_LTTP) then
        return false
    end

    InvalidateReadCaches()

    local address = 0x703506
    if AutoTracker.SelectedConnectorType.Name ~= CONNECTOR_NAME_SD2SNES then
        address = address + LUA_EXTRA_RAM_OFFSET
    end

    local item = Tracker:FindObjectForCode("ganon")
    if item then
        if (ReadU8(segment, address) == 0x01) then
            item.Active = true
        end
    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find item: ", "ganon")
    end

    return true
end

function updateSMcompletion(segment)
    if not (AUTOTRACKER_IS_IN_SM and AUTOTRACKER_IS_IN_GAME_SM) then
        return false
    end

    InvalidateReadCaches()

    local address = 0x703403
    if AutoTracker.SelectedConnectorType.Name ~= CONNECTOR_NAME_SD2SNES then
        address = address + LUA_EXTRA_RAM_OFFSET
    end

    local item = Tracker:FindObjectForCode("brain")
    if item then
        if (ReadU8(segment, address) == 0x01) then
            item.Active = true
        end
    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find item: ", "brain")
    end

    return true
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
    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING then
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
    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING then
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
    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find item: ", code)
    end
end

function updatePseudoProgressiveItemFromByteAndFlag(segment, code, address, flag)
    local item = Tracker:FindObjectForCode(code)
    if item then
        local value = ReadU8(segment, address)
        local flagTest = value & flag

        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("Progressive item: ", code, string.format('0x%x', address),
                    string.format('0x%x', value), string.format('0x%x', flag), flagTest ~= 0)
        end

        if flagTest ~= 0 then
            item.CurrentStage = math.max(1, item.CurrentStage)
        -- For pseudo-progressive items, if the next stage has already been marked, don't downgrade it.
        -- ex. Turning in the mushroom in LTTP removes it from your inventory.
        elseif item.CurrentStage < 2 then
            item.CurrentStage = 0
        end
    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find item:", code)
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
    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING then
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
    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING then
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
    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING then
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
    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING then
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
    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find item: ", code)
    end
end

function resetDungeonCacheTable(cacheTable)
    cacheTable.hc = 0
    cacheTable.ep = 0
    cacheTable.dp = 0
    cacheTable.toh = 0
    cacheTable.pod = 0
    cacheTable.sp = 0
    cacheTable.sw = 0
    cacheTable.tt = 0
    cacheTable.ip = 0
    cacheTable.mm = 0
    cacheTable.tr = 0
    cacheTable.gt = 0
    cacheTable.gt2 = 0
end

function updateDungeonCacheTableFromByteAndFlag(segment, cacheTable, code, address, flag)
    local value = ReadU8(segment, address)
    local check = value & flag
    if check ~= 0 then
        cacheTable[code] = cacheTable[code] + 1
    end
end

function updateDungeonCacheTableFromRoomSlot(segment, cacheTable, code, address, slot)
    local roomData = ReadU16(segment, address + (slot[1] * 2))
    local flag = 1 << slot[2]
    local check = roomData & flag
    if check ~= 0 then
        cacheTable[code] = cacheTable[code] + 1
    end
end

-- Update opened door cache for a door with two separate room slots in case they only opened one side.
-- Most small key doors have both sides in a single room, but some have the two sides in two different rooms.
function updateDungeonDoorCacheFromTwoRooms(segment, code, address, slot1, slot2)
    local roomData1 = ReadU16(segment, address + (slot1[1] * 2))
    local flag1 = 1 << slot1[2]
    local roomData2 = ReadU16(segment, address + (slot2[1] * 2))
    local flag2 = 1 << slot2[2]
    local check = (roomData1 & flag1) + (roomData2 & flag2)
    if check ~= 0 then
        OPENED_DOORS[code] = OPENED_DOORS[code] + 1
    end
end

function updateDungeonLocationFromCache(locationRef, code)
    local location = Tracker:FindObjectForCode(locationRef)
    if location then
        -- Do not auto-track this if the user has manually modified it
        if location.Owner.ModifiedByUser then
            if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
                print("* Skipping user modified location: ", locationRef)
            end
            return
        end

        local totalKeys = REMAINING_KEYS[code] + OPENED_DOORS[code]
        local keysFromChests = math.max(0, totalKeys - FLOOR_KEYS[code])
        local itemsFound = math.floor(math.min(location.ChestCount, math.max(0, OPENED_CHESTS[code] - DUNGEON_ITEMS[code] - keysFromChests)))
        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("Dungeon item count: ", locationRef,
                    "Total keys: " .. totalKeys, "Remaining keys: " .. REMAINING_KEYS[code],
                    "Opened doors: " .. OPENED_DOORS[code], "Floor keys: " .. FLOOR_KEYS[code],
                    "Opened chests: " .. OPENED_CHESTS[code], "Dungeon items: " .. DUNGEON_ITEMS[code],
                    "Keys from chests: " .. keysFromChests, "Items found: " .. itemsFound)
        end
        location.AvailableChestCount = location.ChestCount - itemsFound

    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find location:", locationRef)
    end
end

function updateGanonsTowerFromCache()
    local dungeon = Tracker:FindObjectForCode("@Ganon's Tower/Dungeon")
    local tower = Tracker:FindObjectForCode("@Ganon's Tower/Tower")

    local totalKeys = REMAINING_KEYS.gt + OPENED_DOORS.gt
    local keysFromChests = math.max(0, totalKeys - FLOOR_KEYS.gt)
    local itemsFound1 = math.floor(math.min(dungeon.ChestCount, OPENED_CHESTS.gt))
    local itemsFound2 = math.floor(math.min(tower.ChestCount, OPENED_CHESTS.gt2))

    if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
        print("Dungeon item count: Ganon's Tower",
                "Total keys: " .. totalKeys, "Remaining keys: " .. REMAINING_KEYS.gt,
                "Opened doors: " .. OPENED_DOORS.gt, "Floor keys: " .. FLOOR_KEYS.gt,
                "Opened chests downstairs: " .. OPENED_CHESTS.gt, "Opened chests upstairs: " .. OPENED_CHESTS.gt2,
                "Dungeon items: " .. DUNGEON_ITEMS.gt, "Keys from chests: " .. keysFromChests,
                "Items found downstars: " .. itemsFound1, "Items found upstairs: " .. itemsFound2)
    end
    dungeon.AvailableChestCount = dungeon.ChestCount - itemsFound1
    tower.AvailableChestCount = tower.ChestCount - itemsFound2
end

function updateAllDungeonLocationsFromCache()
    -- Light World
    updateDungeonLocationFromCache("@Hyrule Castle & Sanctuary/Escape", "hc")
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
    updateGanonsTowerFromCache()
end

function updateItemsActiveLTTP(segment)
    if not (AUTOTRACKER_IS_IN_LTTP and AUTOTRACKER_IS_IN_GAME_LTTP) then
        return false
    end
    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateItemsLTTP(segment, 0x7ef300)
    end
    return true
end

function updateItemsInactiveLTTP(segment)
    if not (AUTOTRACKER_IS_IN_SM and AUTOTRACKER_IS_IN_GAME_SM) then
        return false
    end

    local address = 0x703b00
    if AutoTracker.SelectedConnectorType.Name ~= CONNECTOR_NAME_SD2SNES then
        address = address + LUA_EXTRA_RAM_OFFSET
    end

    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateItemsLTTP(segment, address)
    end
    return true
end

function updateItemsLTTP(segment, address)
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
    updateToggleItemFromByteAndFlag(segment, "powder", address + 0x8c, 0x10)
    updateToggleItemFromByteAndFlag(segment, "bow", address + 0x8e, 0x80)
    updateToggleItemFromByteAndFlag(segment, "silvers", address + 0x8e, 0x40)

    updatePseudoProgressiveItemFromByteAndFlag(segment, "mushroom", address + 0x8c, 0x20)
    updatePseudoProgressiveItemFromByteAndFlag(segment, "shovel", address + 0x8c, 0x04)

    updateBottles(segment, address + 0x5c)
    updateFlute(segment, address + 0x8c)
    updateMirror(segment, address + 0x53)
    updateAga1(segment, address + 0xc5)

    --  It may seem unintuitive, but these locations are controlled by flags stored adjacent to the item data,
    --  which makes it more efficient to update them here.
    updateSectionChestCountFromByteAndFlag(segment, "@Secret Passage/Uncle", address + 0xc6, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Hobo/Under The Bridge", address + 0xc9, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Bottle Merchant/Bottle Merchant", address + 0xc9, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Purple Chest/Purple Chest", address + 0xc9, 0x10)

    -- Update remaining small keys and dungeon item (map/compass/big key) data caches from item data.
    if AUTOTRACKER_ENABLE_DUNGEON_TRACKING then
        resetDungeonCacheTable(REMAINING_KEYS)
        resetDungeonCacheTable(DUNGEON_ITEMS)

        -- Remaining keys.
        REMAINING_KEYS.hc = ReadU8(segment, address + 0x7c)
        REMAINING_KEYS.ep = ReadU8(segment, address + 0x7e)
        REMAINING_KEYS.dp = ReadU8(segment, address + 0x7f)
        REMAINING_KEYS.toh = ReadU8(segment, address + 0x86)
        REMAINING_KEYS.pod = ReadU8(segment, address + 0x82)
        REMAINING_KEYS.sp = ReadU8(segment, address + 0x81)
        REMAINING_KEYS.sw = ReadU8(segment, address + 0x84)
        REMAINING_KEYS.tt = ReadU8(segment, address + 0x87)
        REMAINING_KEYS.ip = ReadU8(segment, address + 0x85)
        REMAINING_KEYS.mm = ReadU8(segment, address + 0x83)
        REMAINING_KEYS.tr = ReadU8(segment, address + 0x88)
        REMAINING_KEYS.gt = ReadU8(segment, address + 0x89)

        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("Remaining key counts: ", table.tostring(REMAINING_KEYS))
        end

        -- Compasses
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "gt", address + 0x64, 0x04)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "tr", address + 0x64, 0x08)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "tt", address + 0x64, 0x10)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "toh", address + 0x64, 0x20)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "ip", address + 0x64, 0x40)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "sw", address + 0x64, 0x80)

        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "mm", address + 0x65, 0x01)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "pod", address + 0x65, 0x02)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "sp", address + 0x65, 0x04)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "dp", address + 0x65, 0x10)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "ep", address + 0x65, 0x20)

        -- Big keys
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "gt", address + 0x66, 0x04)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "tr", address + 0x66, 0x08)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "tt", address + 0x66, 0x10)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "toh", address + 0x66, 0x20)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "ip", address + 0x66, 0x40)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "sw", address + 0x66, 0x80)

        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "mm", address + 0x67, 0x01)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "pod", address + 0x67, 0x02)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "sp", address + 0x67, 0x04)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "dp", address + 0x67, 0x10)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "ep", address + 0x67, 0x20)

        -- Maps
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "gt", address + 0x68, 0x04)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "tr", address + 0x68, 0x08)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "tt", address + 0x68, 0x10)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "toh", address + 0x68, 0x20)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "ip", address + 0x68, 0x40)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "sw", address + 0x68, 0x80)

        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "mm", address + 0x69, 0x01)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "pod", address + 0x69, 0x02)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "sp", address + 0x69, 0x04)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "dp", address + 0x69, 0x10)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "ep", address + 0x69, 0x20)
        updateDungeonCacheTableFromByteAndFlag(segment, DUNGEON_ITEMS, "hc", address + 0x69, 0x80)

        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("Dungeon item counts: ", table.tostring(DUNGEON_ITEMS))
        end

        -- Update dungeon location chest counts based on cached data.
        updateAllDungeonLocationsFromCache()
    end
end

function updateRoomsActiveLTTP(segment)
    if not (AUTOTRACKER_IS_IN_LTTP and AUTOTRACKER_IS_IN_GAME_LTTP) then
        return false
    end
    updateRoomsLTTP(segment, 0x7ef000)
    return true
end

function updateRoomsInactiveLTTP(segment)
    if not (AUTOTRACKER_IS_IN_SM and AUTOTRACKER_IS_IN_GAME_SM) then
        return false
    end
    updateRoomsLTTP(segment, getSRAMAddressLTTP(0x0))
    return true
end

function updateRoomsLTTP(segment, address)
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
        updateSectionChestCountFromRoomSlotList(segment, address, "@The Well/Cave",
                { { 47, 5 }, { 47, 6 }, { 47, 7 }, { 47, 8 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@The Well/Bombable Wall", { { 47, 4 } })
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
        updateSectionChestCountFromRoomSlotList(segment, address, "@Tavern/Back Room", { { 259, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Link's House/Link's House", { { 260, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Sahasrala's Hut/Back Room",
                { { 261, 4 }, { 261, 5 }, { 261, 6 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Brewery/Brewery", { { 262, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Chest Game/Chest Game", { { 262, 10 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Chicken House/Bombable Wall", { { 264, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Aginah's Cave/Aginah's Cave", { { 266, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Floodgate Chests/Floodgate Chest", { { 267, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Mimic Cave/Mimic Cave", { { 268, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Mire Shed/Shack", { { 269, 4 }, { 269, 5 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@King's Tomb/The Crypt", { { 275, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Waterfall Fairy/Waterfall Fairy", { { 276, 4 }, { 276, 5 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Pyramid Fairy/Big Bomb Spot",
                { { 278, 4 }, { 278, 5 } }, updateBombIndicatorStatus)
        updateSectionChestCountFromRoomSlotList(segment, address, "@Spike Cave/Spike Cave", { { 279, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Graveyard Ledge/Cave", { { 283, 9 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Cave 45/Cave 45", { { 283, 10 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@C-Shaped House/House", { { 284, 4 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Blind's House/Basement",
                { { 285, 5 }, { 285, 6 }, { 285, 7 }, { 285, 8 } })
        updateSectionChestCountFromRoomSlotList(segment, address, "@Blind's House/Bombable Wall", { { 285, 4 } })
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
        -- Update dungeon room data cache for counting dungeon items without cheating.
        resetDungeonCacheTable(FLOOR_KEYS)
        resetDungeonCacheTable(OPENED_DOORS)
        resetDungeonCacheTable(OPENED_CHESTS)


        -- *** Hyrule Castle & Sanctuary
        -- Room 114 offset 0xE4 (First basement room with blue key guard, locked door, and chest)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "hc", address, { 114, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "hc", address, { 114, 15 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "hc", address, { 114, 4 })

        -- Room 113 offset 0xE2 (Room before stairs to prison)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "hc", address, { 113, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "hc", address, { 113, 15 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "hc", address, { 113, 4 })

        -- Room 128 offset 0x100 (Zelda's cell)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "hc", address, { 128, 4 })

        -- Room 50 offset 0x64 (Dark cross)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "hc", address, { 50, 4 })
        updateDungeonDoorCacheFromTwoRooms(segment, "hc", address, { 50, 15 }, { 34, 15 })

        -- Room 33 offset 0x42 (Dark room with key on rat)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "hc", address, { 33, 10 })
        updateDungeonDoorCacheFromTwoRooms(segment, "hc", address, { 33, 15 }, { 17, 13 })

        -- Room 17 offset 0x22 (Escape secret side room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "hc", address, { 17, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "hc", address, { 17, 5 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "hc", address, { 17, 6 })

        -- Room 18 offset 0x24 (Sanctuary)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "hc", address, { 18, 4 })


        -- *** Eastern Palace
        -- Room 186 offset 0x174 (Small key under pot)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "ep", address, { 186, 10 })
        updateDungeonDoorCacheFromTwoRooms(segment, "ep", address, { 186, 15 }, { 185, 15 })

        -- Room 185 offset 0x172 (Rolling ball entrance room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "ep", address, { 185, 4 })

        -- Room 170 offset 0x154 (Map chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "ep", address, { 170, 4 })

        -- Room 168 offset 0x150 (Compass chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "ep", address, { 168, 4 })

        -- Room 169 offset 0x152 (Big chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "ep", address, { 169, 4 })

        -- Room 184 offset 0x170 (Big key chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "ep", address, { 184, 4 })

        -- Room 153 offset 0x132 (Small key on mimic)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "ep", address, { 153, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "ep", address, { 153, 15 })

        -- Room 200 offset 0x190 (Armos Knights)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "ep", address, { 200, 11 })


        -- *** Desert Palace
        -- Room 115 offset 0xE6 (Big chest and torch item)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "dp", address, { 115, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "dp", address, { 115, 10 })

        -- Room 116 offset 0xE8 (Top room single chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "dp", address, { 116, 4 })

        -- Room 117 offset 0xE9 (Big key chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "dp", address, { 117, 4 })

        -- Room 133 offset 0x10A (Room before big key chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "dp", address, { 133, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "dp", address, { 133, 14 })

        -- Room 99 offset 0xC6 (First flying tile room in back)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "dp", address, { 99, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "dp", address, { 99, 15 })

        -- Room 83 offset 0xA6 (Long room with beamos)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "dp", address, { 83, 10 })
        updateDungeonDoorCacheFromTwoRooms(segment, "dp", address, { 83, 13 }, { 67, 13 })

        -- Room 67 offset 0x86 (Second flying tile room before boss)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "dp", address, { 67, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "dp", address, { 67, 14 })

        -- Room 51 offset 0x66 (Lanmolas)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "dp", address, { 51, 11 })


        -- *** Tower of Hera
        -- Room 119 offset 0xEE (Entrance)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "toh", address, { 119, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "toh", address, { 119, 15 })

        -- Room 135 offset 0x10E (Basement)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "toh", address, { 135, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "toh", address, { 135, 4 })

        -- Room 39 offset 0x4E (Big chest room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "toh", address, { 39, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "toh", address, { 39, 5 })

        -- Room 7 offset 0xE (Trolldorm)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "toh", address, { 7, 11 })


        -- *** Palace of Darkness
        -- Room 9 offset 0x12 (Left entrance basement room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "pod", address, { 9, 4 })

        -- Room 74 offset 0x94 (Entrance area locked door, double-sided)
        updateDungeonDoorCacheFromTwoRooms(segment, "pod", address, { 74, 13 }, { 58, 15 })

        -- Room 58 offset 0x74 (Big key chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "pod", address, { 58, 4 })

        -- Room 10 offset 0x14 (Basement teleporter room with locked door stairs to big key)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "pod", address, { 10, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "pod", address, { 10, 15 })

        -- Room 43 offset 0x56 (Coming up from basement, bombable wall to second chest in bouncy room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "pod", address, { 43, 4 })

        -- Room 42 offset 0x54 (Bouncy enemy room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "pod", address, { 42, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "pod", address, { 42, 5 })
        updateDungeonDoorCacheFromTwoRooms(segment, "pod", address, { 42, 14 }, { 26, 12 })

        -- Room 26 offset 0x34 (Crumble bridge room and adjacent)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "pod", address, { 26, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "pod", address, { 26, 5 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "pod", address, { 26, 6 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "pod", address, { 26, 15 })
        updateDungeonDoorCacheFromTwoRooms(segment, "pod", address, { 26, 14 }, { 25, 14 })

        -- Room 25 offset 0x32 (Dark maze)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "pod", address, { 25, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "pod", address, { 25, 5 })

        -- Room 106 offset 0xD4 (Room before boss)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "pod", address, { 106, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "pod", address, { 106, 5 })

        -- Room 11 offset 0x16 (Basement locked door leading to boss)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "pod", address, { 11, 13 })

        -- Room 90 offset 0xB4 (Helmasaur King)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "pod", address, { 90, 11 })


        -- *** Swamp Palace
        -- Room 40 offset 0x50 (Entrance)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sp", address, { 40, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "sp", address, { 40, 15 })

        -- Room 56 offset 0x70 (First basement room with key under pot)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "sp", address, { 56, 10 })
        updateDungeonDoorCacheFromTwoRooms(segment, "sp", address, { 56, 14 }, { 55, 12 })

        -- Room 55 offset 0x6E (First water valve and key)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sp", address, { 55, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "sp", address, { 55, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "sp", address, { 55, 13 })

        -- Room 70 offset 0x8C (Map chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sp", address, { 70, 4 })

        -- Room 54 offset 0x6C (Central big chest room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sp", address, { 54, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "sp", address, { 54, 10 })
        updateDungeonDoorCacheFromTwoRooms(segment, "sp", address, { 54, 14 }, { 38, 15 })  -- Top locked door
        updateDungeonDoorCacheFromTwoRooms(segment, "sp", address, { 54, 13 }, { 53, 15 })  -- Left locked door

        -- Room 53 offset 0x6A (Second water valve, pot key, and big key chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sp", address, { 53, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "sp", address, { 53, 10 })

        -- Room 52 offset 0x68 (Left side chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sp", address, { 52, 4 })

        -- Room 118 offset 0xEC (Underwater chests)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sp", address, { 118, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sp", address, { 118, 5 })

        -- Room 102 offset 0xCC (Last chest before boss)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sp", address, { 102, 4 })

        -- Room 22 offset 0x2C (Room before boss)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "sp", address, { 22, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "sp", address, { 22, 14 })

        -- Room 6 offset 0xC (Arrghus)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sp", address, { 6, 11 })


        -- *** Skull Woods
        -- Room 103 offset 0xCE (Bottom left drop down room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sw", address, { 103, 4 })

        -- Room 87 offset 0xAE (Drag the statue room and corner chest from first entrance)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sw", address, { 87, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sw", address, { 87, 5 })
        updateDungeonDoorCacheFromTwoRooms(segment, "sw", address, { 87, 13 }, { 88, 14 })

        -- Room 88 offset 0xB0 (First entrance with big chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sw", address, { 88, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sw", address, { 88, 5 })
        updateDungeonDoorCacheFromTwoRooms(segment, "sw", address, { 88, 13 }, { 104, 14 })

        -- Room 104 offset 0xD0 (Soft-lock potential room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sw", address, { 104, 4 })

        -- Room 86 offset 0xAC (Exit towards boss area)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "sw", address, { 86, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "sw", address, { 86, 15 })

        -- Room 89 offset 0xB2 (Back area entrance)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sw", address, { 89, 4 })
        updateDungeonDoorCacheFromTwoRooms(segment, "sw", address, { 89, 15 }, { 73, 13 })

        -- Room 57 offset 0x72 (Drop down to boss)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "sw", address, { 57, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "sw", address, { 57, 14 })

        -- Room 41 offset 0x52 (Mothula)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "sw", address, { 41, 11 })


        -- *** Thieves Town
        -- Room 219 offset 0x1B6 (Entrance, SW main area)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tt", address, { 219, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tt", address, { 219, 5 })

        -- Room 203 offset 0x196 (NW main area)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tt", address, { 203, 4 })

        -- Room 220 offset 0x1B8 (SE main area)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tt", address, { 220, 4 })

        -- Room 188 offset 0x178 (Room before boss)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "tt", address, { 188, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "tt", address, { 188, 15 })

        -- Room 171 offset 0x156 (Locked door to 2F)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "tt", address, { 171, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "tt", address, { 171, 15 })

        -- Room 101 offset 0xCA (2F attic)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tt", address, { 101, 4 })

        -- Room 69 (nice) offset 0x8A ("Maiden" cell)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tt", address, { 69, 4 })

        -- Room 68 offset 0x88 (Big chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tt", address, { 68, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "tt", address, { 68, 14 })

        -- Room 172 offset 0x158 (Blind)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tt", address, { 172, 11 })


        -- *** Ice Palace
        -- Room 14 offset 0x1C (Entrance)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "ip", address, { 14, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "ip", address, { 14, 15 })

        -- Room 46 offset 0x5C (Penguin ice room with first chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "ip", address, { 46, 4 })

        -- Room 62 offset 0x7C (Conveyor room before bomb jump)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "ip", address, { 62, 10 })
        updateDungeonDoorCacheFromTwoRooms(segment, "ip", address, { 62, 14 }, { 78, 14 })

        -- Room 126 offset 0xFC (Room above big chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "ip", address, { 126, 4 })
        updateDungeonDoorCacheFromTwoRooms(segment, "ip", address, { 126, 15 }, { 142, 15 })

        -- Room 158 offset 0x13C (Big chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "ip", address, { 158, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "ip", address, { 158, 15 })

        -- Room 159 offset 0x13E (Ice room key in pot east of block pushing room)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "ip", address, { 159, 10 })

        -- Room 174 offset 0x15C (Beginning of ascent up the back)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "ip", address, { 174, 4 })

        -- Room 95 offset 0xBE (Hookshot over spikes)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "ip", address, { 95, 4 })
        updateDungeonDoorCacheFromTwoRooms(segment, "ip", address, { 95, 15 }, { 94, 15 })

        -- Room 63 offset 0x7E (Pulling tongues before big key)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "ip", address, { 63, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "ip", address, { 63, 10 })

        -- Room 31 offset 0x3E (Big key chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "ip", address, { 31, 4 })

        -- Room 190 offset 0x17C (Block switch room)
        updateDungeonDoorCacheFromTwoRooms(segment, "ip", address, { 190, 14 }, { 191, 15 })

        -- Room 222 offset 0x1BC (Kholdstare)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "ip", address, { 222, 11 })


        -- *** Misery Mire
        -- Room 162 offset 0x144 (Map chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "mm", address, { 162, 4 })

        -- Room 179 offset 0x166 (Right side spike room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "mm", address, { 179, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "mm", address, { 179, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "mm", address, { 179, 15 })

        -- Room 161 offset 0x142 (Top left crystal switch + pot key)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "mm", address, { 161, 10 })
        updateDungeonDoorCacheFromTwoRooms(segment, "mm", address, { 161, 15 }, { 177, 14 })

        -- Room 194 offset 0x184 (Central room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "mm", address, { 194, 4 })
        updateDungeonDoorCacheFromTwoRooms(segment, "mm", address, { 194, 15 }, { 195, 15 })

        -- Room 195 offset 0x186 (Big chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "mm", address, { 195, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "mm", address, { 195, 5 })

        -- Room 193 offset 0x182 (Conveyor belt and tile room, compass chest)
        updateDungeonDoorCacheFromTwoRooms(segment, "mm", address, { 194, 14 }, { 193, 14 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "mm", address, { 193, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "mm", address, { 193, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "mm", address, { 193, 15 })

        -- Room 209 offset 0x1A2 (Big key chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "mm", address, { 209, 4 })

        -- Room 147 offset 0x126 (Basement locked rupee room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "mm", address, { 147, 14 })

        -- Room 144 offset 0x120 (Vitreous)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "mm", address, { 144, 11 })


        -- *** Turtle Rock
        -- Room 214 offset 0x1AC (Map chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tr", address, { 214, 4 })

        -- Room 183 offset 0x16E (Double spike rollers)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tr", address, { 183, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tr", address, { 183, 5 })

        -- Room 198 offset 0x18C (1F central room)
        updateDungeonDoorCacheFromTwoRooms(segment, "tr", address, { 198, 15 }, { 182, 13 })

        -- Room 182 offset 0x16C (Chain Chomp room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tr", address, { 182, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "tr", address, { 182, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "tr", address, { 182, 12 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "tr", address, { 182, 15 })

        -- Room 19 offset 0x26 (Quad anti-fairy room)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "tr", address, { 19, 10 })
        updateDungeonDoorCacheFromTwoRooms(segment, "tr", address, { 19, 15 }, { 20, 14 })

        -- Room 20 offset 0x28 (Central tube room with big key chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tr", address, { 20, 4 })

        -- Room 36 offset 0x48 (Big chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tr", address, { 36, 4 })

        -- Room 4 offset 0x8 (Spike roller after big key door)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tr", address, { 4, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "tr", address, { 4, 15 })

        -- Room 213 offset 0x1AA (Laser bridge)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tr", address, { 213, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tr", address, { 213, 5 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tr", address, { 213, 6 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tr", address, { 213, 7 })

        -- Room 197 offset 0x18A (Door to crystal switch room before boss)
        updateDungeonDoorCacheFromTwoRooms(segment, "tr", address, { 197, 15 }, { 196, 15 })

        -- Room 164 offset 0x148 (Trinexx)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "tr", address, { 164, 11 })


        -- *** Ganon's Tower (dungeon)
        -- Room 140 offset 0x118 (First two rooms with torch, plus Bob's chest and big chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 140, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 140, 5 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 140, 6 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 140, 7 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 140, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "gt", address, { 140, 13 })

        -- Room 139 offset 0x116 (Hookshot block room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 139, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "gt", address, { 139, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "gt", address, { 139, 14 })

        -- Room 155 offset 0x136 (Pot key below hookshot room with locked door)
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "gt", address, { 155, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "gt", address, { 155, 15 })

        -- Room 125 offset 0xFA (Entrance to warp maze)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 125, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "gt", address, { 125, 13 })

        -- Room 123 offset 0xF6 (Four chests on left side above hookshot room, plus end of right side)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 123, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 123, 5 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 123, 6 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 123, 7 })
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "gt", address, { 123, 10 })
        updateDungeonDoorCacheFromTwoRooms(segment, "gt", address, { 123, 14 }, { 124, 13 })

        -- Room 124 offset 0xF8 (Rando room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 124, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 124, 5 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 124, 6 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 124, 7 })

        -- Room 28 offset 0x38 (Big key chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 28, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 28, 5 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 28, 6 })

        -- Room 141 offset 0x11A (Tile room)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 141, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "gt", address, { 141, 14 })

        -- Room 157 offset 0x13A (Last four chests on right side)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 157, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 157, 5 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 157, 6 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt", address, { 157, 7 })


        -- *** Ganon's Tower (tower)
        -- Room 61 offset 0x7A (Mini helmasaur room before Moldorm 2)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt2", address, { 61, 4 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt2", address, { 61, 5 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt2", address, { 61, 6 })
        -- Floor key and opened doors need to be in the main GT count for the math!
        updateDungeonCacheTableFromRoomSlot(segment, FLOOR_KEYS, "gt", address, { 61, 10 })
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_DOORS, "gt", address, { 61, 14 })
        updateDungeonDoorCacheFromTwoRooms(segment, "gt", address, { 61, 13 }, { 77, 15 })

        -- Room 77 offset 0x9A (Validation chest)
        updateDungeonCacheTableFromRoomSlot(segment, OPENED_CHESTS, "gt2", address, { 77, 4 })


        if AUTOTRACKER_ENABLE_DEBUG_LOGGING then
            print("Floor key counts: ", table.tostring(FLOOR_KEYS))
            print("Opened door counts: ", table.tostring(OPENED_DOORS))
            print("Opened chest counts: ", table.tostring(OPENED_CHESTS))
        end

        -- Update dungeon location chest counts based on cached data.
        updateAllDungeonLocationsFromCache()
    end
end

function updateBombIndicatorStatus(status)
    local item = Tracker:FindObjectForCode("bombs")
    if item then
        if status then
            item.CurrentStage = 1
        else
            item.CurrentStage = 0
        end
    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find bombs for status update")
    end
end

function updateBatIndicatorStatus(status)
    local item = Tracker:FindObjectForCode("powder")
    if item then
        if status then
            item.CurrentStage = 1
        else
            item.CurrentStage = 0
        end
    end
end

function updateMushroomStatus(status)
    local item = Tracker:FindObjectForCode("mushroom")
    if item then
        if status then
            item.CurrentStage = 2
        end
    elseif AUTOTRACKER_ENABLE_DEBUG_LOGGING then
        print("***ERROR*** Couldn't find mushroom for status update")
    end
end

function updateNPCItemFlagsActiveLTTP(segment)
    if not (AUTOTRACKER_IS_IN_LTTP and AUTOTRACKER_IS_IN_GAME_LTTP) then
        return false
    end
    if AUTOTRACKER_ENABLE_LOCATION_TRACKING then
        updateNPCItemFlagsLTTP(segment, 0x7ef410)
    end
    return true
end

function updateNPCItemFlagsInactiveLTTP(segment)
    if not (AUTOTRACKER_IS_IN_SM and AUTOTRACKER_IS_IN_GAME_SM) then
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
    updateSectionChestCountFromByteAndFlag(segment, "@Sahasrala's Hut/Sahasrala's Reward", address, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Catfish/Ring of Stones", address, 0x20)
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
    if not (AUTOTRACKER_IS_IN_LTTP and AUTOTRACKER_IS_IN_GAME_LTTP) then
        return false
    end
    if AUTOTRACKER_ENABLE_LOCATION_TRACKING then
        updateOverworldEventsLTTP(segment, 0x7ef280)
    end
    return true
end

function updateOverworldEventsInactiveLTTP(segment)
    if not (AUTOTRACKER_IS_IN_SM and AUTOTRACKER_IS_IN_GAME_SM) then
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
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Flute Spot/Flute Spot", address, 42)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Desert Ledge/Desert Ledge", address, 48)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Lake Hylia Island/Lake Hylia Island", address, 53)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Floodgate Chests/Sunken Treasure", address, 59)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Bumper Cave/Ledge", address, 74)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Pyramid Ledge/Ledge", address, 91)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Digging Game/Dig For Treasure", address, 104)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Master Sword Pedestal/Pedestal", address, 128)
    updateSectionChestCountFromOverworldIndexAndFlag(segment, "@Zora Area/Ledge", address, 129)
end

-- ************************* SM functions

function updateItemsActiveSM(segment)
    if not (AUTOTRACKER_IS_IN_SM and AUTOTRACKER_IS_IN_GAME_SM) then
        return false
    end
    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateItemsSM(segment, 0x7e09a2)
    end
    return true
end

function updateItemsInactiveSM(segment)
    if not (AUTOTRACKER_IS_IN_LTTP and AUTOTRACKER_IS_IN_GAME_LTTP) then
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

function updateAmmoActiveSM(segment)
    if not (AUTOTRACKER_IS_IN_SM and AUTOTRACKER_IS_IN_GAME_SM) then
        return false
    end
    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateAmmoSM(segment, 0x7e09c2)
    end
    return true
end

function updateAmmoInactiveSM(segment)
    if not (AUTOTRACKER_IS_IN_LTTP and AUTOTRACKER_IS_IN_GAME_LTTP) then
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
    if not (AUTOTRACKER_IS_IN_SM and AUTOTRACKER_IS_IN_GAME_SM) then
        return false
    end
    if AUTOTRACKER_ENABLE_ITEM_TRACKING then
        updateSMBosses(segment, 0x7ed828)
    end
    return true
end

function updateSMBossesInactive(segment)
    if not (AUTOTRACKER_IS_IN_LTTP and AUTOTRACKER_IS_IN_GAME_LTTP) then
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
    if not (AUTOTRACKER_IS_IN_SM and AUTOTRACKER_IS_IN_GAME_SM) then
        return false
    end
    if AUTOTRACKER_ENABLE_LOCATION_TRACKING then
        updateRoomsSM(segment, 0x7ed870)
    end
    return true
end

function updateRoomsInactiveSM(segment)
    if not (AUTOTRACKER_IS_IN_LTTP and AUTOTRACKER_IS_IN_GAME_LTTP) then
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
    updateSectionChestCountFromByteAndFlag(segment, "@Bomb Torizo/Bomb Torizo", address + 0x0, 0x80)

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
    updateSectionChestCountFromByteAndFlag(segment, "@Morph Ball/Morph Ball", address + 0x3, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Power Bomb (blue Brinstar)/Power Bomb (blue Brinstar)", address + 0x3, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (blue Brinstar middle)/Missile (blue Brinstar middle)", address + 0x3, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Brinstar Ceiling/Energy Tank, Brinstar Ceiling", address + 0x3, 0x20)
    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Etecoons/Energy Tank, Etecoons", address + 0x3, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Super Missile (green Brinstar bottom)/Super Missile (green Brinstar bottom)", address + 0x3, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Waterway/Energy Tank, Waterway", address + 0x4, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (blue Brinstar bottom)/Missile (blue Brinstar bottom)", address + 0x4, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Brinstar Gate/Energy Tank, Brinstar Gate", address + 0x4, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Missiles (blue Brinstar top)/Missile (blue Brinstar top)", address + 0x4, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Missiles (blue Brinstar top)/Missile (blue Brinstar behind missile)", address + 0x4, 0x20)
    updateSectionChestCountFromByteAndFlag(segment, "@X-Ray Scope/X-Ray Scope", address + 0x4, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Power Bomb (red Brinstar sidehopper room)/Power Bomb (red Brinstar sidehopper room)", address + 0x4, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Power Bomb (red Brinstar spike room)/Power Bomb (red Brinstar spike room)", address + 0x5, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (red Brinstar spike room)/Missile (red Brinstar spike room)", address + 0x5, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Spazer/Spazer", address + 0x5, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Kraid/Energy Tank, Kraid", address + 0x5, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Kraid)/Missile (Kraid)", address + 0x5, 0x10)

    updateSectionChestCountFromByteAndFlag(segment, "@Varia Suit/Varia Suit", address + 0x6, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Norfair Missile (lava room)/Norfair Missile (lava room)", address + 0x6, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Ice Beam/Ice Beam", address + 0x6, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Norfair Missile (below ice)/Norfair Missile (below ice)", address + 0x6, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank, Crocomire/Energy Tank, Crocomire", address + 0x6, 0x10)
    updateSectionChestCountFromByteAndFlag(segment, "@Hi-Jump Boots/Hi-Jump Boots", address + 0x6, 0x20)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (above Crocomire)/Missile (above Crocomire)", address + 0x6, 0x40)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Hi-Jump Boots)/Missile (Hi-Jump Boots)", address + 0x6, 0x80)

    updateSectionChestCountFromByteAndFlag(segment, "@Energy Tank (Hi-Jump Boots)/Energy Tank (Hi-Jump Boots)", address + 0x7, 0x01)
    updateSectionChestCountFromByteAndFlag(segment, "@Power Bomb (Crocomire)/Power Bomb (Crocomire)", address + 0x7, 0x02)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (below Crocomire)/Missile (below Crocomire)", address + 0x7, 0x04)
    updateSectionChestCountFromByteAndFlag(segment, "@Missile (Grapple Beam)/Missile (Grapple Beam)", address + 0x7, 0x08)
    updateSectionChestCountFromByteAndFlag(segment, "@Grapple Beam/Grapple Beam", address + 0x7, 0x10)
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
    AUTOTRACKER_IS_IN_GAME_LTTP = false
    AUTOTRACKER_IS_IN_SM = false
    AUTOTRACKER_IS_IN_GAME_SM = false

    resetDungeonCacheTable(FLOOR_KEYS)
    resetDungeonCacheTable(OPENED_DOORS)
    resetDungeonCacheTable(OPENED_CHESTS)
    resetDungeonCacheTable(REMAINING_KEYS)
    resetDungeonCacheTable(DUNGEON_ITEMS)
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
