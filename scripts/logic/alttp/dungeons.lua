----------------------------------- Dungeon Access Logic

-- Castle Tower

function canEnterCastleTower()
    return accessCheck(canKillManyEnemies() == 1 and (hasCape() == 1 or hasMasterSword() == 1))
end

function canCompleteCastleTower()
    return accessCheck(canEnterCastleTower() == 1 and hasLamp() == 1 and countSmallKeys("at") >= 2 and hasSword() == 1)
end
