------------------------------------ General Logic

function hasItem(code)
    -- Lua functions for access rules are technically supposed to return an integer count.
    -- This is a convenience function to return an int for a given item code if we have it.
    if Tracker:ProviderCountForCode(code) >= 1 then
        return 1
    else
        return 0
    end
end

function accessCheck(condition)
    -- Lua functions for access rules are technically supposed to return an integer count.
    -- This is a convenience function to return an int for a given access check condition.
    if condition then
        return 1
    else
        return 0
    end
end

function isNormal()
    return hasItem("normal")
end

function isHard()
    return hasItem("hard")
end

function gtCrystalCount()
    local reqCount = 7
    local count = Tracker:ProviderCountForCode("crystal") + Tracker:ProviderCountForCode("crystal56")
    if count >= reqCount then
        return 1
    else
        return 0
    end
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

function countPB()
	return Tracker:ProviderCountForCode("powerbomb")
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

function defeatedKraid()
    return hasItem("kraid")
end

function defeatedPhantoon()
    return hasItem("phantoon")
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
	return hasItem("moonpearl")
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

function countSmallKeys(code)
	-- Count small keys for checking access to places.  For now, this is hardcoded to the total number of small keys in
	-- chests in the dungeon.  In the future for keysanity, this will count current small keys on the tracker.
	if code == 'at' then
		return 2
	else
		return 0
	end
end


----------------------------------- Can Do The Things

-- LTTP things

function canLiftLight()
	return accessCheck(hasPowerGlove() == 1 or hasTitansMitt() == 1)
end

function canLiftHeavy()
	return accessCheck(hasTitansMitt() == 1)
end

function canLightTorches()
	return accessCheck(hasLamp() == 1 or hasFireRod() == 1)
end

function canMeltFreezors()
	return accessCheck(hasFireRod() == 1 or (hasBombos() == 1 and hasSword() == 1))
end

function canExtendMagic(bars)
	-- Half magic gives 2x multiplier, bottle gives another 2x multiplier.
	return accessCheck((hasHalfMagic() + 1) * (hasBottle() + 1) >= bars)
end

function canKillManyEnemies()
	return accessCheck(hasSword() == 1 or hasHammer() == 1 or hasBow() == 1 or hasFireRod() == 1 or
			hasSomaria() == 1 or (hasByrna() == 1 and canExtendMagic(2)))
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
	return accessCheck(hasMorph() and (hasBombs() == 1 or hasPowerBombs() == 1))
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


----------------------------------- Portal Access Logic

function canAccessDeathMountainPortal()
	return accessCheck((canDestroyBombWalls() == 1 or hasSpeedBooster() == 1) and
			hasSupers() == 1 and hasMorph() == 1)
end

function canAccessDarkWorldPortal()
	if isNormal() == 1 then
		return accessCheck(canUsePowerBombs() == 1 and hasSupers() == 1 and hasGravity() == 1 and
				hasSpeedBooster() == 1)
	else
		return accessCheck(canUsePowerBombs() == 1 and hasSupers() == 1 and
				(hasChargeBeam() == 1 or (hasSupers() == 1 and hasMissiles() == 1)) and
				(hasGravity() == 1 or (hasHiJump() == 1 and hasIceBeam() == 1 and hasGrapple() == 1)) and
				(hasIceBeam() == 1 or (hasGravity() == 1 and hasSpeedBooster() == 1)))
	end
end

function canAccessMiseryMirePortal()
	if isNormal() == 1 then
		return accessCheck(hasVaria() == 1 and hasSupers() == 1 and canUsePowerBombs() == 1 and
				hasGravity() == 1 and hasSpaceJump() == 1)
	else
		return accessCheck(hasVaria() == 1 and hasSupers() == 1 and canUsePowerBombs() == 1 and
				(hasGravity() == 1 or hasHiJump() == 1))
	end
end

function canAccessNorfairUpperPortal()
	return accessCheck(hasFlute() == 1 or (canLiftLight() == 1 and hasLamp() == 1))
end

function canAccessNorfairLowerPortal()
	return accessCheck(hasFlute() == 1 and canLiftHeavy() == 1)
end

function canAccessMaridiaPortal()
	if isNormal() == 1 then
		return accessCheck(hasMoonPearl() == 1 and hasFlippers() == 1 and hasGravity() == 1 and hasMorph() == 1 and
				(defeatedAga() == 1 or (hasHammer() == 1 and canLiftLight() == 1) or canLiftHeavy() == 1))
	else
		return accessCheck(hasMoonPearl() == 1 and hasFlippers() == 1 and hasMorph() == 1 and
				(canSpringBallJump() == 1 or hasHiJump() == 1 or hasGravity() == 1) and
				(defeatedAga() == 1 or (hasHammer() == 1 and canLiftLight() == 1) or canLiftHeavy() == 1))
	end
end
