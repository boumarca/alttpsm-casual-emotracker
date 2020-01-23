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

-- ************************** Memory reading helper functions

function InvalidateReadCaches()
    U8_READ_CACHE_ADDRESS = 0
    U16_READ_CACHE_ADDRESS = 0
end

function ReadU8(segment, address)
    if U8_READ_CACHE_ADDRESS ~= address then
        U8_READ_CACHE = segment:ReadUInt8(address)
        U8_READ_CACHE_ADDRESS = address
    end

    return U8_READ_CACHE
end

function ReadU16(segment, address)
    if U16_READ_CACHE_ADDRESS ~= address then
        U16_READ_CACHE = segment:ReadUInt16(address)
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
