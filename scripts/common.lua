-- Common logic functions.

-- GT Access
function gtCrystalCount()
    local reqCount = Tracker:ProviderCountForCode("gt_crystals")
    local count = Tracker:ProviderCountForCode("allcrystals")

    if count >= reqCount then
        return 1
    else
        return 0
    end
end
