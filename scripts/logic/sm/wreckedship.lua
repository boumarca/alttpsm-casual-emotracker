----------------------------------- Wrecked Ship Access Logic

function canEnterWreckedShipNormal()
    return accessCheck(hasSupers() == 1 and (
            (canAccessMaridiaPortal() == 1 and hasGravity() == 1 and canPassBombPassages() == 1) or
                    (canUsePowerBombs() == 1 and (
                            hasSpeedBooster() == 1 or
                                    hasGrapple() == 1 or
                                    hasSpaceJump() == 1 or
                                    (hasGravity() == 1 and (canFly() == 1 or hasHiJump() == 1))
                    ))
    ))
end

function canEnterWreckedShipHard()
    return accessCheck(hasSupers() == 1 and (canUsePowerBombs() == 1 or
            (canAccessMaridiaPortal() == 1 and (hasGravity() == 1 or hasHiJump() == 1) and canPassBombPassages() == 1)))
end

function energyTankWreckedShipNormal()
    return accessCheck(defeatedPhantoon() == 1 and
            (hasHiJump() == 1 or hasSpaceJump() == 1 or hasSpeedBooster() == 1 or hasGravity() == 1))
end

function energyTankWreckedShipHard()
    return accessCheck(defeatedPhantoon() == 1 and
            (hasHiJump() == 1 or hasSpaceJump() == 1 or hasSpeedBooster() == 1 or hasGravity() == 1 or
                    hasBombs() == 1 or hasPowerBombs() == 1 or canSpringBallJump() == 1))
end

function reserveTankWreckedShipNormal()
    return accessCheck(defeatedPhantoon() == 1 and hasSpeedBooster() == 1 and canUsePowerBombs() == 1 and
            (hasGrapple() == 1 or hasSpaceJump() == 1 or countEnergyReserves() >= 3 or
                    (hasVaria() == 1 and countEnergyReserves() >= 2)))
end

function reserveTankWreckedShipHard()
    return accessCheck(defeatedPhantoon() == 1 and hasSpeedBooster() == 1 and canUsePowerBombs() == 1 and
            (hasVaria() == 1 or countEnergyReserves() >= 2))
end

function gravitySuitNormal()
    return accessCheck(defeatedPhantoon() == 1 and
            (hasGrapple() == 1 or hasSpaceJump() == 1 or countEnergyReserves() >= 3 or
                    (hasVaria() == 1 and countEnergyReserves() >= 2)))
end

function gravitySuitHard()
    return accessCheck(defeatedPhantoon() == 1 and (hasVaria() == 1 or countEnergyReserves() >= 1))
end
