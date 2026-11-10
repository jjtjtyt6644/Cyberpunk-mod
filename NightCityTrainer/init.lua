-- Night City Trainer
-- A single-player trainer menu for Cyberpunk 2077, built on Cyber Engine Tweaks (CET).
-- Open the CET overlay in game to show the menu.

local NCT = {
    version = "4.0.0",
    overlayOpen = false,
    page = "Home",
    tick = 0,
    infoTick = 0,
    slowTick = 0,
    toast = { text = "Ready. Load a save, then pick a cheat.", ok = true, time = -100 },
    info = nil,           -- live character stats, refreshed twice a second
    pendingRestore = nil, -- cheats to switch back on once a save is loaded

    -- sliders / inputs (saved between sessions)
    speedMult = 1.0,
    jumpMult = 1.0,
    carryBonus = 0,
    cwCapacity = 0,
    gameSpeed = 1.0,
    hour = 12,
    moneyAmount = 100000,
    level = 60,
    streetCred = 50,
    attrPoints = 5,
    perkPoints = 10,
    relicPoints = 3,
    attrValue = 20,
    itemId = "Items.money",
    itemQty = 1,
    matQty = 500,
    blinkDistance = 10,
    flySpeed = 15,
    xpMult = 1,
    rememberCheats = true,
    showPopups = true,

    achConfirm = false,
    mods = {},   -- active stat modifiers, by key
    spots = {},  -- saved teleport positions
    keys = { fwd = false, back = false, up = false, down = false },
    flyPos = nil,
}

local SAVED_FIELDS = {
    "page", "speedMult", "jumpMult", "carryBonus", "cwCapacity", "gameSpeed", "hour", "moneyAmount",
    "level", "streetCred", "attrPoints", "perkPoints", "relicPoints", "attrValue", "itemId",
    "itemQty", "matQty", "blinkDistance", "flySpeed", "xpMult", "rememberCheats", "showPopups",
}

local REASON = "NightCityTrainer"
local INFINITE_AMMO_EFFECT = "GameplayRestriction.InfiniteAmmo"
local MAX_SPOTS = 8

---------------------------------------------------------------------------
-- Helpers
---------------------------------------------------------------------------

local function getPlayer()
    local ok, player = pcall(function() return Game.GetPlayer() end)
    if ok then return player end
    return nil
end

local function toast(text, ok)
    NCT.toast.text = text
    NCT.toast.ok = ok
    NCT.toast.time = os.clock()
end

-- Runs a cheat safely and reports the result in the status bar.
-- The cheat may return its own status text.
local function run(label, fn)
    if not getPlayer() then
        toast("Load a save first.", false)
        return false
    end
    local ok, result = pcall(fn)
    if ok then
        toast(type(result) == "string" and result or label, true)
    else
        local msg = tostring(result):gsub("^.-:%d+: ", "")
        toast(label .. " failed: " .. msg, false)
        print("[NightCityTrainer] " .. label .. " failed: " .. tostring(result))
    end
    return ok
end

local function formatNumber(n)
    local s = tostring(math.floor(n))
    local out = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    if out:sub(1, 1) == "," then out = out:sub(2) end
    return out
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

local function itemID(name)
    return ItemID.FromTDBID(TweakDBID.new(name))
end

local function itemCount(name)
    return Game.GetTransactionSystem():GetItemQuantity(getPlayer(), itemID(name))
end

local function giveItem(name, qty)
    Game.GetTransactionSystem():GiveItem(getPlayer(), itemID(name), qty)
end

-- Gives an item and confirms it really arrived in the inventory.
local function giveItemChecked(name, qty)
    local before = itemCount(name)
    giveItem(name, qty)
    if itemCount(name) <= before then
        error("'" .. name .. "' is not a valid item ID on this game version")
    end
end

local function fillPool(poolType)
    Game.GetStatPoolsSystem():RequestSettingStatPoolMaxValue(getPlayer():GetEntityID(), poolType, nil)
end

local function statValue(statType)
    return Game.GetStatsSystem():GetStatValue(getPlayer():GetEntityID(), statType)
end

-- Adds, replaces or removes (value = nil) a stat modifier on the player.
local function setStatMod(key, statType, modType, value)
    local stats = Game.GetStatsSystem()
    local id = getPlayer():GetEntityID()
    if NCT.mods[key] then
        stats:RemoveModifier(id, NCT.mods[key])
        NCT.mods[key] = nil
    end
    if value then
        local mod = RPGManager.CreateStatModifier(statType, modType, value)
        stats:AddModifier(id, mod)
        NCT.mods[key] = mod
    end
end

local function setGodMode(enabled)
    local gm = Game.GetGodModeSystem()
    local id = getPlayer():GetEntityID()
    local reason = CName.new(REASON)
    if enabled then
        gm:AddGodMode(id, gameGodModeType.Invulnerable, reason)
    else
        gm:RemoveGodMode(id, gameGodModeType.Invulnerable, reason)
    end
end

local function setGameSpeed(speed)
    local ts = Game.GetTimeSystem()
    local reason = CName.new(REASON)
    ts:UnsetTimeDilation(reason)
    if math.abs(speed - 1.0) > 0.01 then
        ts:SetTimeDilation(reason, speed)
    end
end

local function preventionSystem()
    local system = Game.GetScriptableSystemsContainer():Get(CName.new("PreventionSystem"))
    if not system then error("police system not found") end
    return system
end

-- Switches the police / wanted system on or off through the game's request queue.
local function setPolice(active)
    local request = TogglePreventionSystem.new()
    request.sourceName = CName.new(REASON)
    request.isActive = active
    preventionSystem():QueueRequest(request)
end

local function clearWanted()
    preventionSystem():ChangeHeatStage(EPreventionHeatStage.Heat_0, REASON)
end

---------------------------------------------------------------------------
-- Ammo
---------------------------------------------------------------------------

local AMMO = { "Ammo.HandgunAmmo", "Ammo.RifleAmmo", "Ammo.ShotgunAmmo", "Ammo.SniperRifleAmmo" }

local function topUpAmmo()
    for _, name in ipairs(AMMO) do
        if itemCount(name) < 400 then giveItem(name, 500) end
    end
end

local function hasInfiniteAmmoEffect()
    local player = getPlayer()
    local id = TweakDBID.new(INFINITE_AMMO_EFFECT)
    local ok, has = pcall(function()
        return Game.GetStatusEffectSystem():HasStatusEffect(player:GetEntityID(), id)
    end)
    return ok and has == true
end

-- The game has a built-in "weapons use no ammo" effect; this switches it on or
-- off. Returns true when the effect is confirmed active.
local function setInfiniteAmmoEffect(enabled)
    local player = getPlayer()
    local id = TweakDBID.new(INFINITE_AMMO_EFFECT)
    if enabled then
        if hasInfiniteAmmoEffect() then return true end
        local ok = pcall(function()
            Game.GetStatusEffectSystem():ApplyStatusEffect(player:GetEntityID(), id,
                player:GetRecordID(), player:GetEntityID())
        end)
        if not ok or not hasInfiniteAmmoEffect() then
            pcall(function() StatusEffectHelper.ApplyStatusEffect(player, id) end)
        end
        return hasInfiniteAmmoEffect()
    end
    pcall(function() Game.GetStatusEffectSystem():RemoveStatusEffect(player:GetEntityID(), id) end)
    if hasInfiniteAmmoEffect() then
        pcall(function() StatusEffectHelper.RemoveStatusEffect(player, id) end)
    end
    return false
end

---------------------------------------------------------------------------
-- Character development (levels, points, attributes)
-- These talk to the game's PlayerDevelopmentSystem directly; the old
-- Game.GiveDevPoints / Game.SetLevel console commands no longer exist.
---------------------------------------------------------------------------

local function devData()
    local data = PlayerDevelopmentSystem.GetData(getPlayer())
    if not data then error("character data not available") end
    return data
end

local function devSystem()
    return Game.GetScriptableSystemsContainer():Get(CName.new("PlayerDevelopmentSystem"))
end

-- Picks whichever "why did the level change" value this game version has.
local function gainReason()
    for _, name in ipairs({ "Ignore", "IsDebug", "Gameplay" }) do
        local ok, value = pcall(function() return telemetryLevelGainReason[name] end)
        if ok and value ~= nil then return value end
    end
    error("no level change reason available")
end

local function getDevPoints(pointType)
    return devData():GetDevPoints(gamedataDevelopmentPointType[pointType])
end

local function addDevPoints(pointType, amount, name)
    local before = getDevPoints(pointType)
    pcall(function()
        devData():AddDevelopmentPoints(amount, gamedataDevelopmentPointType[pointType])
    end)
    local after = getDevPoints(pointType)
    if after > before then
        return "Gave " .. amount .. " " .. name .. " points (now " .. after .. ")"
    end

    -- Direct call had no effect: go through the game's request queue instead.
    local request = AddDevelopmentPoints.new()
    request.owner = getPlayer()
    request.amountOfPoints = amount
    request.developmentPointType = gamedataDevelopmentPointType[pointType]
    devSystem():QueueRequest(request)
    return "Requested " .. amount .. " " .. name .. " points - check the character menu"
end

local function getProficiency(profType)
    return devData():GetProficiencyLevel(gamedataProficiencyType[profType])
end

local function setProficiency(profType, level)
    local prof = gamedataProficiencyType[profType]
    local reason = gainReason()
    local ok = pcall(function() devData():SetLevel(prof, level, reason, false) end)
    if ok and getProficiency(profType) == level then return true end

    local request = SetProficiencyLevel.new()
    request.owner = getPlayer()
    request.proficiencyType = prof
    request.newLevel = level
    request.telemetryLevelGainReason = reason
    devSystem():QueueRequest(request)
    return false
end

local function setAttribute(statName, value)
    local stat = gamedataStatType[statName]
    pcall(function() devData():SetAttribute(stat, value) end)
    if math.floor(statValue(stat) + 0.5) == value then return true end

    local request = SetAttribute.new()
    request.owner = getPlayer()
    request.attributeType = stat
    request.statLevel = value
    devSystem():QueueRequest(request)
    return false
end

local function refreshInfo()
    if not getPlayer() then
        NCT.info = nil
        return
    end
    local info = {}
    pcall(function() info.money = itemCount("Items.money") end)
    pcall(function() info.level = getProficiency("Level") end)
    pcall(function() info.cred = getProficiency("StreetCred") end)
    pcall(function() info.attr = getDevPoints("Attribute") end)
    pcall(function() info.perk = getDevPoints("Primary") end)
    pcall(function() info.relic = getDevPoints("Espionage") end)
    NCT.info = info
end

---------------------------------------------------------------------------
-- Teleport and fly
---------------------------------------------------------------------------

local function playerRotation(player)
    local q = player:GetWorldOrientation()
    local ok, angles = pcall(function() return q:ToEulerAngles() end)
    if ok and angles then return angles end
    ok, angles = pcall(function() return GetSingleton("Quaternion"):ToEulerAngles(q) end)
    if ok and angles then return angles end
    return EulerAngles.new(0, 0, 0)
end

-- The vehicle the player is sitting in, or nil when on foot.
local function mountedVehicle()
    local player = getPlayer()
    local ok, vehicle = pcall(function() return Game["GetMountedVehicle;GameObject"](player) end)
    if ok and vehicle then return vehicle end
    ok, vehicle = pcall(function() return Game.GetMountedVehicle(player) end)
    if ok and vehicle then return vehicle end
    return nil
end

local function requireVehicle()
    local vehicle = mountedVehicle()
    if not vehicle then error("get in a vehicle first") end
    return vehicle
end

-- Teleports the player, or the vehicle they are driving, keeping its facing.
local function teleportTo(x, y, z)
    local target = mountedVehicle() or getPlayer()
    Game.GetTeleportationFacility():Teleport(target, Vector4.new(x, y, z, 1), playerRotation(target))
end

local function blink(distance)
    local target = mountedVehicle() or getPlayer()
    local pos = target:GetWorldPosition()
    local dir = target:GetWorldForward()
    teleportTo(pos.x + dir.x * distance, pos.y + dir.y * distance, pos.z + 0.5)
end

---------------------------------------------------------------------------
-- Vehicles
---------------------------------------------------------------------------

local function repairVehicle(vehicle)
    local repaired = false
    if pcall(function() vehicle:GetVehicleComponent():RepairVehicle() end) then repaired = true end
    if pcall(function()
        vehicle:DestructionResetGrid()
        vehicle:DestructionResetGlass()
    end) then repaired = true end
    pcall(function()
        Game.GetStatPoolsSystem():RequestSettingStatPoolMaxValue(vehicle:GetEntityID(),
            gamedataStatPoolType.Health, nil)
    end)
    if not repaired then error("this vehicle could not be repaired") end
end

local function setVehicleGodMode(vehicle, enabled)
    local gm = Game.GetGodModeSystem()
    local reason = CName.new(REASON)
    if enabled then
        gm:AddGodMode(vehicle:GetEntityID(), gameGodModeType.Invulnerable, reason)
    else
        gm:RemoveGodMode(vehicle:GetEntityID(), gameGodModeType.Invulnerable, reason)
    end
end

-- Keeps whatever vehicle the player is driving undamaged.
local function protectVehicle()
    local vehicle = mountedVehicle()
    if not vehicle then return end
    pcall(setVehicleGodMode, vehicle, true)
    pcall(repairVehicle, vehicle)
end

local function flipVehicle()
    local vehicle = requireVehicle()
    local pos = vehicle:GetWorldPosition()
    local angles = playerRotation(vehicle)
    Game.GetTeleportationFacility():Teleport(vehicle,
        Vector4.new(pos.x, pos.y, pos.z + 1.0, 1), EulerAngles.new(0, 0, angles.yaw))
end

local function setVehicleDoors(open)
    local vehicle = requireVehicle()
    local ok = pcall(function()
        local ps = vehicle:GetVehiclePS()
        if open then ps:OpenAllVehDoors(true) else ps:CloseAllVehDoors(true) end
    end)
    if not ok then error("doors can't be controlled on this vehicle") end
end

---------------------------------------------------------------------------
-- Enemies
---------------------------------------------------------------------------

-- Kills hostile NPCs within `range` metres. Returns how many were killed.
local function killHostiles(range)
    local player = getPlayer()
    local npcs = player:GetNPCsAroundObject(range)
    local killed = 0
    for _, npc in ipairs(npcs) do
        local hostile = false
        pcall(function()
            hostile = GameObject.GetAttitudeTowards(npc, player) == EAIAttitude.AIA_Hostile
        end)
        if hostile then
            local dead = false
            pcall(function() dead = npc:IsDead() end)
            if not dead and pcall(function() npc:Kill(player, false, false) end) then
                killed = killed + 1
            end
        end
    end
    return killed
end

-- Fly mode: holds the player in the air and moves them along the camera
-- direction while the bound fly keys are held.
local function updateFly(delta)
    local player = getPlayer()
    if not player then return end
    if not NCT.flyPos then
        local pos = player:GetWorldPosition()
        NCT.flyPos = { x = pos.x, y = pos.y, z = pos.z + 0.5 }
    end
    local p, k = NCT.flyPos, NCT.keys
    local step = NCT.flySpeed * delta
    if k.fwd or k.back then
        local dir = Game.GetCameraSystem():GetActiveCameraForward()
        local sign = k.fwd and 1 or -1
        p.x = p.x + dir.x * step * sign
        p.y = p.y + dir.y * step * sign
        p.z = p.z + dir.z * step * sign
    end
    if k.up then p.z = p.z + step end
    if k.down then p.z = p.z - step end
    teleportTo(p.x, p.y, p.z)
end

---------------------------------------------------------------------------
-- Cheat registry
-- Every on/off cheat lives here so the menu, hotkeys, the "everything off"
-- button and the remembered-cheats restore all share one code path.
--   apply    : called when switched on or off (optional)
--   remember : switched back on automatically next session
---------------------------------------------------------------------------

local function statCheat(key, statType, modType, value)
    return function(on)
        setStatMod(key, gamedataStatType[statType], gameStatModifierType[modType], on and value or nil)
    end
end

-- Same, for cheats made of several stat changes: { { stat, modType, value }, ... }
local function multiStatCheat(key, stats)
    return function(on)
        for i, entry in ipairs(stats) do
            setStatMod(key .. i, gamedataStatType[entry[1]], gameStatModifierType[entry[2]],
                on and entry[3] or nil)
        end
    end
end

local CHEATS = {
    godMode = {
        label = "God Mode", remember = true, apply = setGodMode,
        desc = "You take no damage from anything.",
    },
    infStamina = {
        label = "Infinite Stamina", remember = true,
        desc = "Sprint, dodge and swing melee weapons without ever tiring.",
    },
    infOxygen = {
        label = "Infinite Oxygen", remember = true,
        desc = "Stay underwater as long as you like.",
    },
    infRam = {
        label = "Infinite RAM", remember = true,
        desc = "RAM refills instantly, so quickhacks are always available.",
    },
    regen = {
        label = "Rapid Health Regen",
        desc = "Health regenerates quickly, even in combat.",
        apply = multiStatCheat("regen", {
            { "HealthInCombatRegenEnabled", "Additive", 1 },
            { "HealthGeneralRegenRateMult", "Additive", 10 },
        }),
    },
    immune = {
        label = "Status Immunity",
        desc = "Immune to burning, poison, bleeding, shock and knockdown.",
        apply = multiStatCheat("immune", {
            { "BurningImmunity", "Additive", 1 },
            { "PoisonImmunity", "Additive", 1 },
            { "BleedingImmunity", "Additive", 1 },
            { "ElectrocuteImmunity", "Additive", 1 },
            { "KnockdownImmunity", "Additive", 1 },
        }),
    },
    doubleJump = {
        label = "Double Jump",
        desc = "Jump again in mid-air, without needing the leg cyberware.",
        apply = statCheat("doubleJump", "HasDoubleJump", "Additive", 1),
    },
    airDash = {
        label = "Air Dash",
        desc = "Dodge while in the air.",
        apply = statCheat("airDash", "HasDodgeAir", "Additive", 1),
    },
    silent = {
        label = "Silent Movement",
        desc = "Running and landing make no noise for enemies to hear.",
        apply = multiStatCheat("silent", {
            { "CanRunSilently", "Additive", 1 },
            { "CanLandSilently", "Additive", 1 },
        }),
    },
    headshots = {
        label = "Lethal Headshots",
        desc = "Headshots deal massively increased damage.",
        apply = statCheat("headshots", "HeadshotDamageMultiplier", "Additive", 10),
    },
    freezeClock = {
        label = "Freeze Time Of Day",
        desc = "The in-game clock stops, so it stays day or night.",
        apply = function(on) Game.GetTimeSystem():SetPausedState(on, CName.new(REASON)) end,
    },
    infAmmo = {
        label = "Infinite Ammo", remember = true,
        desc = "Weapons stop using ammo and your reserve is kept topped up.",
        apply = function(on)
            local active = setInfiniteAmmoEffect(on)
            if on then
                topUpAmmo()
                if active then return "Infinite Ammo ON - weapons no longer use ammo" end
                return "Infinite Ammo ON - reserve auto-refills (you still reload)"
            end
        end,
    },
    noPolice = {
        label = "Disable Police", remember = true, apply = function(on) setPolice(not on) end,
        desc = "Crimes no longer raise a wanted level.",
    },
    noFall = {
        label = "No Fall Damage", apply = statCheat("noFall", "FallDamageReduction", "Additive", 100),
        desc = "Drop from any height without getting hurt.",
    },
    alwaysCrit = {
        label = "Always Crit", apply = statCheat("alwaysCrit", "CritChance", "Additive", 100),
        desc = "Every hit is a critical hit.",
    },
    megaCrit = {
        label = "Mega Crit Damage", apply = statCheat("megaCrit", "CritDamage", "Additive", 1000),
        desc = "Critical hits deal +1000% damage.",
    },
    tankArmor = {
        label = "Tank Armor", apply = statCheat("tankArmor", "Armor", "Additive", 10000),
        desc = "Adds 10,000 armor.",
    },
    invisible = {
        label = "Invisible", apply = function(on) getPlayer():SetInvisible(on) end,
        desc = "Enemies cannot see you.",
    },
    slowMo = {
        label = "Slow Motion", apply = function(on) setGameSpeed(on and 0.25 or 1.0) end,
        desc = "The world runs at quarter speed.",
    },
    carGod = {
        label = "Indestructible Vehicle", remember = true,
        desc = "The vehicle you drive takes no damage and repairs itself.",
        apply = function(on)
            if on then
                protectVehicle()
            else
                local vehicle = mountedVehicle()
                if vehicle then setVehicleGodMode(vehicle, false) end
            end
        end,
    },
    fly = {
        label = "Fly Mode",
        desc = "Hover and fly through anything. Needs the Fly keys bound in CET.",
        apply = function(on)
            NCT.flyPos = nil
            if on then return "Fly Mode ON - hold your bound fly keys to move" end
        end,
    },
}

for key in pairs(CHEATS) do NCT[key] = false end

local function setCheat(key, on)
    local cheat = CHEATS[key]
    local ok = run(cheat.label .. (on and " ON" or " OFF"), function()
        if cheat.apply then return cheat.apply(on) end
    end)
    if ok then NCT[key] = on end
    return ok
end

local function activeCheatCount()
    local n = 0
    for key in pairs(CHEATS) do
        if NCT[key] then n = n + 1 end
    end
    return n
end

local function resetMovement()
    NCT.speedMult, NCT.jumpMult, NCT.carryBonus = 1.0, 1.0, 0
    setStatMod("speed")
    setStatMod("jump")
    setStatMod("carry")
end

local function everythingOff()
    if not getPlayer() then
        toast("Load a save first.", false)
        return
    end
    for key, cheat in pairs(CHEATS) do
        if NCT[key] then
            if cheat.apply then pcall(cheat.apply, false) end
            NCT[key] = false
        end
    end
    pcall(resetMovement)
    pcall(function()
        NCT.cwCapacity = 0
        setStatMod("cwCapacity")
    end)
    pcall(function()
        NCT.gameSpeed = 1.0
        setGameSpeed(1.0)
    end)
    pcall(function()
        NCT.xpMult = 1
        setStatMod("xpMult")
    end)
    toast("Every cheat switched off", true)
end

-- One-click groups of cheats.
local LOADOUTS = {
    { "GOD", "Unkillable, with endless stamina, RAM and ammo.",
        { "godMode", "infStamina", "infRam", "infAmmo", "noFall", "immune" } },
    { "GHOST", "Unseen and unheard, with the police switched off.",
        { "invisible", "silent", "noPolice" } },
    { "PARKOUR", "Double jump, air dash, endless stamina, no fall damage.",
        { "doubleJump", "airDash", "noFall", "infStamina" } },
}

local function applyLoadout(loadout)
    local switched = 0
    for _, key in ipairs(loadout[3]) do
        local cheat = CHEATS[key]
        if not NCT[key] then
            local ok = true
            if cheat.apply then ok = pcall(cheat.apply, true) end
            if ok then
                NCT[key] = true
                switched = switched + 1
            end
        end
    end
    return loadout[1] .. " loadout on (" .. switched .. " cheats switched on)"
end

---------------------------------------------------------------------------
-- Settings file (kept next to this script)
---------------------------------------------------------------------------

local function saveSettings()
    local data = { spots = NCT.spots, active = {} }
    for _, field in ipairs(SAVED_FIELDS) do data[field] = NCT[field] end
    for key, cheat in pairs(CHEATS) do
        if cheat.remember and NCT[key] then data.active[#data.active + 1] = key end
    end
    pcall(function()
        local file = io.open("settings.json", "w")
        if file then
            file:write(json.encode(data))
            file:close()
        end
    end)
end

local function loadSettings()
    local ok, data = pcall(function()
        local file = io.open("settings.json", "r")
        if not file then return nil end
        local text = file:read("*a")
        file:close()
        return json.decode(text)
    end)
    if not ok or type(data) ~= "table" then return end

    for _, field in ipairs(SAVED_FIELDS) do
        if data[field] ~= nil and type(data[field]) == type(NCT[field]) then
            NCT[field] = data[field]
        end
    end
    if type(data.spots) == "table" then
        NCT.spots = {}
        for _, spot in ipairs(data.spots) do
            if type(spot) == "table" and spot.x and spot.y and spot.z then
                NCT.spots[#NCT.spots + 1] = { name = tostring(spot.name or "Spot"), x = spot.x, y = spot.y, z = spot.z }
            end
        end
    end
    if NCT.rememberCheats and type(data.active) == "table" and #data.active > 0 then
        NCT.pendingRestore = data.active
    end
end

-- Switches remembered cheats back on once a save is loaded.
local function restoreCheats()
    local restored = 0
    for _, key in ipairs(NCT.pendingRestore) do
        local cheat = CHEATS[key]
        if cheat and cheat.remember and not NCT[key] then
            local ok = true
            if cheat.apply then ok = pcall(cheat.apply, true) end
            if ok then
                NCT[key] = true
                restored = restored + 1
            end
        end
    end
    NCT.pendingRestore = nil
    if restored > 0 then
        toast("Restored " .. restored .. " cheat" .. (restored == 1 and "" or "s") .. " from last session", true)
    end
end

---------------------------------------------------------------------------
-- Theme
---------------------------------------------------------------------------

local C = {
    bg      = { 0.035, 0.040, 0.065, 0.98 },
    side    = { 0.020, 0.024, 0.040, 1.00 },
    panel   = { 0.085, 0.095, 0.140, 1.00 },
    panelHi = { 0.130, 0.150, 0.210, 1.00 },
    yellow  = { 0.988, 0.933, 0.039, 1.00 },
    cyan    = { 0.000, 0.940, 1.000, 1.00 },
    cyanD   = { 0.000, 0.480, 0.560, 1.00 },
    red     = { 1.000, 0.300, 0.380, 1.00 },
    redD    = { 0.450, 0.090, 0.140, 1.00 },
    green   = { 0.250, 1.000, 0.600, 1.00 },
    text    = { 0.900, 0.930, 0.960, 1.00 },
    dim     = { 0.560, 0.610, 0.700, 1.00 },
    black   = { 0.020, 0.020, 0.030, 1.00 },
}

local GAP = 8
local colorPushes, varPushes = 0, 0

local function pushColor(target, c)
    ImGui.PushStyleColor(target, c[1], c[2], c[3], c[4])
    colorPushes = colorPushes + 1
end

local function pushVar(target, a, b)
    if b then
        ImGui.PushStyleVar(target, a, b)
    else
        ImGui.PushStyleVar(target, a)
    end
    varPushes = varPushes + 1
end

local function pushTheme()
    pushVar(ImGuiStyleVar.WindowRounding, 8)
    pushVar(ImGuiStyleVar.ChildRounding, 6)
    pushVar(ImGuiStyleVar.FrameRounding, 4)
    pushVar(ImGuiStyleVar.GrabRounding, 4)
    pushVar(ImGuiStyleVar.ScrollbarRounding, 4)
    pushVar(ImGuiStyleVar.WindowBorderSize, 1)
    pushVar(ImGuiStyleVar.WindowPadding, 14, 12)
    pushVar(ImGuiStyleVar.FramePadding, 10, 6)
    pushVar(ImGuiStyleVar.ItemSpacing, GAP, GAP)

    pushColor(ImGuiCol.WindowBg, C.bg)
    pushColor(ImGuiCol.ChildBg, C.side)
    pushColor(ImGuiCol.Border, C.cyanD)
    pushColor(ImGuiCol.Text, C.text)
    pushColor(ImGuiCol.TitleBg, C.black)
    pushColor(ImGuiCol.TitleBgActive, C.black)
    pushColor(ImGuiCol.TitleBgCollapsed, C.black)
    pushColor(ImGuiCol.FrameBg, C.panel)
    pushColor(ImGuiCol.FrameBgHovered, C.panelHi)
    pushColor(ImGuiCol.FrameBgActive, C.panelHi)
    pushColor(ImGuiCol.Button, C.panel)
    pushColor(ImGuiCol.ButtonHovered, C.cyanD)
    pushColor(ImGuiCol.ButtonActive, C.cyan)
    pushColor(ImGuiCol.CheckMark, C.yellow)
    pushColor(ImGuiCol.SliderGrab, C.cyan)
    pushColor(ImGuiCol.SliderGrabActive, C.yellow)
    pushColor(ImGuiCol.Separator, C.panelHi)
    pushColor(ImGuiCol.ScrollbarBg, C.side)
    pushColor(ImGuiCol.ScrollbarGrab, C.panelHi)
    pushColor(ImGuiCol.ScrollbarGrabHovered, C.cyanD)
    pushColor(ImGuiCol.ScrollbarGrabActive, C.cyan)
    pushColor(ImGuiCol.ResizeGrip, C.cyanD)
    pushColor(ImGuiCol.ResizeGripHovered, C.cyan)
    pushColor(ImGuiCol.ResizeGripActive, C.yellow)
end

local function popTheme()
    ImGui.PopStyleColor(colorPushes)
    ImGui.PopStyleVar(varPushes)
    colorPushes, varPushes = 0, 0
end

---------------------------------------------------------------------------
-- Widgets
---------------------------------------------------------------------------

-- All sizes scale with the CET font so the menu fits any resolution.
local function em(n)
    return n * ImGui.GetFontSize()
end

local function availWidth()
    local w = ImGui.GetContentRegionAvail()
    return w
end

local function textColored(c, text)
    ImGui.TextColored(c[1], c[2], c[3], c[4], text)
end

local function wrapped(c, text)
    ImGui.PushStyleColor(ImGuiCol.Text, c[1], c[2], c[3], 1)
    ImGui.TextWrapped(text)
    ImGui.PopStyleColor(1)
end

local function hint(text) wrapped(C.dim, text) end
local function warn(text) wrapped(C.red, text) end

local firstSection = true

local function section(title)
    if not firstSection then
        ImGui.Dummy(0, em(0.4))
    end
    firstSection = false
    textColored(C.cyan, string.upper(title))
    ImGui.Separator()
end

-- Yellow call-to-action button with dark text.
local function primaryButton(label, width)
    ImGui.PushStyleColor(ImGuiCol.Button, C.yellow[1], C.yellow[2], C.yellow[3], 1)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, 1, 1, 0.50, 1)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, C.cyan[1], C.cyan[2], C.cyan[3], 1)
    ImGui.PushStyleColor(ImGuiCol.Text, C.black[1], C.black[2], C.black[3], 1)
    local pressed = ImGui.Button(label, width or 0, 0)
    ImGui.PopStyleColor(4)
    return pressed
end

local function dangerButton(label, width)
    ImGui.PushStyleColor(ImGuiCol.Button, C.redD[1], C.redD[2], C.redD[3], 1)
    ImGui.PushStyleColor(ImGuiCol.ButtonHovered, C.red[1], C.red[2], C.red[3], 1)
    ImGui.PushStyleColor(ImGuiCol.ButtonActive, C.red[1], C.red[2], C.red[3], 1)
    local pressed = ImGui.Button(label, width or 0, 0)
    ImGui.PopStyleColor(3)
    return pressed
end

local function button(label, width)
    return ImGui.Button(label, width or 0, 0)
end

-- Width of each button when `count` buttons share one row.
local function columnWidth(count)
    return (availWidth() - GAP * (count - 1)) / count
end

-- Checkbox that lights up while active. Returns newValue, changed.
local function toggle(label, value)
    if value then
        ImGui.PushStyleColor(ImGuiCol.Text, C.yellow[1], C.yellow[2], C.yellow[3], 1)
    end
    local newValue, changed = ImGui.Checkbox(label, value)
    if value then
        ImGui.PopStyleColor(1)
    end
    return newValue, changed
end

-- Animated on/off switch, drawn by hand. Needs CET's draw-list functions; when
-- those are missing the trainer falls back to plain checkboxes.
local drawSupported = nil
local switchAnim = {}

local function canDraw()
    if drawSupported == nil then
        drawSupported = pcall(function()
            local dl = ImGui.GetWindowDrawList()
            local clear = ImGui.GetColorU32(0, 0, 0, 0)
            local x, y = ImGui.GetCursorScreenPos()
            ImGui.ImDrawListAddRectFilled(dl, x, y, x, y, clear, 0)
            ImGui.ImDrawListAddCircleFilled(dl, x, y, 0, clear, 12)
            ImGui.SetCursorScreenPos(x, y)
            if type(x) ~= "number" or type(y) ~= "number" then error("no cursor position") end
        end)
    end
    return drawSupported
end

local function mix(a, b, t)
    return a + (b - a) * t
end

-- Returns newValue, changed, hovered.
local function switch(id, label, value)
    if not canDraw() then
        local v, changed = toggle(label, value)
        return v, changed, ImGui.IsItemHovered()
    end

    local h = em(1.2)
    local w = h * 1.85
    local x, y = ImGui.GetCursorScreenPos()
    local pressed = ImGui.InvisibleButton("##switch_" .. id, availWidth(), h)
    local hovered = ImGui.IsItemHovered()

    local target = value and 1 or 0
    local t = switchAnim[id] or target
    t = t + (target - t) * 0.28
    if math.abs(target - t) < 0.01 then t = target end
    switchAnim[id] = t

    local dl = ImGui.GetWindowDrawList()
    local off = hovered and C.cyanD or C.panelHi
    local track = ImGui.GetColorU32(mix(off[1], C.yellow[1], t), mix(off[2], C.yellow[2], t),
        mix(off[3], C.yellow[3], t), 1)
    local knob = ImGui.GetColorU32(mix(C.text[1], C.black[1], t), mix(C.text[2], C.black[2], t),
        mix(C.text[3], C.black[3], t), 1)
    ImGui.ImDrawListAddRectFilled(dl, x, y, x + w, y + h, track, h / 2)
    ImGui.ImDrawListAddCircleFilled(dl, x + h / 2 + (w - h) * t, y + h / 2, h / 2 - 3, knob, 20)

    ImGui.SetCursorScreenPos(x + w + em(0.6), y + (h - ImGui.GetFontSize()) / 2)
    textColored(value and C.yellow or C.text, label)
    ImGui.SetCursorScreenPos(x, y + h + GAP)
    ImGui.Dummy(0, 0)

    return (pressed and not value) or (not pressed and value), pressed, hovered
end

-- Switch for a cheat from the registry, with its description as a tooltip.
local function cheatToggle(key, label)
    local cheat = CHEATS[key]
    local v, changed, hovered = switch(key, label or cheat.label, NCT[key])
    if hovered and cheat.desc then ImGui.SetTooltip(cheat.desc) end
    if changed then setCheat(key, v) end
end

-- Small boxed figure for the dashboard.
local function statTile(id, label, value, width)
    ImGui.PushStyleColor(ImGuiCol.ChildBg, C.panel[1], C.panel[2], C.panel[3], 1)
    ImGui.BeginChild("##tile_" .. id, width, em(4.6), true, ImGuiWindowFlags.NoScrollbar)
    textColored(C.dim, label)
    textColored(C.yellow, value)
    ImGui.EndChild()
    ImGui.PopStyleColor(1)
end

-- Labelled controls. The label sits above the control; when `actionLabel` is
-- given a yellow button is placed to the right and its click is returned.
local ACTION_W = 5.5

local function beginField(label, hasAction)
    textColored(C.dim, label)
    local w = availWidth()
    if hasAction then w = w - em(ACTION_W) - GAP end
    ImGui.PushItemWidth(w)
end

local function endField(id, actionLabel)
    ImGui.PopItemWidth()
    if actionLabel then
        ImGui.SameLine()
        return primaryButton(actionLabel .. "##" .. id, em(ACTION_W))
    end
    return false
end

local function sliderInt(id, label, value, lo, hi, actionLabel)
    beginField(label, actionLabel ~= nil)
    value = ImGui.SliderInt("##" .. id, value, lo, hi)
    return value, endField(id, actionLabel)
end

local function sliderFloat(id, label, value, lo, hi, fmt, actionLabel)
    beginField(label, actionLabel ~= nil)
    value = ImGui.SliderFloat("##" .. id, value, lo, hi, fmt)
    return value, endField(id, actionLabel)
end

local function inputInt(id, label, value, lo, hi, step, actionLabel)
    beginField(label, actionLabel ~= nil)
    value = clamp(ImGui.InputInt("##" .. id, value, step or 1, (step or 1) * 10), lo, hi)
    return value, endField(id, actionLabel)
end

---------------------------------------------------------------------------
-- Pages
---------------------------------------------------------------------------

local function refillAmmo()
    for _, name in ipairs(AMMO) do giveItem(name, 999) end
end

local function drawHomePage()
    local info = NCT.info or {}
    local function shown(value, money)
        if value == nil then return "--" end
        return money and ("E$ " .. formatNumber(value)) or tostring(value)
    end

    local w = columnWidth(4)
    statTile("level", "LEVEL", shown(info.level), w)
    ImGui.SameLine()
    statTile("cred", "STREET CRED", shown(info.cred), w)
    ImGui.SameLine()
    statTile("perk", "PERK POINTS", shown(info.perk), w)
    ImGui.SameLine()
    statTile("money", "EDDIES", shown(info.money, true), w)

    section("Loadouts")
    w = columnWidth(#LOADOUTS)
    local hoveredLoadout
    for i, loadout in ipairs(LOADOUTS) do
        if primaryButton(loadout[1] .. "##loadout", w) then
            run(loadout[1] .. " loadout", function() return applyLoadout(loadout) end)
        end
        if ImGui.IsItemHovered() then hoveredLoadout = loadout end
        if i < #LOADOUTS then ImGui.SameLine() end
    end
    hint(hoveredLoadout and (hoveredLoadout[1] .. ": " .. hoveredLoadout[2])
        or "One click switches on a whole set of cheats. Hover a loadout to see what it does.")

    section("Quick Actions")
    w = columnWidth(3)
    if button("+ E$ 1,000,000", w) then
        run("Added E$ 1,000,000", function() giveItem("Items.money", 1000000) end)
    end
    ImGui.SameLine()
    if button("Heal To Full", w) then
        run("Healed to full", function() fillPool(gamedataStatPoolType.Health) end)
    end
    ImGui.SameLine()
    if button("Refill Ammo", w) then
        run("Ammo refilled", refillAmmo)
    end
    if button("Kill Enemies Nearby", w) then
        run("Kill enemies", function()
            local n = killHostiles(30)
            return n == 0 and "No hostile enemies within 30m" or ("Killed " .. n .. " hostile enemies")
        end)
    end
    ImGui.SameLine()
    if button("Clear Wanted Level", w) then
        run("Wanted level cleared", clearWanted)
    end
    ImGui.SameLine()
    if button("Repair Vehicle", w) then
        run("Vehicle repaired", function() repairVehicle(requireVehicle()) end)
    end

    local active = {}
    for key, cheat in pairs(CHEATS) do
        if NCT[key] then active[#active + 1] = { key, cheat.label } end
    end
    table.sort(active, function(a, b) return a[2] < b[2] end)

    section("Active Cheats  (" .. #active .. ")")
    if #active == 0 then
        hint("Nothing is switched on. Pick a loadout above or browse the pages on the left.")
    else
        for _, entry in ipairs(active) do
            cheatToggle(entry[1])
        end
        if dangerButton("TURN EVERYTHING OFF", availWidth()) then
            everythingOff()
        end
    end
end

local function drawPlayerPage()
    section("Survival")
    cheatToggle("godMode", "God Mode  (take no damage)")
    cheatToggle("infStamina")
    cheatToggle("infOxygen")
    cheatToggle("infRam", "Infinite RAM  (quickhacks)")
    cheatToggle("regen")
    cheatToggle("immune")
    cheatToggle("noFall")

    if primaryButton("RESTORE HEALTH, STAMINA AND RAM", availWidth()) then
        run("Health, stamina and RAM restored", function()
            fillPool(gamedataStatPoolType.Health)
            pcall(fillPool, gamedataStatPoolType.Stamina)
            pcall(fillPool, gamedataStatPoolType.Memory)
        end)
    end

    section("Abilities")
    cheatToggle("doubleJump")
    cheatToggle("airDash")
    cheatToggle("silent")

    section("Movement")
    NCT.speedMult = sliderFloat("speed", "Run speed", NCT.speedMult, 1.0, 5.0, "x%.1f")
    NCT.jumpMult = sliderFloat("jump", "Jump height", NCT.jumpMult, 1.0, 10.0, "x%.1f")
    NCT.carryBonus = sliderInt("carry", "Extra carry weight", NCT.carryBonus, 0, 5000)

    local w = columnWidth(2)
    if primaryButton("APPLY MOVEMENT", w) then
        run("Movement applied", function()
            setStatMod("speed", gamedataStatType.MaxSpeed, gameStatModifierType.Multiplier,
                NCT.speedMult > 1.0 and NCT.speedMult or nil)
            setStatMod("jump", gamedataStatType.JumpHeight, gameStatModifierType.Multiplier,
                NCT.jumpMult > 1.0 and NCT.jumpMult or nil)
            setStatMod("carry", gamedataStatType.CarryCapacity, gameStatModifierType.Additive,
                NCT.carryBonus > 0 and NCT.carryBonus or nil)
        end)
    end
    ImGui.SameLine()
    if button("Reset Movement", w) then
        run("Movement reset", resetMovement)
    end
    hint("Reset movement before saving if you want a clean save.")
end

local function drawCombatPage()
    section("Ammo")
    cheatToggle("infAmmo", "Infinite Ammo  (no ammo used)")
    if button("Refill Ammo Now", availWidth()) then
        run("Ammo refilled", function()
            for _, name in ipairs(AMMO) do giveItem(name, 999) end
        end)
    end

    section("Enemies")
    local w = columnWidth(2)
    if primaryButton("KILL ENEMIES (30m)", w) then
        run("Kill enemies", function()
            local n = killHostiles(30)
            return n == 0 and "No hostile enemies within 30m" or ("Killed " .. n .. " hostile enemies")
        end)
    end
    ImGui.SameLine()
    if primaryButton("KILL ENEMIES (100m)", w) then
        run("Kill enemies", function()
            local n = killHostiles(100)
            return n == 0 and "No hostile enemies within 100m" or ("Killed " .. n .. " hostile enemies")
        end)
    end
    hint("Only enemies that are hostile to you. Civilians and friendly characters are left alone.")

    section("Damage")
    cheatToggle("alwaysCrit")
    cheatToggle("megaCrit", "Mega Crit Damage  (+1000%)")
    cheatToggle("headshots")

    section("Defense")
    cheatToggle("tankArmor", "Tank Armor  (+10,000)")
    cheatToggle("invisible", "Invisible To Enemies")
    cheatToggle("slowMo", "Slow Motion  (25% speed)")

    section("Cyberware")
    local apply
    NCT.cwCapacity, apply = sliderInt("cw", "Extra cyberware capacity", NCT.cwCapacity, 0, 1000, "SET")
    if apply then
        run("Cyberware capacity +" .. NCT.cwCapacity, function()
            setStatMod("cwCapacity", gamedataStatType.Humanity, gameStatModifierType.Additive,
                NCT.cwCapacity > 0 and NCT.cwCapacity or nil)
        end)
    end
    hint("Turn damage, armor and cyberware cheats off before saving if you want a clean save.")
end

local MONEY_PRESETS = {
    { "+10K", 10000 }, { "+100K", 100000 }, { "+1M", 1000000 }, { "+10M", 10000000 },
}

local function drawMoneyPage()
    section("Eddies")
    textColored(C.dim, "Current balance")
    if NCT.info and NCT.info.money then
        textColored(C.yellow, "E$ " .. formatNumber(NCT.info.money))
    else
        textColored(C.dim, "--")
    end

    local w = columnWidth(#MONEY_PRESETS)
    for i, preset in ipairs(MONEY_PRESETS) do
        if primaryButton(preset[1], w) then
            run("Added E$ " .. formatNumber(preset[2]), function()
                giveItem("Items.money", preset[2])
            end)
        end
        if i < #MONEY_PRESETS then ImGui.SameLine() end
    end

    section("Custom Amount")
    NCT.moneyAmount = inputInt("money", "Amount", NCT.moneyAmount, 1, 2000000000, 10000)
    w = columnWidth(2)
    if primaryButton("ADD MONEY", w) then
        run("Added E$ " .. formatNumber(NCT.moneyAmount), function()
            giveItem("Items.money", NCT.moneyAmount)
        end)
    end
    ImGui.SameLine()
    if button("Remove Money", w) then
        run("Removed E$ " .. formatNumber(NCT.moneyAmount), function()
            Game.GetTransactionSystem():RemoveItem(getPlayer(), itemID("Items.money"), NCT.moneyAmount)
        end)
    end
end

local ATTRIBUTES = {
    { "Body", "Strength" },
    { "Reflexes", "Reflexes" },
    { "Tech", "TechnicalAbility" },
    { "Intelligence", "Intelligence" },
    { "Cool", "Cool" },
}

local SKILLS = { "CoolSkill", "IntelligenceSkill", "ReflexesSkill", "StrengthSkill", "TechnicalAbilitySkill" }

local function maxSkills()
    local confirmed = 0
    for _, skill in ipairs(SKILLS) do
        if setProficiency(skill, 60) then confirmed = confirmed + 1 end
    end
    return confirmed == #SKILLS
end

local function maxAttributes()
    local confirmed = 0
    for _, attr in ipairs(ATTRIBUTES) do
        if setAttribute(attr[2], 20) then confirmed = confirmed + 1 end
    end
    return confirmed == #ATTRIBUTES
end

local function drawProgressPage()
    local info = NCT.info or {}
    local apply

    section("One Click")
    if primaryButton("MAX OUT CHARACTER", availWidth()) then
        run("Max out character", function()
            local level = setProficiency("Level", 60)
            local cred = setProficiency("StreetCred", 50)
            local skills = maxSkills()
            local attrs = maxAttributes()
            if level and cred and skills and attrs then
                return "Level 60, street cred 50, all skills 60, all attributes 20"
            end
            return "Max out requested - check the character menu"
        end)
    end
    hint("Level 60, street cred 50, every skill at 60 and every attribute at 20.")

    section("Points")
    NCT.attrPoints, apply = inputInt("attr",
        "Attribute points  (you have " .. tostring(info.attr or "--") .. ")",
        NCT.attrPoints, 1, 100, 1, "GIVE")
    if apply then
        run("Give attribute points", function()
            return addDevPoints("Attribute", NCT.attrPoints, "attribute")
        end)
    end

    NCT.perkPoints, apply = inputInt("perk",
        "Perk points  (you have " .. tostring(info.perk or "--") .. ")",
        NCT.perkPoints, 1, 300, 1, "GIVE")
    if apply then
        run("Give perk points", function()
            return addDevPoints("Primary", NCT.perkPoints, "perk")
        end)
    end

    NCT.relicPoints, apply = inputInt("relic",
        "Relic points  (you have " .. tostring(info.relic or "--") .. ")",
        NCT.relicPoints, 1, 15, 1, "GIVE")
    if apply then
        run("Give relic points", function()
            return addDevPoints("Espionage", NCT.relicPoints, "relic")
        end)
    end
    hint("Relic points need the Phantom Liberty expansion.")

    section("Experience")
    NCT.xpMult, apply = sliderInt("xpmult", "XP multiplier for everything you earn", NCT.xpMult, 1, 20, "SET")
    if apply then
        run("XP multiplier x" .. NCT.xpMult, function()
            setStatMod("xpMult", gamedataStatType.XPbonusMultiplier, gameStatModifierType.Additive,
                NCT.xpMult > 1 and (NCT.xpMult - 1) or nil)
        end)
    end
    local xw = columnWidth(2)
    if button("+10,000 XP", xw) then
        run("Gave 10,000 XP", function()
            devData():AddExperience(10000, gamedataProficiencyType.Level, gainReason(), false)
        end)
    end
    ImGui.SameLine()
    if button("+10,000 Street Cred XP", xw) then
        run("Gave 10,000 street cred XP", function()
            devData():AddExperience(10000, gamedataProficiencyType.StreetCred, gainReason(), false)
        end)
    end

    section("Level")
    NCT.level, apply = sliderInt("level", "Character level", NCT.level, 1, 60, "SET")
    if apply then
        run("Set level", function()
            if setProficiency("Level", NCT.level) then
                return "Level set to " .. NCT.level
            end
            return "Level change requested - check the character menu"
        end)
    end

    NCT.streetCred, apply = sliderInt("cred", "Street cred", NCT.streetCred, 1, 50, "SET")
    if apply then
        run("Set street cred", function()
            if setProficiency("StreetCred", NCT.streetCred) then
                return "Street cred set to " .. NCT.streetCred
            end
            return "Street cred change requested - check the character menu"
        end)
    end

    if button("Max All Skills  (level 60)", availWidth()) then
        run("Max all skills", function()
            if maxSkills() then return "All 5 skills set to 60" end
            return "Skill changes requested - check the character menu"
        end)
    end
    hint("Headhunter, Netrunner, Shinobi, Solo and Engineer.")

    section("Attributes")
    NCT.attrValue = sliderInt("attrval", "Set attribute to", NCT.attrValue, 3, 20)
    local w = columnWidth(#ATTRIBUTES)
    for i, attr in ipairs(ATTRIBUTES) do
        if button(attr[1], w) then
            run("Set " .. attr[1], function()
                if setAttribute(attr[2], NCT.attrValue) then
                    return attr[1] .. " set to " .. NCT.attrValue
                end
                return attr[1] .. " change requested - check the character menu"
            end)
        end
        if i < #ATTRIBUTES then ImGui.SameLine() end
    end
    if button("Max All Attributes  (20)", availWidth()) then
        run("Max all attributes", function()
            if maxAttributes() then return "All attributes set to 20" end
            return "Attribute changes requested - check the character menu"
        end)
    end
end

local MATERIALS = {
    "Items.CommonMaterial1", "Items.UncommonMaterial1", "Items.RareMaterial1",
    "Items.EpicMaterial1", "Items.LegendaryMaterial1",
}
local HACK_MATERIALS = {
    "Items.QuickHackUncommonMaterial1", "Items.QuickHackRareMaterial1",
    "Items.QuickHackEpicMaterial1", "Items.QuickHackLegendaryMaterial1",
}
local ICONICS = {
    { "Satori (katana)", "Items.Preset_Katana_Saburo" },
    { "Malorian Arms 3516", "Items.Preset_Silverhand_3516" },
    { "Skippy (smart pistol)", "Items.mq007_skippy" },
    { "Dying Night (pistol)", "Items.Preset_Lexington_Wilson" },
    { "Archangel (revolver)", "Items.Preset_Overture_Kerry" },
    { "La Chingona Dorada", "Items.Preset_Nue_Jackie" },
    { "Widow Maker (rifle)", "Items.Preset_Achilles_Nash" },
    { "Plan B (pistol)", "Items.Preset_Liberty_Dex" },
}

-- Gives every item in a list; returns how many were accepted by the game.
local function giveList(names, qty)
    local given = 0
    for _, name in ipairs(names) do
        if pcall(giveItemChecked, name, qty) then given = given + 1 end
    end
    if given == 0 then error("none of these item IDs exist on this game version") end
    return given
end

local function drawItemsPage()
    section("Quick Packs")
    NCT.matQty = inputInt("matqty", "Quantity of each", NCT.matQty, 1, 100000, 100)

    local w = columnWidth(3)
    if primaryButton("CRAFTING PARTS", w) then
        run("Give crafting components", function()
            local n = giveList(MATERIALS, NCT.matQty)
            return "Gave " .. n .. " of " .. #MATERIALS .. " crafting component types x" .. NCT.matQty
        end)
    end
    ImGui.SameLine()
    if primaryButton("QUICKHACK PARTS", w) then
        run("Give quickhack components", function()
            local n = giveList(HACK_MATERIALS, NCT.matQty)
            return "Gave " .. n .. " of " .. #HACK_MATERIALS .. " quickhack component types x" .. NCT.matQty
        end)
    end
    ImGui.SameLine()
    if primaryButton("AMMO", w) then
        run("Give ammo", function()
            local n = giveList(AMMO, NCT.matQty)
            return "Gave " .. n .. " of " .. #AMMO .. " ammo types x" .. NCT.matQty
        end)
    end

    section("Iconic Weapons")
    w = columnWidth(2)
    for i, weapon in ipairs(ICONICS) do
        if button(weapon[1], w) then
            run("Give " .. weapon[1], function()
                giveItemChecked(weapon[2], 1)
                return "Added " .. weapon[1] .. " to your inventory"
            end)
        end
        if i % 2 == 1 and i < #ICONICS then ImGui.SameLine() end
    end

    section("Spawn Any Item")
    beginField("Item ID", false)
    NCT.itemId = ImGui.InputText("##itemid", NCT.itemId, 128)
    endField("itemid")
    local apply
    NCT.itemQty, apply = inputInt("itemqty", "Quantity", NCT.itemQty, 1, 1000000, 1, "ADD")
    if apply then
        local id = NCT.itemId
        if not id:find("%.") then id = "Items." .. id end
        run("Add item", function()
            giveItemChecked(id, NCT.itemQty)
            return "Added " .. id .. " x" .. NCT.itemQty
        end)
    end
    hint("Example: Items.Preset_Lexington_Default. A red message means the ID does not exist.")
end

local WEATHER = {
    { "Sunny", "24h_weather_sunny" },
    { "Cloudy", "24h_weather_cloudy" },
    { "Rain", "24h_weather_rain" },
    { "Fog", "24h_weather_fog" },
    { "Pollution", "24h_weather_pollution" },
    { "Toxic Rain", "24h_weather_toxic_rain" },
    { "Sandstorm", "24h_weather_sandstorm" },
    { "Heavy Clouds", "24h_weather_heavy_clouds" },
}

local TIMES = { { "Dawn", 6 }, { "Noon", 12 }, { "Dusk", 19 }, { "Midnight", 0 } }

local function setHour(hour)
    Game.GetTimeSystem():SetGameTimeByHMS(hour, 0, 0)
end

local function drawWorldPage()
    local apply

    section("Time")
    local w = columnWidth(#TIMES)
    for i, preset in ipairs(TIMES) do
        if button(preset[1], w) then
            NCT.hour = preset[2]
            run(string.format("Time set to %02d:00", preset[2]), function() setHour(preset[2]) end)
        end
        if i < #TIMES then ImGui.SameLine() end
    end
    NCT.hour, apply = sliderInt("hour", "Hour of day", NCT.hour, 0, 23, "SET")
    if apply then
        run(string.format("Time set to %02d:00", NCT.hour), function() setHour(NCT.hour) end)
    end
    cheatToggle("freezeClock")

    NCT.gameSpeed, apply = sliderFloat("gspeed", "Game speed", NCT.gameSpeed, 0.1, 3.0, "x%.2f", "SET")
    if apply then
        NCT.slowMo = false
        run(string.format("Game speed x%.2f", NCT.gameSpeed), function() setGameSpeed(NCT.gameSpeed) end)
    end
    if button("Back To Normal Speed", availWidth()) then
        NCT.gameSpeed, NCT.slowMo = 1.0, false
        run("Game speed normal", function() setGameSpeed(1.0) end)
    end

    section("Weather")
    w = columnWidth(4)
    for i, weather in ipairs(WEATHER) do
        if button(weather[1], w) then
            run("Weather: " .. weather[1], function()
                Game.GetWeatherSystem():SetWeather(CName.new(weather[2]), 5.0, 9)
            end)
        end
        if i % 4 ~= 0 and i < #WEATHER then ImGui.SameLine() end
    end
    if button("Reset Weather", availWidth()) then
        run("Weather reset", function() Game.GetWeatherSystem():ResetWeather(true) end)
    end

    section("Police")
    cheatToggle("noPolice", "Disable Police  (no wanted level)")
    if primaryButton("CLEAR WANTED LEVEL", availWidth()) then
        run("Wanted level cleared", clearWanted)
    end

end

local HERO_VEHICLES = {
    { "Rayfield Caliburn", "Vehicle.v_sport1_rayfield_caliburn_player" },
    { "Rayfield Aerondight", "Vehicle.v_sport1_rayfield_aerondight_player" },
    { "Quadra Type-66 Avenger", "Vehicle.v_sport2_quadra_type66_avenger_player" },
    { "Porsche 911 Turbo", "Vehicle.v_sport2_porsche_911turbo_player" },
    { "Yaiba Kusanagi (bike)", "Vehicle.v_sportbike1_yaiba_kusanagi_player" },
    { "Jackie's Arch (bike)", "Vehicle.v_sportbike2_arch_jackie_player" },
}

local function drawVehiclesPage()
    section("Current Vehicle")
    local inVehicle = getPlayer() and mountedVehicle() ~= nil
    if inVehicle then
        textColored(C.green, "You are in a vehicle.")
    else
        hint("Get in a vehicle to use the buttons in this section.")
    end

    cheatToggle("carGod", "Indestructible Vehicle  (auto-repairs)")

    local w = columnWidth(2)
    if primaryButton("REPAIR VEHICLE", w) then
        run("Vehicle repaired", function() repairVehicle(requireVehicle()) end)
    end
    ImGui.SameLine()
    if primaryButton("FLIP UPRIGHT", w) then
        run("Vehicle flipped upright", flipVehicle)
    end

    if button("Open All Doors", w) then
        run("Doors opened", function() setVehicleDoors(true) end)
    end
    ImGui.SameLine()
    if button("Close All Doors", w) then
        run("Doors closed", function() setVehicleDoors(false) end)
    end

    if button("Next Radio Station", w) then
        run("Radio station changed", function() requireVehicle():NextRadioReceiverStation() end)
    end
    ImGui.SameLine()
    if button("Boost Forward", w) then
        run("Boosted " .. NCT.blinkDistance .. "m forward", function()
            requireVehicle()
            blink(NCT.blinkDistance)
        end)
    end
    hint("Boost uses the blink distance from the Teleport page. Fly Mode and saved spots also "
        .. "carry the vehicle you are driving.")

    section("Dream Garage")
    hint("Adds the vehicle to your owned list, ready to call from the vehicle menu.")
    for i, car in ipairs(HERO_VEHICLES) do
        if button(car[1] .. "##hero" .. i, w) then
            run("Add " .. car[1], function()
                if not TweakDB:GetRecord(TweakDBID.new(car[2])) then
                    error(car[1] .. " does not exist on this game version")
                end
                Game.GetVehicleSystem():EnablePlayerVehicle(car[2], true, false)
                return car[1] .. " added to your vehicles"
            end)
        end
        if i % 2 == 1 and i < #HERO_VEHICLES then ImGui.SameLine() end
    end

    section("Garage")
    if primaryButton("SUMMON MY VEHICLE", availWidth()) then
        run("Vehicle summoned", function() Game.GetVehicleSystem():SpawnPlayerVehicle() end)
    end
    if primaryButton("UNLOCK ALL VEHICLES", availWidth()) then
        run("All vehicles unlocked", function()
            Game.GetVehicleSystem():EnableAllPlayerVehicles()
        end)
    end
    hint("Unlocking is permanent for the save it is used on.")
end

local function drawTeleportPage()
    section("Fly Mode")
    cheatToggle("fly", "Fly Mode  (no clip)")
    NCT.flySpeed = sliderInt("flyspeed", "Fly speed in metres per second", NCT.flySpeed, 5, 100)
    hint("Bind the four Fly keys in CET's Bindings tab first. You hover in place, then move where the "
        .. "camera points. Switch on God Mode before turning Fly Mode off high up.")

    section("Blink")
    NCT.blinkDistance = sliderInt("blink", "Distance in metres", NCT.blinkDistance, 2, 100)
    local w = columnWidth(2)
    if primaryButton("BLINK FORWARD", w) then
        run("Blinked " .. NCT.blinkDistance .. "m forward", function() blink(NCT.blinkDistance) end)
    end
    ImGui.SameLine()
    if button("Lift Up 10m", w) then
        run("Lifted up", function()
            local pos = getPlayer():GetWorldPosition()
            teleportTo(pos.x, pos.y, pos.z + 10)
        end)
    end
    hint("Blink goes through walls and doors. Use Lift Up if you get stuck in the floor.")

    section("Saved Spots  (" .. #NCT.spots .. " of " .. MAX_SPOTS .. ")")
    if primaryButton("SAVE CURRENT POSITION", availWidth()) then
        if #NCT.spots >= MAX_SPOTS then
            toast("All " .. MAX_SPOTS .. " spots are used. Delete one first.", false)
        else
            run("Spot saved", function()
                local pos = getPlayer():GetWorldPosition()
                local name = "Spot " .. (#NCT.spots + 1)
                NCT.spots[#NCT.spots + 1] = { name = name, x = pos.x, y = pos.y, z = pos.z }
                saveSettings()
                return name .. " saved"
            end)
        end
    end

    local removeIndex
    for i, spot in ipairs(NCT.spots) do
        local goW = availWidth() - em(4) - GAP
        local label = string.format("%s   (%.0f, %.0f, %.0f)##spot%d", spot.name, spot.x, spot.y, spot.z, i)
        if button(label, goW) then
            run("Teleported to " .. spot.name, function() teleportTo(spot.x, spot.y, spot.z) end)
        end
        ImGui.SameLine()
        if dangerButton("Del##spot" .. i, em(4)) then removeIndex = i end
    end
    if removeIndex then
        local name = NCT.spots[removeIndex].name
        table.remove(NCT.spots, removeIndex)
        saveSettings()
        toast(name .. " deleted", true)
    end
    if #NCT.spots == 0 then
        hint("No spots saved yet. Spots are kept between game sessions.")
    end
end

local function unlockAllAchievements()
    local system = Game.GetAchievementSystem()
    local records = TweakDB:GetRecords("gamedataAchievement_Record")
    local count = 0
    for _, record in ipairs(records) do
        if pcall(function() system:UnlockAchievement(record) end) then
            count = count + 1
        end
    end
    if count == 0 then
        error("no achievements could be unlocked")
    end
    return count
end

local function drawAchievementsPage()
    section("Steam Achievements")
    hint("Unlocks every achievement the game knows about on your Steam account.")
    warn("This is permanent. Steam has no way to re-lock them.")

    NCT.achConfirm = ImGui.Checkbox("I understand, unlock them all", NCT.achConfirm)
    if NCT.achConfirm then
        if primaryButton("UNLOCK ALL ACHIEVEMENTS", availWidth()) then
            run("Unlock achievements", function()
                return "Sent " .. unlockAllAchievements() .. " achievements to Steam"
            end)
            NCT.achConfirm = false
        end
    end
    hint("Steam can take a minute to show them. Check your profile afterwards.")
end

local HOTKEY_HELP = {
    "Add E$ 100,000", "Heal to full", "Refill ammo", "Clear wanted level",
    "Toggle God Mode", "Toggle Infinite Ammo", "Toggle Slow Motion", "Toggle Fly Mode",
    "Toggle Indestructible Vehicle", "Repair vehicle", "Flip vehicle upright",
    "Kill hostile enemies nearby",
    "Blink forward", "Teleport to first saved spot", "Turn every cheat off",
    "Fly: forward / back / up / down  (hold)",
}

local function drawSettingsPage()
    section("Trainer")
    local v, changed = ImGui.Checkbox("Remember my cheats between sessions", NCT.rememberCheats)
    if changed then
        NCT.rememberCheats = v
        saveSettings()
    end
    hint("God mode, infinite stamina, oxygen, RAM and ammo, and disabled police switch back on "
        .. "automatically when you load a save.")

    v, changed = ImGui.Checkbox("Show pop-ups when I use a hotkey", NCT.showPopups)
    if changed then
        NCT.showPopups = v
        saveSettings()
    end
    hint("A small message appears at the top of the screen while the menu is closed.")

    section("Panic Button")
    if dangerButton("TURN EVERY CHEAT OFF", availWidth()) then
        everythingOff()
    end
    hint("Switches off every toggle and resets movement, cyberware capacity and game speed. "
        .. "Use it before saving for a clean save.")

    section("Hotkeys")
    hint("Bind these in the CET overlay under Bindings > NightCityTrainer:")
    for _, line in ipairs(HOTKEY_HELP) do
        textColored(C.text, "  - " .. line)
    end
end

-- name, draw function, icon name (from CET's bundled icon font)
local PAGES = {
    { "Home", drawHomePage, "Home" },
    { "Player", drawPlayerPage, "Account" },
    { "Combat", drawCombatPage, "Sword" },
    { "Money", drawMoneyPage, "Cash" },
    { "Progress", drawProgressPage, "TrendingUp" },
    { "Items", drawItemsPage, "PackageVariant" },
    { "Vehicles", drawVehiclesPage, "Car" },
    { "World", drawWorldPage, "Earth" },
    { "Teleport", drawTeleportPage, "MapMarker" },
    { "Achievements", drawAchievementsPage, "Trophy" },
    { "Settings", drawSettingsPage, "Cog" },
}

local function pageIcon(name)
    local ok, glyph = pcall(function() return IconGlyphs[name] end)
    if ok and type(glyph) == "string" then return glyph .. "  " end
    return ""
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

local function drawHeader()
    textColored(C.yellow, "NIGHT CITY TRAINER")
    ImGui.SameLine()
    textColored(C.dim, "v" .. NCT.version)

    local info = NCT.info
    if info then
        local parts = {}
        if info.level then parts[#parts + 1] = "LVL " .. info.level end
        if info.cred then parts[#parts + 1] = "CRED " .. info.cred end
        if info.money then parts[#parts + 1] = "E$ " .. formatNumber(info.money) end
        local active = activeCheatCount()
        parts[#parts + 1] = active .. (active == 1 and " cheat on" or " cheats on")
        textColored(C.green, "ONLINE")
        ImGui.SameLine()
        textColored(C.text, table.concat(parts, "   |   "))
    else
        textColored(C.red, "NO SAVE LOADED")
        ImGui.SameLine()
        textColored(C.dim, "load a save to enable the cheats")
    end
end

local function drawSidebar()
    local w = availWidth()
    -- Left-aligned labels so the icons line up.
    ImGui.PushStyleVar(ImGuiStyleVar.ButtonTextAlign, 0.08, 0.5)
    for _, page in ipairs(PAGES) do
        local name = page[1]
        local label = pageIcon(page[3]) .. name .. "##nav"
        if NCT.page == name then
            primaryButton(label, w)
        elseif button(label, w) then
            NCT.page = name
        end
    end
    ImGui.Dummy(0, em(0.3))
    if dangerButton(pageIcon("Power") .. "All Off##nav", w) then
        everythingOff()
    end
    ImGui.PopStyleVar(1)
end

local function drawWindow()
    ImGui.SetNextWindowSize(em(46), em(42), ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowPos(80, 80, ImGuiCond.FirstUseEver)

    if ImGui.Begin("Night City Trainer", ImGuiWindowFlags.NoCollapse) then
        drawHeader()
        ImGui.Separator()

        local _, availH = ImGui.GetContentRegionAvail()
        local bodyH = math.max(availH - em(2.2), em(6))

        ImGui.BeginChild("##nct_side", em(11), bodyH, true)
        drawSidebar()
        ImGui.EndChild()

        ImGui.SameLine()

        ImGui.PushStyleColor(ImGuiCol.ChildBg, 0, 0, 0, 0)
        ImGui.BeginChild("##nct_page", 0, bodyH, true)
        firstSection = true
        local found = false
        for _, page in ipairs(PAGES) do
            if page[1] == NCT.page then
                found = true
                local ok, err = pcall(page[2])
                if not ok then
                    warn("This page hit an error: " .. tostring(err))
                end
            end
        end
        if not found then NCT.page = "Home" end
        ImGui.EndChild()
        ImGui.PopStyleColor(1)

        wrapped(NCT.toast.ok and C.green or C.red, "> " .. NCT.toast.text)
    end
    ImGui.End()
end

-- Small message at the top of the screen, shown while the menu is closed so
-- hotkeys still give feedback.
local function drawPopup()
    local width = GetDisplayResolution()
    ImGui.SetNextWindowPos(width / 2, 70, ImGuiCond.Always, 0.5, 0)
    local flags = ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoResize + ImGuiWindowFlags.NoMove
        + ImGuiWindowFlags.NoScrollbar + ImGuiWindowFlags.NoSavedSettings + ImGuiWindowFlags.NoInputs
        + ImGuiWindowFlags.AlwaysAutoResize + ImGuiWindowFlags.NoFocusOnAppearing
    if ImGui.Begin("##nct_popup", flags) then
        textColored(C.yellow, "TRAINER")
        ImGui.SameLine()
        textColored(NCT.toast.ok and C.green or C.red, NCT.toast.text)
    end
    ImGui.End()
end

---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

registerForEvent("onInit", function()
    loadSettings()
    print("[NightCityTrainer] v" .. NCT.version .. " loaded. Open the CET overlay to use it.")
end)

registerForEvent("onShutdown", function()
    saveSettings()
end)

registerForEvent("onOverlayOpen", function()
    NCT.overlayOpen = true
    refreshInfo()
end)

registerForEvent("onOverlayClose", function()
    NCT.overlayOpen = false
    saveSettings()
end)

registerForEvent("onUpdate", function(delta)
    NCT.tick = NCT.tick + delta
    NCT.infoTick = NCT.infoTick + delta
    NCT.slowTick = NCT.slowTick + delta

    if NCT.fly then pcall(updateFly, delta) end

    if NCT.tick >= 0.2 then
        NCT.tick = 0
        if (NCT.infStamina or NCT.infOxygen or NCT.infRam) and getPlayer() then
            pcall(function()
                if NCT.infStamina then fillPool(gamedataStatPoolType.Stamina) end
                if NCT.infOxygen then fillPool(gamedataStatPoolType.Oxygen) end
                if NCT.infRam then fillPool(gamedataStatPoolType.Memory) end
            end)
        end
    end

    if NCT.infoTick >= 0.5 then
        NCT.infoTick = 0
        if NCT.overlayOpen then refreshInfo() end
    end

    if NCT.slowTick >= 2.0 then
        NCT.slowTick = 0
        if getPlayer() then
            if NCT.pendingRestore then restoreCheats() end
            -- Re-applied regularly so toggles survive loading another save.
            if NCT.godMode then pcall(setGodMode, true) end
            if NCT.noPolice then pcall(setPolice, false) end
            if NCT.carGod then pcall(protectVehicle) end
            if NCT.infAmmo then
                pcall(setInfiniteAmmoEffect, true)
                pcall(topUpAmmo)
            end
        end
    end
end)

registerForEvent("onDraw", function()
    local showPopup = not NCT.overlayOpen and NCT.showPopups and (os.clock() - NCT.toast.time) < 3
    if not NCT.overlayOpen and not showPopup then return end

    pushTheme()
    local ok, err = pcall(NCT.overlayOpen and drawWindow or drawPopup)
    popTheme()
    if not ok then
        print("[NightCityTrainer] draw error: " .. tostring(err))
    end
end)

---------------------------------------------------------------------------
-- Hotkeys (bind them in the CET overlay under Bindings)
---------------------------------------------------------------------------

local function cheatHotkey(id, key)
    registerHotkey(id, "Toggle " .. CHEATS[key].label, function()
        setCheat(key, not NCT[key])
    end)
end

registerHotkey("nct_add_money", "Add E$ 100,000", function()
    run("Added E$ 100,000", function() giveItem("Items.money", 100000) end)
end)

registerHotkey("nct_heal", "Heal to full", function()
    run("Healed to full", function() fillPool(gamedataStatPoolType.Health) end)
end)

registerHotkey("nct_refill_ammo", "Refill ammo", function()
    run("Ammo refilled", function()
        for _, name in ipairs(AMMO) do giveItem(name, 999) end
    end)
end)

registerHotkey("nct_clear_wanted", "Clear wanted level", function()
    run("Wanted level cleared", clearWanted)
end)

cheatHotkey("nct_god_mode", "godMode")
cheatHotkey("nct_inf_ammo", "infAmmo")
cheatHotkey("nct_slow_mo", "slowMo")
cheatHotkey("nct_fly", "fly")
cheatHotkey("nct_car_god", "carGod")

registerHotkey("nct_repair_vehicle", "Repair vehicle", function()
    run("Vehicle repaired", function() repairVehicle(requireVehicle()) end)
end)

registerHotkey("nct_flip_vehicle", "Flip vehicle upright", function()
    run("Vehicle flipped upright", flipVehicle)
end)

registerHotkey("nct_kill_enemies", "Kill hostile enemies nearby", function()
    run("Kill enemies", function()
        local n = killHostiles(30)
        return n == 0 and "No hostile enemies within 30m" or ("Killed " .. n .. " hostile enemies")
    end)
end)

registerHotkey("nct_blink", "Blink forward", function()
    run("Blinked forward", function() blink(NCT.blinkDistance) end)
end)

registerHotkey("nct_spot_1", "Teleport to first saved spot", function()
    local spot = NCT.spots[1]
    if not spot then
        toast("No saved spot yet.", false)
        return
    end
    run("Teleported to " .. spot.name, function() teleportTo(spot.x, spot.y, spot.z) end)
end)

registerHotkey("nct_all_off", "Turn every cheat off", everythingOff)

registerInput("nct_fly_forward", "Fly: forward (hold)", function(down) NCT.keys.fwd = down end)
registerInput("nct_fly_back", "Fly: back (hold)", function(down) NCT.keys.back = down end)
registerInput("nct_fly_up", "Fly: up (hold)", function(down) NCT.keys.up = down end)
registerInput("nct_fly_down", "Fly: down (hold)", function(down) NCT.keys.down = down end)

return NCT
