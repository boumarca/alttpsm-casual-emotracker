------------------------------------ General Logic

function hasItem(code)
    -- Lua functions for access rules are technically supposed to return an integer count.
    -- This is a convenience function to return an int so we don't need to copy/paste this in all access functions.
    if Tracker:ProviderCountForCode(code) >= 1 then
        return 1
    else
        return 0
    end
end

function accessCheck(condition)
    -- Lua functions for access rules are technically supposed to return an integer count.
    -- This is a convenience function to return an int so we don't need to copy/paste this in all access functions.
    if condition then
        return 1
    else
        return 0
    end
end

function isKeysanity()
    return accessCheck(string.find(Tracker.ActiveVariantUID, "keys") ~= nil)
end

function notKeysanity()
    return accessCheck(isKeysanity() ~= 1)
end


----------------------------------- Super Metroid Items

function hasWaveBeam()
    return hasItem("wave")
end

function hasPlasmaBeam()
    return hasItem("plasma")
end

function hasChargeBeam()
    return hasItem("charge")
end

function hasIceBeam()
    return hasItem("ice")
end

function hasHiJump()
    return hasItem("hijump")
end

function hasSpaceJump()
    return hasItem("space")
end

function hasVaria()
    return hasItem("varia")
end

function hasGravity()
    return hasItem("gravity")
end

function hasGrapple()
    return hasItem("grapple")
end

function hasBombs()
    return hasItem("bomb")
end

function hasPowerBombs()
    return hasItem("powerbomb")
end

function hasMorph()
    return hasItem("morph")
end

function hasMissiles()
    return hasItem("missile")
end

function hasSupers()
    return hasItem("super")
end

function countEnergyReserves()
	local etanks = Tracker:ProviderCountForCode("etank")
	local reservetanks = Tracker:ProviderCountForCode("reservetank")
	return etanks + reservetanks
end

function hasScrewAttack()
    return hasItem("screw")
end

function hasSpringBall()
    return hasItem("spring")
end

function hasSpeedBooster()
    return hasItem("speed")
end

function hasKraidKey()
    return hasItem("kraid_key")
end

function defeatedKraid()
    return hasItem("kraid")
end

function hasPhantoonKey()
    return hasItem("phantoon_key")
end

function defeatedPhantoon()
    return hasItem("phantoon")
end

function hasDraygonKey()
    return hasItem("draygon_key")
end

function hasRidleyKey()
    return hasItem("ridley_key")
end


----------------------------------- Link to the Past Items

function hasFlute()
    return hasItem("flute")
end

function hasBottle()
    return hasItem("bottle")
end

function hasHalfMagic()
    return hasItem("halfmagic")
end

function hasLamp()
    return hasItem("lamp")
end

function hasPowerGlove()
    return hasItem("gloves")
end

function hasTitansMitt()
    return hasItem("mitts")
end

function hasMoonPearl()
    return hasItem("pearl")
end

function hasFlippers()
    return hasItem("flippers")
end

function hasHookshot()
    return hasItem("hookshot")
end

function hasHammer()
    return hasItem("hammer")
end

function hasBow()
    return hasItem("bow")
end

function hasFireRod()
    return hasItem("firerod")
end

function hasIceRod()
    return hasItem("icerod")
end

function hasSomaria()
    return hasItem("somaria")
end

function hasByrna()
    return hasItem("byrna")
end

function hasCape()
    return hasItem("cape")
end

function hasBombos()
    return hasItem("bombos")
end

function hasSword()
    return hasItem("sword")
end

function hasMasterSword()
    return hasItem("sword2")
end

function defeatedAga()
    return hasItem("aga1")
end

function hasGTCrystals()
    local reqCount = 7
    local count = Tracker:ProviderCountForCode("crystal") + Tracker:ProviderCountForCode("crystal56")
    return accessCheck(count >= reqCount)
end


----------------------------------- Can Do The Things

-- These are used in access rules, so they have to return an integer!

-- LTTP things

function canLightTorches()
    return accessCheck(hasLamp() == 1 or hasFireRod() == 1)
end

function canMeltFreezors()
    return accessCheck(hasFireRod() == 1 or (hasBombos() == 1 and hasSword() == 1))
end

function countMagicBars()
    -- Half magic gives 2x multiplier, bottle gives another 2x multiplier.
    local maxBars = 1
    if hasHalfMagic() then
        maxBars = maxBars * 2
    end
    if hasBottle() then
        maxBars = maxBars * 2
    end
    return maxBars
end

function canExtendMagic(bars)
    return countMagicBars() >= bars
end

function canKillManyEnemies()
    return accessCheck(hasSword() == 1 or hasHammer() == 1 or hasBow() == 1 or hasFireRod() == 1 or hasSomaria() == 1 or
            (hasByrna() == 1 and canExtendMagic(2)))
end

-- SM things

function canIbj()
    return accessCheck(hasMorph() == 1 and hasBombs() == 1)
end

function canFly()
    return accessCheck(hasSpaceJump() == 1 or canIbj() == 1)
end

function canUsePowerBombs()
    return accessCheck(hasMorph() == 1 and hasPowerBombs() == 1)
end

function canPassBombPassages()
    return accessCheck(hasMorph() == 1 and (hasBombs() == 1 or hasPowerBombs() == 1))
end

function canDestroyBombWalls()
    return accessCheck(canPassBombPassages() == 1 or hasScrewAttack() == 1)
end

function canSpringBallJump()
    return accessCheck(hasMorph() == 1 and hasSpringBall() == 1)
end

function canHellRun()
    return accessCheck(hasVaria() == 1 or countEnergyReserves() >= 5)
end

function canOpenRedDoors()
    return accessCheck(hasMissiles() == 1 or hasSupers() == 1)
end
