-- Night City Trainer
-- A single-player trainer menu for Cyberpunk 2077, built on Cyber Engine Tweaks (CET).
-- Open the CET overlay in game to show the menu.

local NCT = {
    version = "4.9.0",
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
    skillValue = 60,
    job = nil,          -- long task (recipe unlock) running in slices
    lootRadius = 15,    -- metres around the player that Auto Loot reaches
    looted = {},        -- bodies already looted, so each is only emptied once
    skipSpeed = 2,      -- how fast the skip helper presses: 1 balanced, 2 fast, 3 insane
    fovValue = 80,
    fovOn = false,
    fovDefault = 0,     -- the game's own FOV, remembered the first time it is changed
    profiles = { false, false, false },
    checklist = {},     -- test checklist answers: item -> { state, note }
    movementOn = false, -- these four remember whether a slider setting was applied
    cwOn = false,
    xpOn = false,
    speedOn = false,
    rememberCheats = true,
    showPopups = true,

    achConfirm = false,
    mods = {},   -- active stat modifiers, by key
    spots = {},  -- saved teleport positions
    keys = { fwd = false, back = false, left = false, right = false, up = false, down = false },
    flyPos = nil,
}

local SAVED_FIELDS = {
    "page", "speedMult", "jumpMult", "carryBonus", "cwCapacity", "gameSpeed", "hour", "moneyAmount",
    "level", "streetCred", "attrPoints", "perkPoints", "relicPoints", "attrValue", "itemId",
    "itemQty", "matQty", "blinkDistance", "flySpeed", "xpMult", "rememberCheats", "showPopups",
    "movementOn", "cwOn", "xpOn", "speedOn", "skipSpeed", "fovValue", "fovOn", "fovDefault",
    "lootRadius",
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
    -- Weapons and clothing are not stackable, so counting them is unreliable.
    -- The item ID is checked against the game's database first instead.
    if not TweakDB:GetRecord(name) then
        error("'" .. name .. "' is not a valid item ID on this game version")
    end
    local before = itemCount(name)
    giveItem(name, qty)
    if itemCount(name) > before then return end
    local ok, owned = pcall(function()
        return Game.GetTransactionSystem():HasItem(getPlayer(), itemID(name))
    end)
    if not (ok and owned == true) then
        error("the game did not add '" .. name .. "'")
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
        -- After a death or a loaded save the old modifier no longer exists; that is fine.
        pcall(function() stats:RemoveModifier(id, NCT.mods[key]) end)
        NCT.mods[key] = nil
    end
    if value then
        local mod = RPGManager.CreateStatModifier(statType, modType, value)
        stats:AddModifier(id, mod)
        NCT.mods[key] = mod
    end
end

-- Invulnerable blocks damage; Immortal is a second safety net that never lets
-- health reach zero, which covers explosions and other damage that slips past.
local function setGodMode(enabled)
    local gm = Game.GetGodModeSystem()
    local id = getPlayer():GetEntityID()
    local reason = CName.new(REASON)
    for _, kind in ipairs({ "Invulnerable", "Immortal" }) do
        pcall(function()
            local mode = gameGodModeType[kind]
            if enabled then gm:AddGodMode(id, mode, reason) else gm:RemoveGodMode(id, mode, reason) end
        end)
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

-- Sets the wanted level: 0 clears it, 1 to 5 are the police heat stages.
local function setWanted(level)
    preventionSystem():ChangeHeatStage(EPreventionHeatStage["Heat_" .. level], REASON)
end

local function clearWanted()
    setWanted(0)
end

-- The player's first-person camera, used for the field of view.
local function fppCamera()
    return getPlayer():GetFPPCameraComponent()
end

---------------------------------------------------------------------------
-- Ammo
---------------------------------------------------------------------------

-- Cutscenes and dialogue: the game lets players fast-forward certain scenes by
-- holding a key. These helpers do the same without the key.
local function sceneInterface()
    return Game.GetSceneSystem():GetScriptInterface()
end

local function fastForwardMode()
    for _, name in ipairs({ "GameplayReview", "Default" }) do
        local ok, value = pcall(function() return scnFastForwardMode[name] end)
        if ok and value ~= nil then return value end
    end
    error("this game version has no scene fast-forward mode")
end

local function autoSkipScenes()
    local scenes = sceneInterface()
    local mode = fastForwardMode()
    if scenes:IsFastForwardingActive() then return end
    if scenes:IsFastForwardingAllowed(mode) then scenes:FastForwardingActivate(mode) end
end

local function stopFastForward()
    local scenes = sceneInterface()
    if scenes:IsFastForwardingActive() then scenes:FastForwardingDeactivate() end
end

-- How cinematic the game currently is: 1 is normal play, 3 is a limited-control
-- dialogue, 4 and 5 are cutscenes.
local function sceneTier()
    local defs = Game.GetAllBlackboardDefs()
    local board = Game.GetBlackboardSystem():GetLocalInstanced(getPlayer():GetEntityID(), defs.PlayerStateMachine)
    return board:GetInt(defs.PlayerStateMachine.SceneTier)
end

-- True while the "hold to skip" prompt is on screen. This is the most exact
-- signal there is, because it is the same flag the game's own HUD uses.
local function skipPromptShown()
    local defs = Game.GetAllBlackboardDefs()
    local board = Game.GetBlackboardSystem():Get(defs.UI_FastForward)
    return board:GetBool(defs.UI_FastForward.FastForwardHintActive) == true
end

-- True while a cutscene or dialogue scene is playing. A scene counts when the
-- skip prompt is showing, or the game is in a cinematic state. What was seen is
-- kept in NCT.sceneInfo so the menu can show it.
local function inScene()
    local info = {}
    local okPrompt, prompt = pcall(skipPromptShown)
    if okPrompt then info.prompt = prompt end
    local okTier, tier = pcall(sceneTier)
    if okTier and type(tier) == "number" then info.tier = tier end
    local okAllowed, allowed = pcall(function()
        return sceneInterface():IsFastForwardingAllowed(fastForwardMode())
    end)
    if okAllowed then info.allowed = allowed == true end
    NCT.sceneInfo = info

    if info.prompt then return true end
    if info.tier then return info.tier >= 3 end
    return info.allowed == true
end

-- The launcher's skip helper presses the skip key for us, because Cyber Engine
-- Tweaks cannot press keys itself. It reads skip.flag from this folder, and
-- writes helper.alive so the menu can tell whether it is running.
local function writeSkipFlag(active)
    pcall(function()
        local file = io.open("skip.flag", "w")
        if file then
            file:write(os.time() .. " " .. (active and "1" or "0") .. " " .. NCT.skipSpeed)
            file:close()
        end
    end)
end

local function skipHelperRunning()
    local ok, text = pcall(function()
        local file = io.open("helper.alive", "r")
        if not file then return nil end
        local content = file:read("*a")
        file:close()
        return content
    end)
    local stamp = ok and text and tonumber(text:match("%d+"))
    return stamp ~= nil and stamp ~= false and math.abs(os.time() - stamp) <= 4
end

---------------------------------------------------------------------------
-- Combat helpers: one-hit kill, fall guard, auto loot
---------------------------------------------------------------------------

local function poolValue(entityId, pool)
    return Game.GetStatPoolsSystem():GetStatPoolValue(entityId, pool, false)
end

local function setPoolValue(entityId, pool, value)
    Game.GetStatPoolsSystem():RequestSettingStatPoolValue(entityId, pool, value, nil)
end

local function isHostile(npc, player)
    local ok, hostile = pcall(function()
        return GameObject.GetAttitudeTowards(npc, player) == EAIAttitude.AIA_Hostile
    end)
    return ok and hostile
end

local function killNpc(npc, player)
    if not pcall(function() npc:Kill(player, false, false) end) then
        setPoolValue(npc:GetEntityID(), gamedataStatPoolType.Health, 0)
    end
end

-- One-Hit Kill: about ten times a second, any hostile enemy nearby that has
-- lost health is finished off. This needs no hook into the game's damage code.
local function oneHitSweep()
    local player = getPlayer()
    for _, npc in ipairs(player:GetNPCsAroundObject(80)) do
        local alive = false
        pcall(function() alive = not npc:IsDead() end)
        if alive and isHostile(npc, player) then
            local ok, percent = pcall(function()
                return Game.GetStatPoolsSystem():GetStatPoolValue(npc:GetEntityID(), gamedataStatPoolType.Health, true)
            end)
            if ok and type(percent) == "number" and percent < 99.5 then pcall(killNpc, npc, player) end
        end
    end
end

-- Invisible extra: enemies that had already locked on forget about you.
local function dropAggro()
    local player = getPlayer()
    for _, npc in ipairs(player:GetNPCsAroundObject(80)) do
        pcall(function() npc:GetTargetTrackerComponent():ClearThreats() end)
    end
end

-- High falls can kill in one hit, faster than health can be put back. While
-- the player is falling fast, a temporary shield blocks all damage.
local function setFallShield(on)
    if NCT.fallShield == on then return end
    NCT.fallShield = on
    local gm = Game.GetGodModeSystem()
    local id = getPlayer():GetEntityID()
    local reason = CName.new(REASON .. "Fall")
    for _, kind in ipairs({ "Invulnerable", "Immortal" }) do
        pcall(function()
            local mode = gameGodModeType[kind]
            if on then gm:AddGodMode(id, mode, reason) else gm:RemoveGodMode(id, mode, reason) end
        end)
    end
end

-- Fall guard: when the player has just been falling fast and health suddenly
-- drops, the lost health is put back. Runs about 20 times a second.
local function guardFalls()
    local player = getPlayer()
    if not player then return end
    local id = player:GetEntityID()
    local now = os.clock()
    local hp = poolValue(id, gamedataStatPoolType.Health)
    local z = player:GetWorldPosition().z
    local last = NCT.fall
    local airUntil = last and last.airUntil or 0
    if last then
        local speed = (last.z - z) / math.max(now - last.time, 0.001)
        if speed > 6 then airUntil = now + 1.0 end
        if hp < last.hp - 0.5 and now < airUntil + 0.3 then
            pcall(setPoolValue, id, gamedataStatPoolType.Health, last.hp)
            hp = last.hp
        end
    end
    -- Shield on while falling and for a moment after landing.
    setFallShield(now < airUntil + 0.5)
    NCT.fall = { hp = hp, z = z, time = now, airUntil = airUntil }
end

-- Auto loot: takes everything from dead enemies close to the player, once each.
local function autoLootNearby()
    local player = getPlayer()
    local npcs = player:GetNPCsAroundObject(NCT.lootRadius)
    local taken = 0
    local seen = NCT.looted
    local ts = Game.GetTransactionSystem()
    for _, npc in ipairs(npcs) do
        local ok, dead = pcall(function() return npc:IsDead() end)
        if ok and dead then
            local id = tostring(npc:GetEntityID().hash)
            if not seen[id] then
                seen[id] = os.clock()
                if pcall(function() ts:TransferAllItems(npc, player) end) then taken = taken + 1 end
            end
        end
    end
    -- Forget old bodies so the list cannot grow forever.
    local now = os.clock()
    for id, when in pairs(seen) do
        if now - when > 120 then seen[id] = nil end
    end
    return taken
end

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

-- Returns the object when it really is a vehicle, otherwise nil.
local function asVehicle(object)
    if not object then return nil end
    local ok, isVehicle = pcall(function() return object:IsVehicle() end)
    if ok and isVehicle == true then return object end
    return nil
end

-- The vehicle the player is sitting in, or nil when on foot. Several lookups
-- are tried because the game offers more than one and not all work everywhere.
local function mountedVehicle()
    local player = getPlayer()
    if not player then return nil end

    -- The answer is reused for a moment: it is asked for many times a second
    -- while flying, and the lookups are not free.
    local cache = NCT.mountCache
    if cache and os.clock() - cache.time < 0.3 then return cache.vehicle end

    local lookups = {
        function()
            local info = Game.GetMountingFacility():GetMountingInfoSingleWithObjects(player)
            return Game.FindEntityByID(info.parentId)
        end,
        function() return Game.GetMountedVehicle(player) end,
        function() return GetMountedVehicle(player) end,
    }
    local found = nil
    for _, lookup in ipairs(lookups) do
        local ok, object = pcall(lookup)
        found = ok and asVehicle(object) or nil
        if found then break end
    end
    NCT.mountCache = { time = os.clock(), vehicle = found }
    return found
end

-- The vehicle the player is aiming at, or nil.
local function lookedAtVehicle()
    local ok, object = pcall(function()
        return Game.GetTargetingSystem():GetLookAtObject(getPlayer(), false, false)
    end)
    return ok and asVehicle(object) or nil
end

-- The personal vehicle most recently called, or nil.
local function calledVehicle()
    local ok, object = pcall(function() return Game.GetVehicleSystem():GetActivePlayerVehicle() end)
    local vehicle = ok and asVehicle(object) or nil
    if vehicle then return vehicle end
    ok, object = pcall(function() return Game.GetVehicleSystem():GetActivePlayerVehicle(0) end)
    return ok and asVehicle(object) or nil
end

-- Finds the vehicle the vehicle buttons should act on, and says how it was found.
local function findVehicle()
    local vehicle = mountedVehicle()
    if vehicle then return vehicle, "the vehicle you are in" end
    vehicle = lookedAtVehicle()
    if vehicle then return vehicle, "the vehicle you are looking at" end
    vehicle = calledVehicle()
    if vehicle then return vehicle, "your last called vehicle" end
    return nil
end

local function requireVehicle()
    local vehicle = findVehicle()
    if not vehicle then
        error("no vehicle found - get in one, look at one, or call your car first")
    end
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

local function flipVehicle()
    local vehicle = requireVehicle()
    local pos = vehicle:GetWorldPosition()
    local angles = playerRotation(vehicle)
    Game.GetTeleportationFacility():Teleport(vehicle,
        Vector4.new(pos.x, pos.y, pos.z + 1.0, 1), EulerAngles.new(0, 0, angles.yaw))
end

-- Fixes a wrecked personal vehicle once, then calls it to you. This is a single
-- repair when you press the button, not the old always-on repair that could
-- throw the car around.
local function reviveVehicle()
    local vehicleSystem = Game.GetVehicleSystem()
    local vehicle = calledVehicle() or lookedAtVehicle() or mountedVehicle()
    local repaired = 0
    if vehicle then
        if pcall(function() vehicle:GetVehicleComponent():RepairVehicle() end) then repaired = repaired + 1 end
        if pcall(function() vehicle:DestructionResetGrid() end) then repaired = repaired + 1 end
        if pcall(function() vehicle:DestructionResetGlass() end) then repaired = repaired + 1 end
        pcall(function()
            Game.GetStatPoolsSystem():RequestSettingStatPoolMaxValue(vehicle:GetEntityID(),
                gamedataStatPoolType.Health, nil)
        end)
    end
    local onCooldown = false
    pcall(function() onCooldown = vehicleSystem:IsActivePlayerVehicleOnCooldown() == true end)
    pcall(function() vehicleSystem:SpawnPlayerVehicle() end)
    if onCooldown then
        return "Repaired, but the game still has this car on its summon cooldown - pick another car to call meanwhile"
    end
    if repaired > 0 then return "Vehicle repaired and called" end
    return "Vehicle called"
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

-- Fly mode: holds the player in the air and steers them with the camera. Forward
-- and back follow where the camera points, left and right strafe across it, and
-- up and down move straight along the vertical.
local function updateFly(delta)
    local player = getPlayer()
    if not player then return end
    if not NCT.flyPos then
        local pos = player:GetWorldPosition()
        NCT.flyPos = { x = pos.x, y = pos.y, z = pos.z + 0.5 }
    end
    local p, k = NCT.flyPos, NCT.keys
    local step = NCT.flySpeed * delta
    local moving = k.fwd or k.back or k.left or k.right
    if moving then
        local dir = Game.GetCameraSystem():GetActiveCameraForward()
        local forward = (k.fwd and 1 or 0) - (k.back and 1 or 0)
        local side = (k.right and 1 or 0) - (k.left and 1 or 0)
        -- The right-hand direction is the camera direction turned 90 degrees, flat on the ground.
        local flat = math.sqrt(dir.x * dir.x + dir.y * dir.y)
        local rx, ry = 0, 0
        if flat > 0.001 then rx, ry = dir.y / flat, -dir.x / flat end
        local mx = dir.x * forward + rx * side
        local my = dir.y * forward + ry * side
        local mz = dir.z * forward
        -- Moving diagonally is not faster than moving straight.
        local length = math.sqrt(mx * mx + my * my + mz * mz)
        if length > 1 then mx, my, mz = mx / length, my / length, mz / length end
        p.x, p.y, p.z = p.x + mx * step, p.y + my * step, p.z + mz * step
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

-- God mode's extra layer: maximum resistance to every damage type, explosions included.
local godResistance = multiStatCheat("godResist", {
    { "ExplosionResistance", "Additive", 100 },
    { "PhysicalResistance", "Additive", 100 },
    { "ThermalResistance", "Additive", 100 },
    { "ElectricResistance", "Additive", 100 },
    { "ChemicalResistance", "Additive", 100 },
})

local CHEATS = {
    godMode = {
        label = "God Mode", remember = true,
        apply = function(on)
            setGodMode(on)
            pcall(godResistance, on)
        end,
        desc = "You take no damage from anything, explosions included, and your health is topped up constantly.",
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
    oneHit = {
        label = "One-Hit Kill",
        desc = "Any hostile enemy that takes damage dies instantly.",
    },
    autoLoot = {
        label = "Auto Loot",
        desc = "Automatically takes everything from enemies you have killed nearby.",
    },
    perfectAim = {
        label = "Perfect Aim",
        desc = "No weapon recoil and no bullet spread.",
        apply = multiStatCheat("perfectAim", {
            { "RecoilKickMin", "Multiplier", 0 },
            { "RecoilKickMax", "Multiplier", 0 },
            { "SpreadDefaultX", "Multiplier", 0 },
            { "SpreadDefaultY", "Multiplier", 0 },
        }),
    },
    instantHacks = {
        label = "Free Instant Quickhacks",
        desc = "Quickhacks cost no RAM and cyberware has no cooldown.",
        apply = multiStatCheat("instantHacks", {
            { "MemoryCostReduction", "Additive", 100 },
            { "QuickhacksCooldownReduction", "Additive", 100 },
            { "CyberwareCooldownReduction", "Additive", 100 },
        }),
    },
    rapidRecharge = {
        label = "Rapid Item Recharge",
        desc = "Max-Doc, grenades and Berserk recharge almost instantly.",
        apply = multiStatCheat("rapidRecharge", {
            { "HealingItemsChargesRegenRate", "Additive", 100 },
            { "GrenadesChargesRegenRate", "Additive", 100 },
            { "BerserkChargesRegenRate", "Additive", 100 },
        }),
    },
    cheapVendors = {
        label = "Vendor Discounts",
        desc = "Vendors charge you far less and pay more for what you sell.",
        apply = multiStatCheat("cheapVendors", {
            { "VendorBuyPriceDiscount", "Additive", 0.9 },
            { "VendorSellPriceDiscount", "Additive", 1.0 },
        }),
    },
    freezeClock = {
        label = "Freeze Time Of Day",
        desc = "The in-game clock stops, so it stays day or night.",
        apply = function(on) Game.GetTimeSystem():SetPausedState(on, CName.new(REASON)) end,
    },
    autoSkip = {
        label = "Auto Skip Cutscenes",
        desc = "Presses your skip key (Y) for you during cutscenes and dialogue. Needs the launcher's skip helper.",
        apply = function(on)
            if on then
                if skipHelperRunning() then return "Auto Skip ON - the skip helper is running" end
                return "Auto Skip ON - now start the skip helper with the launcher's PLAY button"
            end
            writeSkipFlag(false)
            pcall(stopFastForward)
        end,
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
        label = "No Fall Damage",
        apply = multiStatCheat("noFall", {
            { "FallDamageReduction", "Additive", 100 },
            { "HasSuperheroFall", "Additive", 1 },
        }),
        desc = "Drop from any height without getting hurt. A watchdog also undoes any health lost in a fall.",
    },
    alwaysCrit = {
        label = "Always Crit", apply = statCheat("alwaysCrit", "CritChance", "Additive", 100),
        desc = "Every hit is a critical hit.",
    },
    megaCrit = {
        label = "Mega Crit Damage",
        apply = multiStatCheat("megaCrit", {
            { "CritDamage", "Additive", 1000 },
            { "CritDamageBonus", "Additive", 1000 },
        }),
        desc = "Critical hits deal +1000% damage.",
    },
    tankArmor = {
        label = "Tank Armor", apply = statCheat("tankArmor", "Armor", "Additive", 10000),
        desc = "Adds 10,000 armor.",
    },
    invisible = {
        label = "Invisible",
        apply = function(on)
            getPlayer():SetInvisible(on)
            if on then pcall(dropAggro) end
        end,
        desc = "Enemies cannot see you, and ones already chasing you lose track of you.",
    },
    slowMo = {
        label = "Slow Motion", apply = function(on) setGameSpeed(on and 0.25 or 1.0) end,
        desc = "The world runs at quarter speed.",
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

-- Every cheat is remembered between sessions except Fly Mode, which would
-- drop you from the sky after loading.
for key, cheat in pairs(CHEATS) do
    NCT[key] = false
    if cheat.remember == nil then cheat.remember = key ~= "fly" end
end

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
    NCT.movementOn = false
    setStatMod("speed")
    setStatMod("jump")
    setStatMod("carry")
end

local function applyMovement()
    setStatMod("speed", gamedataStatType.MaxSpeed, gameStatModifierType.Multiplier,
        NCT.speedMult > 1.0 and NCT.speedMult or nil)
    setStatMod("jump", gamedataStatType.JumpHeight, gameStatModifierType.Multiplier,
        NCT.jumpMult > 1.0 and NCT.jumpMult or nil)
    setStatMod("carry", gamedataStatType.CarryCapacity, gameStatModifierType.Additive,
        NCT.carryBonus > 0 and NCT.carryBonus or nil)
    NCT.movementOn = NCT.speedMult > 1.0 or NCT.jumpMult > 1.0 or NCT.carryBonus > 0
end

local function applyCyberwareCapacity()
    setStatMod("cwCapacity", gamedataStatType.Humanity, gameStatModifierType.Additive,
        NCT.cwCapacity > 0 and NCT.cwCapacity or nil)
    NCT.cwOn = NCT.cwCapacity > 0
end

local function applyXpMultiplier()
    setStatMod("xpMult", gamedataStatType.XPbonusMultiplier, gameStatModifierType.Additive,
        NCT.xpMult > 1 and (NCT.xpMult - 1) or nil)
    NCT.xpOn = NCT.xpMult > 1
end

local function applyGameSpeed(speed)
    NCT.gameSpeed = speed
    NCT.speedOn = math.abs(speed - 1.0) > 0.01
    setGameSpeed(speed)
end

local function applyFov()
    local camera = fppCamera()
    -- Remember the game's own value before the first change so Reset can restore it.
    if not NCT.fovOn and NCT.fovDefault == 0 then
        local ok, current = pcall(function() return camera:GetFOV() end)
        if ok and type(current) == "number" and current > 0 then NCT.fovDefault = current end
    end
    camera:SetFOV(NCT.fovValue)
    NCT.fovOn = true
end

local function resetFov()
    fppCamera():SetFOV(NCT.fovDefault > 0 and NCT.fovDefault or 68)
    NCT.fovOn = false
end

-- Re-applies every slider setting that was switched on, e.g. after a restart.
local function applyNumericSettings()
    if NCT.fovOn then pcall(applyFov) end
    if NCT.movementOn then pcall(applyMovement) end
    if NCT.cwOn then pcall(applyCyberwareCapacity) end
    if NCT.xpOn then pcall(applyXpMultiplier) end
    if NCT.speedOn then pcall(setGameSpeed, NCT.gameSpeed) end
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
        applyCyberwareCapacity()
    end)
    pcall(function() applyGameSpeed(1.0) end)
    pcall(function()
        NCT.xpMult = 1
        applyXpMultiplier()
    end)
    pcall(function() if NCT.fovOn then resetFov() end end)
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
    { "SOLO", "Perfect aim, guaranteed crits, one-hit kills and endless ammo.",
        { "perfectAim", "alwaysCrit", "megaCrit", "oneHit", "infAmmo" } },
    { "NETRUNNER", "Free instant quickhacks, endless RAM and fast item recharge.",
        { "instantHacks", "infRam", "rapidRecharge" } },
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
-- Profiles: three save slots for your own set of cheats and slider settings.
---------------------------------------------------------------------------

local NUMERIC_KEYS = { "speedMult", "jumpMult", "carryBonus", "cwCapacity", "xpMult", "gameSpeed" }
local PROFILE_SLOTS = 3

local function captureProfile(index)
    local profile = { name = "Profile " .. index, cheats = {}, numbers = {} }
    for key in pairs(CHEATS) do
        if NCT[key] and key ~= "fly" then profile.cheats[#profile.cheats + 1] = key end
    end
    table.sort(profile.cheats)
    for _, field in ipairs(NUMERIC_KEYS) do profile.numbers[field] = NCT[field] end
    return profile
end

local function loadProfile(profile)
    local wanted = {}
    for _, key in ipairs(profile.cheats) do wanted[key] = true end
    -- Switch off whatever the profile does not use, then switch its cheats on.
    for key, cheat in pairs(CHEATS) do
        if NCT[key] and not wanted[key] then
            if cheat.apply then pcall(cheat.apply, false) end
            NCT[key] = false
        end
    end
    for _, key in ipairs(profile.cheats) do
        local cheat = CHEATS[key]
        if cheat and not NCT[key] then
            local ok = true
            if cheat.apply then ok = pcall(cheat.apply, true) end
            if ok then NCT[key] = true end
        end
    end
    for _, field in ipairs(NUMERIC_KEYS) do
        if type(profile.numbers[field]) == "number" then NCT[field] = profile.numbers[field] end
    end
    pcall(applyMovement)
    pcall(applyCyberwareCapacity)
    pcall(applyXpMultiplier)
    pcall(function() applyGameSpeed(NCT.gameSpeed) end)
    return "Loaded " .. profile.name .. " (" .. #profile.cheats .. " cheats)"
end

---------------------------------------------------------------------------
-- Settings file (kept next to this script)
---------------------------------------------------------------------------

-- Writes every setting and active cheat to disk, but only when something
-- changed since the last write. Called every few seconds, when the menu
-- closes and when the game shuts down, so nothing is lost on a crash.
local function saveSettings()
    local data = { spots = NCT.spots, profiles = NCT.profiles, checklist = NCT.checklist, active = {} }
    for _, field in ipairs(SAVED_FIELDS) do data[field] = NCT[field] end
    local keys = {}
    for key, cheat in pairs(CHEATS) do
        if cheat.remember and NCT[key] then keys[#keys + 1] = key end
    end
    table.sort(keys)
    data.active = keys

    local ok, text = pcall(json.encode, data)
    if not ok or text == NCT.lastSaved then return end
    pcall(function()
        local file = io.open("settings.json", "w")
        if file then
            file:write(text)
            file:close()
            NCT.lastSaved = text
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
    if type(data.checklist) == "table" then
        for item, entry in pairs(data.checklist) do
            if type(item) == "string" and type(entry) == "table" then
                NCT.checklist[item] = {
                    state = (entry.state == "ok" or entry.state == "bad" or entry.state == "skip") and entry.state or nil,
                    note = type(entry.note) == "string" and entry.note or "",
                }
            end
        end
    end
    if type(data.profiles) == "table" then
        for i = 1, PROFILE_SLOTS do
            local p = data.profiles[i]
            NCT.profiles[i] = false
            if type(p) == "table" and type(p.cheats) == "table" and type(p.numbers) == "table" then
                local clean = { name = tostring(p.name or ("Profile " .. i)), cheats = {}, numbers = {} }
                for _, key in ipairs(p.cheats) do
                    if CHEATS[key] then clean.cheats[#clean.cheats + 1] = key end
                end
                for _, field in ipairs(NUMERIC_KEYS) do
                    if type(p.numbers[field]) == "number" then clean.numbers[field] = p.numbers[field] end
                end
                NCT.profiles[i] = clean
            end
        end
    end
    if NCT.rememberCheats then
        NCT.pendingRestore = type(data.active) == "table" and data.active or {}
    else
        NCT.movementOn, NCT.cwOn, NCT.xpOn, NCT.speedOn = false, false, false, false
    end
end

-- Switches remembered cheats and slider settings back on once a save is
-- loaded. Anything the game isn't ready for yet is retried a few times.
local function restoreCheats()
    NCT.restoreTries = (NCT.restoreTries or 0) + 1
    local restored, remaining = 0, {}
    for _, key in ipairs(NCT.pendingRestore) do
        local cheat = CHEATS[key]
        if cheat and cheat.remember and not NCT[key] then
            local ok = true
            if cheat.apply then ok = pcall(cheat.apply, true) end
            if ok then
                NCT[key] = true
                restored = restored + 1
            else
                remaining[#remaining + 1] = key
            end
        end
    end
    applyNumericSettings()
    if #remaining > 0 and NCT.restoreTries < 6 then
        NCT.pendingRestore = remaining
    else
        NCT.pendingRestore = nil
        NCT.restoreTries = 0
    end
    if restored > 0 then
        toast("Restored " .. restored .. " cheat" .. (restored == 1 and "" or "s") .. " from last session", true)
    end
end

-- Loading another save creates a new player and wipes every stat change, so
-- everything that was on is queued to be switched on again.
local function onNewSave()
    -- Keep anything already waiting: a death and the reload after it both call this.
    local keys, queued = {}, {}
    for _, key in ipairs(NCT.pendingRestore or {}) do
        keys[#keys + 1] = key
        queued[key] = true
    end
    for key in pairs(CHEATS) do
        if NCT[key] then
            if not queued[key] then keys[#keys + 1] = key end
            NCT[key] = false
        end
    end
    NCT.mods = {}
    NCT.flyPos = nil
    NCT.fall = nil
    NCT.fallShield = nil
    NCT.mountCache = nil
    NCT.restoreTries = 0
    NCT.pendingRestore = keys
end

-- Stat-based cheats are re-applied every few seconds, so if the game ever drops
-- a modifier (a respawn, a scripted scene) it comes straight back.
local function reassertStatCheats()
    for key, cheat in pairs(CHEATS) do
        if NCT[key] and cheat.apply then
            local owned = false
            for modKey in pairs(NCT.mods) do
                if modKey:sub(1, #key) == key then
                    owned = true
                    break
                end
            end
            if owned then pcall(cheat.apply, true) end
        end
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
local canDraw -- defined with the switch widget below

-- Animation state shared by the menu: frame time, the sliding sidebar
-- highlight, and when the current page was opened.
local anim = { last = os.clock(), dt = 0, navY = nil, pageAt = 0, pageName = nil }

local function u32(c, alpha)
    return ImGui.GetColorU32(c[1], c[2], c[3], alpha == nil and (c[4] or 1) or alpha)
end

local function easeOut(t)
    t = math.max(0, math.min(1, t))
    return 1 - (1 - t) ^ 3
end

local function fillRect(dl, x1, y1, x2, y2, color, rounding)
    ImGui.ImDrawListAddRectFilled(dl, x1, y1, x2, y2, color, rounding or 0)
end

local function gradientRect(dl, x1, y1, x2, y2, left, right)
    if x2 <= x1 or y2 <= y1 then return end
    if not pcall(ImGui.ImDrawListAddRectFilledMultiColor, dl, x1, y1, x2, y2, left, right, right, left) then
        fillRect(dl, x1, y1, x2, y2, left)
    end
end

local function hline(dl, x1, x2, y, color, thickness)
    if not pcall(ImGui.ImDrawListAddLine, dl, x1, y, x2, y, color, thickness or 1) then
        fillRect(dl, x1, y, x2, y + (thickness or 1), color)
    end
end

local function textWidth(text)
    local w = ImGui.CalcTextSize(text)
    return w
end

-- Section title: a yellow tick, the title in cyan, and a fine rule to the edge.
local function section(title)
    if not firstSection then
        ImGui.Dummy(0, em(0.5))
    end
    firstSection = false
    local upper = string.upper(title)
    local fancy = canDraw and canDraw() and pcall(function()
        local dl = ImGui.GetWindowDrawList()
        local x, y = ImGui.GetCursorScreenPos()
        local w = availWidth()
        local fh = ImGui.GetFontSize()
        fillRect(dl, x, y + 2, x + 3, y + fh - 1, u32(C.yellow), 1)
        local tw = textWidth(upper)
        hline(dl, x + em(0.6) + tw + em(0.7), x + w, y + fh / 2 + 1, u32(C.cyan, 0.18), 1)
        ImGui.SetCursorScreenPos(x + em(0.6), y)
        textColored(C.cyan, upper)
        ImGui.Dummy(0, em(0.15))
    end)
    if not fancy then
        textColored(C.cyan, upper)
        ImGui.Separator()
    end
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

function canDraw()
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
    local x, y = ImGui.GetCursorScreenPos()
    ImGui.PushStyleColor(ImGuiCol.ChildBg, C.panel[1], C.panel[2], C.panel[3], 1)
    ImGui.BeginChild("##tile_" .. id, width, em(4.6), true, ImGuiWindowFlags.NoScrollbar)
    textColored(C.dim, label)
    textColored(C.yellow, value)
    ImGui.EndChild()
    ImGui.PopStyleColor(1)
    if canDraw() then
        pcall(function()
            local dl = ImGui.GetWindowDrawList()
            gradientRect(dl, x + 2, y, x + width - 2, y + 2, u32(C.yellow), u32(C.cyan, 0.6))
        end)
    end
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

-- Style and convenience helpers, used by the Home, World and Style pages.
local function saveUserSettings()
    pcall(function()
        GetSingleton("inkMenuScenario"):GetSystemRequestsHandler():RequestSaveUserSettings()
    end)
end

local function settingLabel(var)
    local label = nil
    pcall(function()
        local text = Game.GetLocalizedTextByKey(var:GetDisplayName())
        if type(text) == "string" and text ~= "" then label = text end
    end)
    if not label then
        pcall(function()
            local text = Game.GetLocalizedText(var:GetDisplayName().value)
            if type(text) == "string" and text ~= "" then label = text end
        end)
    end
    if not label then
        pcall(function() label = var:GetName().value end)
    end
    return label or "Setting"
end

-- Every on/off option in a settings group, read fresh about once a second.
local settingsCache = {}

local function boolSettings(path)
    local cached = settingsCache[path]
    if cached and os.clock() - cached.time < 1 then return cached.list end
    local list = {}
    pcall(function()
        local group = Game.GetSettingsSystem():GetGroup(path)
        for _, var in ipairs(group:GetVars(false)) do
            local ok, value = pcall(function() return var:GetValue() end)
            if ok and type(value) == "boolean" then
                list[#list + 1] = { var = var, label = settingLabel(var) }
            end
        end
    end)
    settingsCache[path] = { time = os.clock(), list = list }
    return list
end

local function setBoolGroup(path, value)
    local list = boolSettings(path)
    if #list == 0 then error("the game has no settings under " .. path) end
    for _, entry in ipairs(list) do pcall(function() entry.var:SetValue(value) end) end
    settingsCache[path] = nil
    saveUserSettings()
end

local function hudVisible()
    for _, entry in ipairs(boolSettings("/interface/hud")) do
        local ok, value = pcall(function() return entry.var:GetValue() end)
        if ok and value then return true end
    end
    return false
end

local function toggleHud()
    local show = not hudVisible()
    setBoolGroup("/interface/hud", show)
    return show and "HUD shown" or "HUD hidden"
end

local function quickSave()
    GetSingleton("inkMenuScenario"):GetSystemRequestsHandler():QuickSave()
    return "Quick save requested"
end

-- Moves the clock forward, for shops that are closed or quests that wait.
local function skipHours(hours)
    local timeSystem = Game.GetTimeSystem()
    local now = timeSystem:GetGameTimeStamp()
    timeSystem:SetGameTimeBySeconds(math.floor(now + hours * 3600))
    return "Skipped " .. hours .. (hours == 1 and " hour" or " hours")
end

-- Removes burning, bleeding, poison, shock and every other debuff.
local function cureDebuffs()
    local player = getPlayer()
    local cured = pcall(function() StatusEffectHelper.RemoveStatusEffectsWithTag(player, CName.new("Debuff"), 0) end)
    if not cured then
        cured = pcall(function()
            StatusEffectHelper.RemoveStatusEffectsWithTag(GetGameInstance(), player:GetEntityID(), CName.new("Debuff"))
        end)
    end
    if not cured then error("the game would not remove the effects") end
    return "Every debuff removed"
end

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
    if button("Repair & Call Car", w) then
        run("Repair vehicle", reviveVehicle)
    end
    if button("Quick Save", w) then
        run("Quick save", quickSave)
    end
    ImGui.SameLine()
    if button("Cure All Debuffs", w) then
        run("Cure debuffs", cureDebuffs)
    end
    ImGui.SameLine()
    if button("Toggle HUD", w) then
        run("Toggle HUD", toggleHud)
    end

    section("Profiles")
    hint("Save your current cheats and sliders in a slot, then bring them all back with one click.")
    for i = 1, PROFILE_SLOTS do
        local profile = NCT.profiles[i]
        if profile then
            textColored(C.text, profile.name .. "  (" .. #profile.cheats .. " cheats)")
        else
            textColored(C.dim, "Profile " .. i .. "  (empty)")
        end
        local bw = columnWidth(3)
        if profile then
            if primaryButton("LOAD##prof" .. i, bw) then
                run("Load profile", function() return loadProfile(profile) end)
            end
        elseif button("Load##prof" .. i, bw) then
            toast("Profile " .. i .. " is empty. Save to it first.", false)
        end
        ImGui.SameLine()
        if button("Save Current##prof" .. i, bw) then
            NCT.profiles[i] = captureProfile(i)
            saveSettings()
            toast("Saved your current setup to Profile " .. i, true)
        end
        ImGui.SameLine()
        if button("Clear##prof" .. i, bw) then
            NCT.profiles[i] = false
            saveSettings()
            toast("Profile " .. i .. " cleared", true)
        end
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

    section("Camera")
    local fovApply
    NCT.fovValue, fovApply = sliderFloat("fov", "Field of view", NCT.fovValue, 50, 130, "%.0f", "SET")
    if fovApply then
        run("Field of view " .. math.floor(NCT.fovValue), applyFov)
    end
    if button("Reset Field Of View", availWidth()) then
        run("Field of view reset", resetFov)
    end
    hint("The game may reset the view while you aim down sights. It is re-applied every couple of seconds.")

    section("Movement")
    NCT.speedMult = sliderFloat("speed", "Run speed", NCT.speedMult, 1.0, 5.0, "x%.1f")
    NCT.jumpMult = sliderFloat("jump", "Jump height", NCT.jumpMult, 1.0, 10.0, "x%.1f")
    NCT.carryBonus = sliderInt("carry", "Extra carry weight", NCT.carryBonus, 0, 5000)

    local w = columnWidth(2)
    if primaryButton("APPLY MOVEMENT", w) then
        run("Movement applied", applyMovement)
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
    cheatToggle("oneHit")

    section("Loot")
    cheatToggle("autoLoot")
    NCT.lootRadius = sliderInt("lootradius", "Loot radius in metres", NCT.lootRadius, 3, 50)
    hint("Takes everything from dead enemies within that distance, once per body.")

    section("Defense")
    cheatToggle("tankArmor", "Tank Armor  (+10,000)")
    cheatToggle("invisible", "Invisible To Enemies")
    cheatToggle("slowMo", "Slow Motion  (25% speed)")

    section("Cyberware")
    local apply
    NCT.cwCapacity, apply = sliderInt("cw", "Extra cyberware capacity", NCT.cwCapacity, 0, 1000, "SET")
    if apply then
        run("Cyberware capacity +" .. NCT.cwCapacity, applyCyberwareCapacity)
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

---------------------------------------------------------------------------
-- Progression helpers: skills, crafting recipes, weapon upgrades
---------------------------------------------------------------------------

-- Skill names as shown in the game, with the game's internal names.
local SKILL_NAMES = {
    { "Headhunter", "CoolSkill" },
    { "Netrunner", "IntelligenceSkill" },
    { "Shinobi", "ReflexesSkill" },
    { "Solo", "StrengthSkill" },
    { "Engineer", "TechnicalAbilitySkill" },
}

local function craftingSystem()
    local system = Game.GetScriptableSystemsContainer():Get(CName.new("CraftingSystem"))
    if not system then error("crafting system not found") end
    return system
end

-- Long jobs run in small slices so the game never freezes.
local function startJob(label, list, fn, onDone)
    NCT.job = { label = label, list = list, fn = fn, onDone = onDone, index = 1, done = 0, failed = 0 }
end

local function stepJob()
    local job = NCT.job
    if not job then return end
    if not getPlayer() then
        NCT.job = nil
        return
    end
    local last = math.min(job.index + 59, #job.list)
    for i = job.index, last do
        local ok, changed = pcall(job.fn, job.list[i])
        if not ok then
            job.failed = job.failed + 1
        elseif changed then
            job.done = job.done + 1
        end
    end
    job.index = last + 1
    if job.index > #job.list then
        local text = job.label .. ": " .. job.done .. " added"
        if job.failed > 0 then text = text .. " (" .. job.failed .. " skipped)" end
        toast(text, job.done > 0 or job.failed == 0)
        NCT.job = nil
        if job.onDone then pcall(job.onDone) end
    end
end

-- Teaches every crafting recipe in the game, iconic ones included.
local function unlockAllRecipes(onDone)
    if NCT.job then error("another job is still running") end
    local records = TweakDB:GetRecords("gamedataItemRecipe_Record")
    if type(records) ~= "table" or #records == 0 then error("the game would not list its recipes") end
    local book = craftingSystem():GetPlayerCraftBook()
    local targets = {}
    for _, record in ipairs(records) do
        local ok, target = pcall(function() return record:CraftingResult():Item():GetID() end)
        targets[#targets + 1] = ok and target or record:GetID()
    end
    startJob("Recipes", targets, function(target)
        if book:KnowsRecipe(target) then return false end
        book:AddRecipe(target, {}, 1)
        return true
    end, onDone)
    return "Unlocking " .. #targets .. " recipes..."
end

-- The materials an upgrade can need, handed over first so upgrades are free.
local UPGRADE_MATERIALS = {
    "Items.CommonMaterial1", "Items.UncommonMaterial1", "Items.RareMaterial1",
    "Items.EpicMaterial1", "Items.LegendaryMaterial1",
}

local function heldWeaponId()
    local item = Game.GetTransactionSystem():GetItemInSlot(getPlayer(), TweakDBID.new("AttachmentSlots.WeaponRight"))
    if not item then error("hold a weapon in your hands first") end
    return item:GetItemID()
end

local function upgradeHeldWeapon(times)
    local id = heldWeaponId()
    for _, name in ipairs(UPGRADE_MATERIALS) do pcall(giveItem, name, 300 * times) end
    local crafting = craftingSystem()
    for _ = 1, times do
        local ok = pcall(function() crafting:UpgradeItem(getPlayer(), id) end)
        if not ok then
            local request = UpgradeItemRequest.new()
            request.owner = getPlayer()
            request.itemID = id
            crafting:QueueRequest(request)
        end
    end
    return "Upgrade x" .. times .. " sent - check the weapon's tier in your inventory"
end

local function addSkillXp(amount)
    local reason = gainReason()
    local given = 0
    for _, skill in ipairs(SKILL_NAMES) do
        if pcall(function()
            devData():AddExperience(amount, gamedataProficiencyType[skill[2]], reason, false)
        end) then given = given + 1 end
    end
    if given == 0 then error("the game would not add skill experience") end
    return "Gave " .. formatNumber(amount) .. " XP to " .. given .. " skills"
end

-- Everything in the player's inventory, as the game's item data objects.
local function inventoryItems()
    local ok, a, b = pcall(function() return Game.GetTransactionSystem():GetItemList(getPlayer()) end)
    local list = ok and (type(a) == "table" and a or b) or nil
    if type(list) ~= "table" then error("the game would not list your inventory") end
    return list
end

local function itemTdbid(itemId)
    local ok, tdb = pcall(function() return itemId.id end)
    if ok and tdb then return tdb end
    return ItemID.GetTDBID(itemId)
end

local function hasTag(data, tag)
    local ok, value = pcall(function() return data:HasTag(CName.new(tag)) end)
    return ok and value == true
end

-- Upgrades every piece of cyberware you own, without a ripperdoc. Money and
-- materials are handed over first so the upgrades cost nothing.
local function upgradeAllCyberware()
    local crafting = craftingSystem()
    local player = getPlayer()
    pcall(giveItem, "Items.money", 500000)
    for _, name in ipairs(UPGRADE_MATERIALS) do pcall(giveItem, name, 2000) end
    local count = 0
    for _, data in ipairs(inventoryItems()) do
        if hasTag(data, "Cyberware") then
            local id = data:GetID()
            for _ = 1, 5 do
                if not pcall(function() crafting:UpgradeItem(player, id) end) then
                    pcall(function()
                        local request = UpgradeItemRequest.new()
                        request.owner = player
                        request.itemID = id
                        crafting:QueueRequest(request)
                    end)
                end
            end
            count = count + 1
        end
    end
    if count == 0 then error("no cyberware found in your inventory") end
    return "Upgrades sent for " .. count .. " cyberware items - check their tier in your inventory"
end

local function perkTypes()
    local records = TweakDB:GetRecords("gamedataNewPerk_Record")
    if type(records) ~= "table" or #records == 0 then error("the game would not list its perks") end
    local types = {}
    for _, record in ipairs(records) do
        local ok, perkType = pcall(function() return record:Type() end)
        if ok and perkType ~= nil then types[#types + 1] = perkType end
    end
    if #types == 0 then error("could not read the perk list") end
    return types
end

local function perkLevel(data, perkType)
    local level = data:IsNewPerkBought(perkType)
    if type(level) == "boolean" then return level and 1 or 0 end
    return tonumber(level) or 0
end

-- Buys every perk to its highest level, relic perks included. Attributes are
-- maxed and plenty of points handed over first, because perks require both.
local function maxAllPerks(onDone)
    if NCT.job then error("another job is still running") end
    local types = perkTypes()
    pcall(maxAttributes)
    pcall(addDevPoints, "Primary", 1000, "perk")
    pcall(addDevPoints, "Espionage", 100, "relic")
    -- Three passes, so perks that need a parent perk get bought after it.
    local list = {}
    for _ = 1, 3 do
        for _, perkType in ipairs(types) do list[#list + 1] = perkType end
    end
    startJob("Perks", list, function(perkType)
        local data = devData()
        local maxLevel = 1
        pcall(function() maxLevel = data:GetNewPerkMaxLevel(perkType) end)
        local before = perkLevel(data, perkType)
        local level = before
        for _ = 1, maxLevel do
            if level >= maxLevel then break end
            pcall(function() data:UnlockNewPerk(perkType) end)
            data:BuyNewPerk(perkType, true)
            local now = perkLevel(data, perkType)
            if now <= level then break end
            level = now
        end
        return level > before
    end, onDone)
    return "Buying every perk..."
end

-- One button for everything: level, street cred, skills, attributes, cyberware,
-- capacity, then every perk, then every recipe.
local function maxEverything()
    if NCT.job then error("another job is still running") end
    pcall(setProficiency, "Level", 60)
    pcall(setProficiency, "StreetCred", 50)
    pcall(maxSkills)
    pcall(function()
        NCT.cwCapacity = math.max(NCT.cwCapacity, 300)
        applyCyberwareCapacity()
    end)
    pcall(upgradeAllCyberware)
    maxAllPerks(function() pcall(unlockAllRecipes) end)
    return "Maxing everything: level, cred, skills, attributes, cyberware, then every perk and recipe..."
end

-- Refunds spent perk or attribute points, and reports how many points you have now.
local function respec(kind)
    local data = devData()
    local pointType = kind == "attributes" and "Attribute" or "Primary"
    local before = getDevPoints(pointType)
    if kind == "attributes" then
        if not pcall(function() data:ResetAttributes() end) then
            error("this game version has no attribute reset")
        end
    elseif not pcall(function() data:ResetPerks() end) then
        if not pcall(function() data:RemoveAllPerks() end) then
            error("this game version has no perk reset")
        end
    end
    local after = getDevPoints(pointType)
    local name = kind == "attributes" and "Attribute" or "Perk"
    if after > before then
        return name .. " points refunded: " .. before .. " -> " .. after
    end
    return name .. " reset requested - check the character menu"
end

local function drawProgressPage()
    local info = NCT.info or {}
    local apply

    section("One Click")
    if primaryButton("MAX OUT EVERYTHING", availWidth()) then
        run("Max out everything", maxEverything)
    end
    hint("Level 60, street cred 50, every skill 60, every attribute 20, every perk, every cyberware "
        .. "upgraded, +300 cyberware capacity and every crafting recipe.")
    local oneJob = NCT.job
    if oneJob then
        textColored(C.cyan, string.format("%s...  %d of %d", oneJob.label,
            math.min(oneJob.index - 1, #oneJob.list), #oneJob.list))
        pcall(ImGui.ProgressBar, (oneJob.index - 1) / #oneJob.list, availWidth(), em(1))
    end
    local pw2 = columnWidth(2)
    if button("Max All Perks", pw2) then
        run("Max all perks", function() return maxAllPerks() end)
    end
    ImGui.SameLine()
    if button("Upgrade All Cyberware", pw2) then
        run("Upgrade cyberware", upgradeAllCyberware)
    end

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
        run("XP multiplier x" .. NCT.xpMult, applyXpMultiplier)
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

    local lw = columnWidth(2)
    if button("Level Up  (+1)", lw) then
        run("Level up", function()
            local target = math.min(getProficiency("Level") + 1, 60)
            if setProficiency("Level", target) then return "Level " .. target end
            return "Level change requested - check the character menu"
        end)
    end
    ImGui.SameLine()
    if button("Street Cred Up  (+1)", lw) then
        run("Street cred up", function()
            local target = math.min(getProficiency("StreetCred") + 1, 50)
            if setProficiency("StreetCred", target) then return "Street cred " .. target end
            return "Street cred change requested - check the character menu"
        end)
    end

    section("Skills")
    NCT.skillValue = sliderInt("skillval", "Set skill to", NCT.skillValue, 1, 60)
    local sw = columnWidth(#SKILL_NAMES)
    for i, skill in ipairs(SKILL_NAMES) do
        if button(skill[1] .. "##skill", sw) then
            run("Set " .. skill[1], function()
                if setProficiency(skill[2], NCT.skillValue) then
                    return skill[1] .. " set to " .. NCT.skillValue
                end
                return skill[1] .. " change requested - check the character menu"
            end)
        end
        if i < #SKILL_NAMES then ImGui.SameLine() end
    end
    local kw = columnWidth(2)
    if button("+5,000 XP To Every Skill", kw) then
        run("Skill XP", function() return addSkillXp(5000) end)
    end
    ImGui.SameLine()
    if button("Max All Skills  (60)", kw) then
        run("Max all skills", function()
            if maxSkills() then return "All 5 skills set to 60" end
            return "Skill changes requested - check the character menu"
        end)
    end
    hint("Skill levels unlock the skill's passive bonuses, like the game's own skill progression.")

    section("Crafting & Gear")
    if primaryButton("UNLOCK ALL CRAFTING RECIPES", availWidth()) then
        run("Unlock recipes", function() return unlockAllRecipes() end)
    end
    local job = NCT.job
    if job then
        textColored(C.cyan, string.format("%s...  %d of %d", job.label, math.min(job.index - 1, #job.list), #job.list))
        pcall(ImGui.ProgressBar, (job.index - 1) / #job.list, availWidth(), em(1))
    end
    local uw = columnWidth(2)
    if button("Upgrade Held Weapon  (+1)", uw) then
        run("Upgrade weapon", function() return upgradeHeldWeapon(1) end)
    end
    ImGui.SameLine()
    if button("Max Upgrade Held Weapon", uw) then
        run("Upgrade weapon", function() return upgradeHeldWeapon(10) end)
    end
    hint("Upgrades the weapon in your hands for free: the materials are handed to you first.")

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

    section("Free Respec")
    local rw = columnWidth(2)
    if button("Reset Perks", rw) then
        run("Reset perks", function() return respec("perks") end)
    end
    ImGui.SameLine()
    if button("Reset Attributes", rw) then
        run("Reset attributes", function() return respec("attributes") end)
    end
    hint("Refunds your points so you can spend them again, at no cost.")
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
    textColored(C.dim, "Skip time")
    local tw = columnWidth(4)
    for i, hours in ipairs({ 1, 3, 6, 12 }) do
        if button("+" .. hours .. "h##skiptime", tw) then
            run("Skip time", function() return skipHours(hours) end)
        end
        if i < 4 then ImGui.SameLine() end
    end

    section("Cutscenes")
    cheatToggle("autoSkip", "Auto Skip Cutscenes  (presses Y)")
    if NCT.autoSkip then
        if NCT.helperRunning then
            textColored(C.green, "Skip helper is running.")
        else
            textColored(C.red, "Skip helper is NOT running. Press PLAY in the launcher to start it.")
        end
        textColored(C.dim, NCT.sceneActive and "A scene is playing right now." or "No scene is playing.")
        local seen = NCT.sceneInfo
        if seen then
            local function yesNo(value)
                if value == nil then return "unknown" end
                return value and "yes" or "no"
            end
            textColored(C.dim, string.format("Skip prompt on screen: %s   Scene level: %s   Skippable: %s",
                yesNo(seen.prompt), tostring(seen.tier or "unknown"), yesNo(seen.allowed)))
        end
    end
    textColored(C.dim, "Skip speed")
    local sw = columnWidth(3)
    local speeds = { { 1, "Balanced" }, { 2, "Fast" }, { 3, "Insane" } }
    for i, entry in ipairs(speeds) do
        local label = entry[2] .. "##skipspeed"
        if NCT.skipSpeed == entry[1] then
            primaryButton(label, sw)
        elseif button(label, sw) then
            NCT.skipSpeed = entry[1]
            toast("Skip speed: " .. entry[2], true)
        end
        if i < #speeds then ImGui.SameLine() end
    end
    hint("Balanced holds the key for a while. Insane taps it as fast as the game can read it.")
    hint("The launcher's skip helper presses Y whenever a cutscene or dialogue is playing. "
        .. "It only presses while Cyberpunk 2077 is the active window, and only while this switch is on.")

    NCT.gameSpeed, apply = sliderFloat("gspeed", "Game speed", NCT.gameSpeed, 0.1, 3.0, "x%.2f", "SET")
    if apply then
        NCT.slowMo = false
        run(string.format("Game speed x%.2f", NCT.gameSpeed), function() applyGameSpeed(NCT.gameSpeed) end)
    end
    local gw = columnWidth(2)
    if button("Back To Normal Speed", gw) then
        NCT.slowMo = false
        run("Game speed normal", function() applyGameSpeed(1.0) end)
    end
    ImGui.SameLine()
    if button("Freeze World", gw) then
        NCT.slowMo = false
        run("World frozen", function() applyGameSpeed(0.02) end)
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
    textColored(C.dim, "Set wanted level")
    local pw = columnWidth(5)
    for level = 1, 5 do
        if button(level .. " Star##wanted" .. level, pw) then
            run("Wanted level " .. level, function()
                setWanted(level)
                return "Wanted level set to " .. level
            end)
        end
        if level < 5 then ImGui.SameLine() end
    end
    hint("Turn Disable Police off first, or the police will ignore the new level.")
end

---------------------------------------------------------------------------
-- Shop: browse every item the game has, search it, and add or buy it.
---------------------------------------------------------------------------

local SHOP_CATEGORIES = {
    { "Weapons", "gamedataWeaponItem_Record" },
    { "Clothing", "gamedataClothing_Record" },
    { "Grenades", "gamedataGrenade_Record" },
    { "Everything", "gamedataItem_Record" },
}

local SHOP = {
    cat = "Weapons",
    search = "",
    qty = 1,
    pay = false,
    limit = 60,
    lists = {},       -- category name -> list of items
    failed = {},      -- categories whose list could not be read
    build = nil,      -- item list currently being loaded
    bulk = nil,       -- bulk add currently running
    confirmBulk = false,
    filterKey = nil,
    filtered = {},
}

-- Test, NPC-only and internal items are hidden from the shop.
local function junkItem(id)
    local l = id:lower()
    return not l:find("^items%.") or l:find("npc") or l:find("items%.base_") or l:find("[_%.]test")
        or l:find("debug") or l:find("dummy") or l:find("_dev[_%.]") or l:find("^items%.q%d%d%d_test")
end

local function startShopBuild(catName, onDone)
    if SHOP.lists[catName] then
        if onDone then onDone(SHOP.lists[catName]) end
        return
    end
    if SHOP.build then
        toast("Still loading the item list, try again in a moment.", false)
        return
    end
    local className
    for _, c in ipairs(SHOP_CATEGORIES) do
        if c[1] == catName then className = c[2] end
    end
    local ok, records = pcall(function() return TweakDB:GetRecords(className) end)
    if not ok or type(records) ~= "table" or #records == 0 then
        SHOP.failed[catName] = true
        toast("Could not read the " .. catName .. " list from the game.", false)
        return
    end
    SHOP.build = { cat = catName, records = records, index = 1, entries = {}, onDone = onDone }
end

-- Loads the list in small slices so the game never freezes.
local function stepShopBuild()
    local job = SHOP.build
    if not job then return end
    local last = math.min(job.index + 149, #job.records)
    for i = job.index, last do
        pcall(function()
            local record = job.records[i]
            local id = TDBID.ToStringDEBUG(record:GetID())
            if type(id) ~= "string" or junkItem(id) then return end
            local name = Game.GetLocalizedTextByKey(record:DisplayName())
            if type(name) ~= "string" or name == "" or #name > 70 then return end
            local iconic = false
            pcall(function() iconic = record:IsIconic() == true end)
            if not iconic then
                pcall(function() iconic = record:TagsContains(CName.new("IconicWeapon")) == true end)
            end
            job.entries[#job.entries + 1] = {
                id = id, name = name, iconic = iconic, key = (name .. " " .. id):lower(),
            }
        end)
    end
    job.index = last + 1
    if job.index > #job.records then
        table.sort(job.entries, function(a, b)
            if a.name ~= b.name then return a.name < b.name end
            return a.id < b.id
        end)
        SHOP.lists[job.cat] = job.entries
        SHOP.filterKey = nil
        SHOP.build = nil
        toast("Loaded " .. #job.entries .. " " .. job.cat:lower() .. ".", true)
        if job.onDone then job.onDone(job.entries) end
    end
end

local function shopFiltered()
    local list = SHOP.lists[SHOP.cat]
    if not list then return nil end
    local key = SHOP.cat .. "|" .. SHOP.search:lower()
    if SHOP.filterKey == key then return SHOP.filtered end
    local words = {}
    for word in SHOP.search:lower():gmatch("%S+") do words[#words + 1] = word end
    local out = {}
    for _, entry in ipairs(list) do
        local match = true
        for _, word in ipairs(words) do
            if not entry.key:find(word, 1, true) then
                match = false
                break
            end
        end
        if match then out[#out + 1] = entry end
    end
    SHOP.filtered, SHOP.filterKey = out, key
    return out
end

-- The item's value as the game calculates it, or nil when it can't be read.
local function priceOf(itemId)
    local ok, price = pcall(function()
        local instance = GetGameInstance and GetGameInstance() or Game.GetGameInstance()
        return RPGManager.CalculateSellPrice(instance, getPlayer(), itemId)
    end)
    if ok and type(price) == "number" and price >= 0 then return math.floor(price) end
    return nil
end

local function itemPrice(id)
    return priceOf(itemID(id))
end

local function shopAdd(entry, qty)
    local cost = 0
    if SHOP.pay then
        local price = itemPrice(entry.id)
        if not price then error("this item's price can't be read - switch off Pay With Eddies") end
        cost = price * qty
        local money = itemCount("Items.money")
        if money < cost then
            error("not enough eddies: you need E$ " .. formatNumber(cost) .. " and have E$ " .. formatNumber(money))
        end
    end
    giveItemChecked(entry.id, qty)
    if cost > 0 then
        Game.GetTransactionSystem():RemoveItem(getPlayer(), itemID("Items.money"), cost)
        return "Bought " .. entry.name .. " for E$ " .. formatNumber(cost)
    end
    return "Added " .. entry.name .. (qty > 1 and (" x" .. qty) or "")
end

local function startBulk(label, ids)
    SHOP.bulk = { label = label, ids = ids, index = 1, given = 0, failed = 0 }
end

local function stepBulk()
    local job = SHOP.bulk
    if not job then return end
    if not getPlayer() then
        SHOP.bulk = nil
        return
    end
    local last = math.min(job.index + 14, #job.ids)
    for i = job.index, last do
        if pcall(giveItemChecked, job.ids[i], 1) then
            job.given = job.given + 1
        else
            job.failed = job.failed + 1
        end
    end
    job.index = last + 1
    if job.index > #job.ids then
        local text = job.label .. ": added " .. job.given .. " items"
        if job.failed > 0 then text = text .. " (" .. job.failed .. " skipped)" end
        toast(text, job.given > 0)
        SHOP.bulk = nil
    end
end

local function bulkAdd(catName, label, predicate)
    if SHOP.bulk then
        toast("A bulk add is already running.", false)
        return
    end
    if not getPlayer() then
        toast("Load a save first.", false)
        return
    end
    startShopBuild(catName, function(list)
        local ids = {}
        for _, entry in ipairs(list) do
            if not predicate or predicate(entry) then ids[#ids + 1] = entry.id end
        end
        if #ids == 0 then
            toast(label .. ": nothing found to add.", false)
            return
        end
        startBulk(label, ids)
    end)
end

-- Selling: what you own, minus equipped gear, quest items and money.
local function buildSellList()
    local player = getPlayer()
    local equipment = Game.GetScriptableSystemsContainer():Get(CName.new("EquipmentSystem"))
    local list = {}
    for _, data in ipairs(inventoryItems()) do
        pcall(function()
            local id = data:GetID()
            local tdb = itemTdbid(id)
            local name = TDBID.ToStringDEBUG(tdb)
            if type(name) ~= "string" or name == "Items.money" then return end
            if hasTag(data, "Quest") then return end
            local equipped = false
            pcall(function() equipped = equipment:IsEquipped(player, id) == true end)
            if equipped then return end
            local display = name
            pcall(function()
                local text = Game.GetLocalizedTextByKey(TweakDB:GetRecord(tdb):DisplayName())
                if type(text) == "string" and text ~= "" then display = text end
            end)
            list[#list + 1] = {
                id = id, name = display, tdbName = name, qty = data:GetQuantity(),
                price = priceOf(id), junk = hasTag(data, "Junk"),
            }
        end)
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    SHOP.sellList = list
end

local function sellEntry(entry, qty)
    qty = math.min(qty, entry.qty)
    if qty <= 0 then error("you have none left") end
    local price = entry.price or 0
    Game.GetTransactionSystem():RemoveItem(getPlayer(), entry.id, qty)
    if price > 0 then giveItem("Items.money", price * qty) end
    entry.qty = entry.qty - qty
    return price * qty
end

local function drawSellView()
    if not SHOP.sellList and getPlayer() then
        local ok, err = pcall(buildSellList)
        if not ok then
            SHOP.sellList = {}
            toast("Could not read your inventory: " .. tostring(err), false)
        end
    end
    local list = SHOP.sellList or {}

    section("Sell")
    local w = columnWidth(2)
    if button("Refresh My Inventory", w) then
        SHOP.sellList = nil
        return
    end
    ImGui.SameLine()
    if primaryButton("SELL ALL JUNK", w) then
        run("Sell junk", function()
            local total, count = 0, 0
            for _, entry in ipairs(list) do
                if entry.junk and entry.qty > 0 then
                    total = total + sellEntry(entry, entry.qty)
                    count = count + 1
                end
            end
            if count == 0 then error("you have no junk to sell") end
            return "Sold " .. count .. " junk items for E$ " .. formatNumber(total)
        end)
    end

    beginField("Search your inventory", false)
    SHOP.sellSearch = ImGui.InputText("##sellsearch", SHOP.sellSearch or "", 100)
    endField("sellsearch")

    local query = (SHOP.sellSearch or ""):lower()
    local shown = 0
    for i, entry in ipairs(list) do
        if entry.qty > 0 and (query == "" or (entry.name .. " " .. entry.tdbName):lower():find(query, 1, true)) then
            shown = shown + 1
            if shown > 80 then break end
            if primaryButton("SELL 1##sell" .. i, em(5)) then
                run("Sell", function()
                    return "Sold " .. entry.name .. " for E$ " .. formatNumber(sellEntry(entry, 1))
                end)
            end
            ImGui.SameLine()
            if entry.qty > 1 then
                if button("ALL##sellall" .. i, em(3.5)) then
                    run("Sell", function()
                        return "Sold all " .. entry.name .. " for E$ " .. formatNumber(sellEntry(entry, entry.qty))
                    end)
                end
                ImGui.SameLine()
            end
            textColored(entry.junk and C.dim or C.text, entry.name .. (entry.qty > 1 and ("  x" .. entry.qty) or ""))
            ImGui.SameLine()
            textColored(C.green, entry.price and ("E$ " .. formatNumber(entry.price)) or "no price")
        end
    end
    if shown == 0 then hint("Nothing to sell here.") end
    hint("Equipped gear and quest items are left out so you cannot sell them by accident.")
end

local function drawShopPage()
    local mw = columnWidth(2)
    for i, mode in ipairs({ { "buy", "BUY" }, { "sell", "SELL" } }) do
        local label = mode[2] .. "##shopmode"
        if (SHOP.mode or "buy") == mode[1] then
            primaryButton(label, mw)
        elseif button(label, mw) then
            SHOP.mode = mode[1]
            if mode[1] == "sell" then SHOP.sellList = nil end
        end
        if i == 1 then ImGui.SameLine() end
    end
    if SHOP.mode == "sell" then
        drawSellView()
        return
    end

    -- Load the list for the selected category the first time it is shown.
    if not SHOP.lists[SHOP.cat] and not SHOP.build and not SHOP.failed[SHOP.cat] then
        startShopBuild(SHOP.cat)
    end

    section("Unlock Everything")
    SHOP.confirmBulk = ImGui.Checkbox("I understand this adds a lot of items to my inventory", SHOP.confirmBulk)
    local w = columnWidth(3)
    if SHOP.confirmBulk then
        if primaryButton("ALL WEAPONS", w) then
            bulkAdd("Weapons", "All weapons")
        end
        ImGui.SameLine()
        if primaryButton("ICONIC WEAPONS", w) then
            bulkAdd("Weapons", "Iconic weapons", function(e) return e.iconic end)
        end
        ImGui.SameLine()
        if primaryButton("ALL CLOTHING", w) then
            bulkAdd("Clothing", "All clothing")
        end
    else
        hint("Tick the box to enable the buttons.")
    end
    hint("Everything is added for free and can be very heavy. Raise your carry weight on the Player page first.")

    local bulk = SHOP.bulk
    if bulk then
        textColored(C.cyan, string.format("Adding %s...  %d of %d", bulk.label, math.min(bulk.index - 1, #bulk.ids), #bulk.ids))
        pcall(ImGui.ProgressBar, (bulk.index - 1) / #bulk.ids, availWidth(), em(1))
    end

    section("Browse")
    w = columnWidth(#SHOP_CATEGORIES)
    for i, c in ipairs(SHOP_CATEGORIES) do
        local label = c[1] .. "##shopcat"
        if SHOP.cat == c[1] then
            primaryButton(label, w)
        elseif button(label, w) then
            SHOP.cat = c[1]
            SHOP.limit = 60
        end
        if i < #SHOP_CATEGORIES then ImGui.SameLine() end
    end

    beginField("Search  (try: katana, jacket, johnny)", false)
    SHOP.search = ImGui.InputText("##shopsearch", SHOP.search, 100)
    endField("shopsearch")

    SHOP.qty = inputInt("shopqty", "Quantity", SHOP.qty, 1, 9999, 1)
    local v, changed = switch("shoppay", "Pay with eddies  (off = everything is free)", SHOP.pay)
    if changed then SHOP.pay = v end
    if SHOP.pay then
        textColored(C.dim, "Your balance: ")
        ImGui.SameLine()
        textColored(C.yellow, "E$ " .. formatNumber((NCT.info and NCT.info.money) or 0))
    end

    local build = SHOP.build
    if build then
        textColored(C.cyan, string.format("Loading %s...  %d%%", build.cat:lower(),
            math.floor(math.min(build.index, #build.records) / #build.records * 100)))
        return
    end
    if SHOP.failed[SHOP.cat] and not SHOP.lists[SHOP.cat] then
        warn("The game would not list " .. SHOP.cat:lower() .. ". Try another category.")
        return
    end

    local results = shopFiltered() or {}
    local shown = math.min(#results, SHOP.limit)
    textColored(C.dim, string.format("%d found, showing %d", #results, shown))

    for i = 1, shown do
        local entry = results[i]
        if primaryButton((SHOP.pay and "BUY" or "ADD") .. "##shop" .. i, em(4)) then
            run("Shop", function() return shopAdd(entry, SHOP.qty) end)
        end
        ImGui.SameLine()
        textColored(entry.iconic and C.yellow or C.text, entry.name)
        if SHOP.pay then
            if entry.price == nil then entry.price = itemPrice(entry.id) or false end
            ImGui.SameLine()
            textColored(C.green, entry.price and ("E$ " .. formatNumber(entry.price)) or "price n/a")
        end
        ImGui.SameLine()
        textColored(C.dim, entry.id:gsub("^Items%.", ""))
    end
    if #results > shown then
        if button("Show 60 more", availWidth()) then SHOP.limit = SHOP.limit + 60 end
    end
    if #results == 0 then
        hint("Nothing matches that search.")
    end
end

---------------------------------------------------------------------------
-- Style and convenience
-- The settings code follows the approach of psiberx's GameSettings module
-- (cp2077-cet-kit, MIT licence): Game.GetSettingsSystem():GetGroup(path) and
-- each var's GetValue / SetValue.
---------------------------------------------------------------------------

-- Adds a piece of clothing to the wardrobe without putting it in your inventory.
local function addToWardrobe(name)
    local id = ItemID.FromTDBID(TweakDBID.new(name))
    local attempts = {
        function() Game.GetWardrobeSystem():StoreUniqueItemIDAndMarkNew(id) end,
        function() Game.GetWardrobeSystem():StoreUniqueItemID(id) end,
        function() WardrobeSystem.StoreUniqueItemIDAndMarkNew(GetGameInstance(), id) end,
        function() WardrobeSystem.SendWardrobeAddItemRequest(GetGameInstance(), id) end,
    }
    for _, attempt in ipairs(attempts) do
        if pcall(attempt) then return true end
    end
    error("the wardrobe would not take " .. name)
end

local function unlockWardrobe()
    if NCT.job then error("another job is still running") end
    startShopBuild("Clothing", function(list)
        local names = {}
        for _, entry in ipairs(list) do names[#names + 1] = entry.id end
        startJob("Wardrobe", names, addToWardrobe)
    end)
    return "Adding every outfit piece to your wardrobe..."
end

local HUD_PATH = "/interface/hud"
local VISUAL_PATH = "/graphics/basic"

local function drawSettingsGroup(path, idPrefix)
    local list = boolSettings(path)
    if #list == 0 then
        hint("The game did not list these settings.")
        return
    end
    for i, entry in ipairs(list) do
        local ok, value = pcall(function() return entry.var:GetValue() end)
        if ok then
            local v, changed = switch(idPrefix .. i, entry.label, value)
            if changed then
                pcall(function() entry.var:SetValue(v) end)
                settingsCache[path] = nil
                saveUserSettings()
            end
        end
    end
end

local function drawStylePage()
    section("HUD")
    local w = columnWidth(2)
    if primaryButton("HIDE ALL HUD", w) then
        run("Hide HUD", function()
            setBoolGroup(HUD_PATH, false)
            return "HUD hidden - press SHOW ALL HUD or the hotkey to bring it back"
        end)
    end
    ImGui.SameLine()
    if button("Show All HUD", w) then
        run("Show HUD", function()
            setBoolGroup(HUD_PATH, true)
            return "HUD shown"
        end)
    end
    hint("Or switch single parts on and off below. These are the game's own HUD settings.")
    drawSettingsGroup(HUD_PATH, "hud")

    section("Photo Tools")
    local pw = columnWidth(3)
    if button("Freeze World", pw) then
        run("World frozen", function() applyGameSpeed(0.02) end)
    end
    ImGui.SameLine()
    if button("Unfreeze", pw) then
        run("Game speed normal", function() applyGameSpeed(1.0) end)
    end
    ImGui.SameLine()
    if button("Clean Screenshot", pw) then
        run("Clean screenshot", function()
            setBoolGroup(HUD_PATH, false)
            applyGameSpeed(0.02)
            return "HUD hidden and world frozen - press Unfreeze and Show All HUD when done"
        end)
    end
    hint("Field of view is on the Player page; time of day and weather are on the World page.")

    section("Visual Effects")
    hint("Turn film grain, chromatic aberration, lens flare, motion blur and the like on or off.")
    drawSettingsGroup(VISUAL_PATH, "gfx")

    section("Wardrobe")
    if primaryButton("UNLOCK EVERY OUTFIT PIECE", availWidth()) then
        run("Unlock wardrobe", unlockWardrobe)
    end
    local job = NCT.job
    if job then
        textColored(C.cyan, string.format("%s...  %d of %d", job.label, math.min(job.index - 1, #job.list), #job.list))
        pcall(ImGui.ProgressBar, (job.index - 1) / #job.list, availWidth(), em(1))
    end
    hint("Puts every piece of clothing into the wardrobe at your stash for transmog, without filling "
        .. "your inventory. To own a piece for real, use the Clothing tab of the Shop page.")
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
    -- Looked up at most once a second, not on every frame.
    if not NCT.vehicleLook or os.clock() - NCT.vehicleLook.time >= 1 then
        local source = nil
        if getPlayer() then
            local _, found = findVehicle()
            source = found
        end
        NCT.vehicleLook = { time = os.clock(), source = source }
    end
    if NCT.vehicleLook.source then
        textColored(C.green, "The buttons below act on " .. NCT.vehicleLook.source .. ".")
    else
        hint("No vehicle found. Get in one, look at one, or call your car, then use the buttons below.")
    end

    local w = columnWidth(2)
    if primaryButton("REPAIR & CALL VEHICLE", w) then
        run("Repair vehicle", reviveVehicle)
    end
    ImGui.SameLine()
    if button("Flip Upright", w) then
        run("Vehicle flipped upright", flipVehicle)
    end
    hint("Repairs your car once, even after it was wrecked, then calls it to you.")

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
            if not mountedVehicle() then error("get in the vehicle to boost it") end
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
    hint("Bind the six Fly keys in CET's Bindings tab first. Using W, A, S, D, Space and Ctrl works well. "
        .. "Forward and back follow where the camera points, left and right strafe, so turning the "
        .. "camera steers you. Switch on God Mode before turning Fly Mode off high up.")

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
    "Flip vehicle upright", "Kill hostile enemies nearby", "Toggle Auto Skip Cutscenes",
    "Toggle Perfect Aim", "Toggle Free Instant Quickhacks", "Toggle One-Hit Kill", "Toggle Auto Loot",
    "Blink forward", "Teleport to first saved spot", "Turn every cheat off",
    "Toggle HUD", "Quick save", "Cure all debuffs", "Skip one hour",
    "Fly: forward / back / left / right / up / down  (hold)",
}

local function drawSettingsPage()
    section("Trainer")
    local v, changed = ImGui.Checkbox("Remember my cheats between sessions", NCT.rememberCheats)
    if changed then
        NCT.rememberCheats = v
        saveSettings()
    end
    hint("Every setting is saved automatically as you change it. Every cheat you left on, plus your "
        .. "movement, cyberware, XP and game speed sliders, switch back on when you load a save. "
        .. "Only Fly Mode is left off on purpose.")

    v, changed = ImGui.Checkbox("Show pop-ups when I use a hotkey", NCT.showPopups)
    if changed then
        NCT.showPopups = v
        saveSettings()
    end
    hint("A small message appears at the top of the screen while the menu is closed.")

    section("Quality Of Life")
    cheatToggle("autoSkip")

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

---------------------------------------------------------------------------
-- Test checklist: tick what works and what is broken, and the trainer writes
-- test-report.txt next to itself so it can be read and fixed.
---------------------------------------------------------------------------

local CHECKLIST = {
    { "Player", {
        "God Mode (no damage, explosions too)", "Infinite Stamina", "Infinite Oxygen", "Infinite RAM",
        "Rapid Health Regen", "Status Immunity", "No Fall Damage (high falls too)", "Double Jump",
        "Air Dash", "Silent Movement", "Field of view", "Run speed / jump height / carry weight",
    } },
    { "Combat", {
        "Infinite Ammo", "Perfect Aim", "One-Hit Kill", "Always Crit", "Mega Crit Damage", "Tank Armor",
        "Invisible (also when enemies already locked on)", "Free Instant Quickhacks", "Rapid Item Recharge",
        "Kill Enemies Nearby", "Auto Loot", "Slow Motion",
    } },
    { "Money and Shop", {
        "Add money", "Shop: buy (free)", "Shop: pay with eddies", "Shop: sell", "Sell All Junk",
        "Unlock all weapons / iconics / clothing", "Vendor Discounts", "Spawn item by ID",
    } },
    { "Progress", {
        "Give perk points", "Give attribute points", "Give relic points", "Level up / street cred up",
        "Set skill levels", "+XP to every skill", "XP multiplier", "Max All Perks", "Upgrade All Cyberware",
        "Upgrade held weapon", "Unlock all crafting recipes", "Free respec", "Max Out Everything",
    } },
    { "Vehicles", {
        "Repair & Call Vehicle (after it was wrecked)", "Flip Upright", "Open / close doors", "Next radio station",
        "Boost forward", "Dream Garage cars", "Unlock all vehicles",
    } },
    { "World and Teleport", {
        "Time of day / skip time", "Freeze time of day", "Weather", "Disable Police", "Wanted level stars",
        "Clear wanted level", "Game speed / freeze world", "Fly mode (steering and strafing)", "Blink forward",
        "Saved teleport spots",
    } },
    { "Style", {
        "Hide all HUD / single HUD parts", "Visual effects switches", "Clean screenshot", "Wardrobe unlock",
    } },
    { "Everyday", {
        "Auto skip cutscenes (presses Y)", "Quick save", "Cure all debuffs", "Profiles", "Loadouts",
        "Cheats come back after restarting the game", "Cheats come back after dying", "Achievements unlock",
        "Hotkeys",
    } },
}

local CHECK_LABELS = { ok = "WORKS", bad = "BROKEN", skip = "SKIPPED" }

-- Builds the report text and the totals, without writing anything.
local function buildReport()
    local lines = {}
    local counts = { ok = 0, bad = 0, skip = 0, none = 0 }
    for _, group in ipairs(CHECKLIST) do
        lines[#lines + 1] = "[" .. group[1] .. "]"
        for _, item in ipairs(group[2]) do
            local entry = NCT.checklist[item]
            local state = entry and entry.state or "none"
            counts[state] = (counts[state] or 0) + 1
            local line = string.format("  %-11s %s", CHECK_LABELS[state] or "NOT TESTED", item)
            if entry and entry.note and entry.note ~= "" then line = line .. "   -- " .. entry.note end
            lines[#lines + 1] = line
        end
        lines[#lines + 1] = ""
    end
    local header = {
        "Night City Trainer v" .. NCT.version .. " test report  (" .. os.date("%Y-%m-%d %H:%M") .. ")",
        string.format("Works: %d   Broken: %d   Skipped: %d   Not tested: %d",
            counts.ok, counts.bad, counts.skip, counts.none),
        "",
    }
    return table.concat(header, "\n") .. table.concat(lines, "\n"), counts
end

-- Saves the report to test-report.txt. Called only when an answer changes.
local function writeReport()
    local text, counts = buildReport()
    pcall(function()
        local file = io.open("test-report.txt", "w")
        if file then
            file:write(text)
            file:close()
        end
    end)
    return text, counts
end

local function choiceButton(label, active, color, width)
    if active then
        ImGui.PushStyleColor(ImGuiCol.Button, color[1], color[2], color[3], 0.85)
        ImGui.PushStyleColor(ImGuiCol.ButtonHovered, color[1], color[2], color[3], 1)
        ImGui.PushStyleColor(ImGuiCol.Text, C.black[1], C.black[2], C.black[3], 1)
    end
    local pressed = ImGui.Button(label, width, 0)
    if active then ImGui.PopStyleColor(3) end
    return pressed
end

local function drawChecklistPage()
    local _, counts = buildReport()
    section("Test Checklist")
    hint("Try each feature in the game, then mark it. Your answers are saved straight away to "
        .. "test-report.txt in the trainer's folder, so they can be read and fixed. Add a note for anything broken.")
    textColored(C.text, string.format("Works %d    Broken %d    Skipped %d    Not tested %d",
        counts.ok, counts.bad, counts.skip, counts.none))
    local w = columnWidth(2)
    if button("Copy Report", w) then
        local text = writeReport()
        if pcall(ImGui.SetClipboardText, text) then
            toast("Report copied - paste it in the chat", true)
        else
            toast("Copy is not available - the report is saved in test-report.txt", false)
        end
    end
    ImGui.SameLine()
    if dangerButton("Clear All Answers", w) then
        NCT.checklist = {}
        writeReport()
        toast("Checklist cleared", true)
    end

    local bw = em(5.2)
    for _, group in ipairs(CHECKLIST) do
        section(group[1])
        for i, item in ipairs(group[2]) do
            local entry = NCT.checklist[item] or {}
            local id = group[1] .. i
            local function mark(state)
                if entry.state == state then entry.state = nil else entry.state = state end
                NCT.checklist[item] = entry
                writeReport()
            end
            if choiceButton("Works##ok" .. id, entry.state == "ok", C.green, bw) then mark("ok") end
            ImGui.SameLine()
            if choiceButton("Broken##bad" .. id, entry.state == "bad", C.red, bw) then mark("bad") end
            ImGui.SameLine()
            if choiceButton("Skip##skip" .. id, entry.state == "skip", C.dim, bw) then mark("skip") end
            ImGui.SameLine()
            local color = entry.state == "ok" and C.green or (entry.state == "bad" and C.red or C.text)
            textColored(color, item)
            if entry.state == "bad" then
                ImGui.PushItemWidth(availWidth())
                local note = ImGui.InputText("##note" .. id, entry.note or "", 160)
                ImGui.PopItemWidth()
                if type(note) == "string" and note ~= (entry.note or "") then
                    entry.note = note
                    NCT.checklist[item] = entry
                    writeReport()
                end
                if (entry.note or "") == "" then hint("What went wrong? (optional)") end
            end
        end
    end
end

-- name, draw function, icon name (from CET's bundled icon font)
local PAGES = {
    { "Home", drawHomePage, "Home" },
    { "Player", drawPlayerPage, "Account" },
    { "Combat", drawCombatPage, "Sword" },
    { "Money", drawMoneyPage, "Cash" },
    { "Progress", drawProgressPage, "TrendingUp" },
    { "Shop", drawShopPage, "Cart" },
    { "Items", drawItemsPage, "PackageVariant" },
    { "Style", drawStylePage, "Palette" },
    { "Vehicles", drawVehiclesPage, "Car" },
    { "World", drawWorldPage, "Earth" },
    { "Teleport", drawTeleportPage, "MapMarker" },
    { "Achievements", drawAchievementsPage, "Trophy" },
    { "Settings", drawSettingsPage, "Cog" },
    { "Test", drawChecklistPage, "ClipboardCheck" },
}

local function pageIcon(name)
    local ok, glyph = pcall(function() return IconGlyphs[name] end)
    if ok and type(glyph) == "string" then return glyph .. "  " end
    return ""
end

---------------------------------------------------------------------------
-- Window
---------------------------------------------------------------------------

-- A rounded label with text inside. Returns its width.
local function pill(dl, x, y, text, fg, bg, dot)
    local pad = em(0.55)
    local extra = dot and em(0.8) or 0
    local w = textWidth(text) + pad * 2 + extra
    local h = ImGui.GetFontSize() + em(0.45)
    fillRect(dl, x, y, x + w, y + h, bg, h / 2)
    if dot then
        local pulse = 0.45 + 0.55 * (0.5 + 0.5 * math.sin(os.clock() * 4))
        ImGui.ImDrawListAddCircleFilled(dl, x + pad + em(0.2), y + h / 2, em(0.22), u32(fg, pulse), 12)
    end
    ImGui.SetCursorScreenPos(x + pad + extra, y + em(0.22))
    textColored(fg, text)
    return w
end

-- Banner across the top: title, live status pills, and a light that sweeps
-- along the bottom edge.
local function drawFancyHeader()
    local dl = ImGui.GetWindowDrawList()
    local x, y = ImGui.GetCursorScreenPos()
    local w = availWidth()
    local h = em(4.4)
    local now = os.clock()

    gradientRect(dl, x, y, x + w, y + h, u32(C.panel, 0.95), u32(C.side, 0.6))
    fillRect(dl, x, y, x + em(0.3), y + h, u32(C.yellow))
    hline(dl, x, x + w, y + h - 1, u32(C.cyan, 0.2), 1)
    local band = em(9)
    local sweep = (now * 0.3) % 1
    local sx = x - band + sweep * (w + band)
    gradientRect(dl, math.max(x, sx), y + h - 2, math.min(x + w, sx + band), y + h, u32(C.cyan, 0), u32(C.cyan, 0.9))

    ImGui.SetCursorScreenPos(x + em(1.0), y + em(0.5))
    textColored(C.yellow, "NIGHT CITY TRAINER")
    ImGui.SameLine()
    textColored(C.dim, "v" .. NCT.version)

    local px, py = x + em(1.0), y + em(2.25)
    local gap = em(0.4)
    local info = NCT.info
    if info then
        px = px + pill(dl, px, py, "ONLINE", C.green, u32(C.green, 0.12), true) + gap
        local parts = {}
        if info.level then parts[#parts + 1] = "LVL " .. info.level end
        if info.cred then parts[#parts + 1] = "CRED " .. info.cred end
        if info.money then parts[#parts + 1] = "E$ " .. formatNumber(info.money) end
        for _, text in ipairs(parts) do
            px = px + pill(dl, px, py, text, C.text, u32(C.panelHi, 0.9)) + gap
        end
        local active = activeCheatCount()
        pill(dl, px, py, active .. (active == 1 and " CHEAT ON" or " CHEATS ON"), C.black, u32(C.yellow, 0.95))
    else
        px = px + pill(dl, px, py, "NO SAVE LOADED", C.red, u32(C.red, 0.14), true) + gap
        ImGui.SetCursorScreenPos(px, py + em(0.22))
        textColored(C.dim, "load a save to enable the cheats")
    end
    ImGui.SetCursorScreenPos(x, y + h + GAP)
    ImGui.Dummy(0, 0)
end

local function drawPlainHeader()
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
    ImGui.Separator()
end

local function drawHeader()
    if not (canDraw() and pcall(drawFancyHeader)) then drawPlainHeader() end
end

local function openPage(name)
    if NCT.page ~= name then
        NCT.page = name
        anim.pageAt = os.clock()
    end
end

-- Sidebar with a highlight that glides to the selected page.
local function drawFancySidebar()
    local dl = ImGui.GetWindowDrawList()
    local w = availWidth()
    local h = em(1.95)
    local step = h + 4
    local x0, y0 = ImGui.GetCursorScreenPos()

    local selected = 1
    for i, page in ipairs(PAGES) do
        if page[1] == NCT.page then selected = i end
    end
    local target = y0 + (selected - 1) * step
    if not anim.navY or math.abs(anim.navY - target) > step * #PAGES then anim.navY = target end
    anim.navY = anim.navY + (target - anim.navY) * math.min(1, anim.dt * 14)
    fillRect(dl, x0, anim.navY, x0 + w, anim.navY + h, u32(C.yellow, 0.13), 5)
    fillRect(dl, x0, anim.navY + 5, x0 + 3, anim.navY + h - 5, u32(C.yellow), 2)

    for i, page in ipairs(PAGES) do
        local iy = y0 + (i - 1) * step
        ImGui.SetCursorScreenPos(x0, iy)
        if ImGui.InvisibleButton("##nav" .. i, w, h) then openPage(page[1]) end
        local hovered = ImGui.IsItemHovered()
        if hovered and i ~= selected then
            fillRect(dl, x0, iy, x0 + w, iy + h, u32(C.panelHi, 0.55), 5)
        end
        ImGui.SetCursorScreenPos(x0 + em(0.8), iy + (h - ImGui.GetFontSize()) / 2)
        local color = (i == selected) and C.yellow or (hovered and C.text or C.dim)
        textColored(color, pageIcon(page[3]) .. page[1])
    end
    ImGui.SetCursorScreenPos(x0, y0 + #PAGES * step + em(0.4))
    if dangerButton(pageIcon("Power") .. "All Off##nav", w) then
        everythingOff()
    end
end

local function drawPlainSidebar()
    local w = availWidth()
    -- Left-aligned labels so the icons line up.
    ImGui.PushStyleVar(ImGuiStyleVar.ButtonTextAlign, 0.08, 0.5)
    for _, page in ipairs(PAGES) do
        local name = page[1]
        local label = pageIcon(page[3]) .. name .. "##nav"
        if NCT.page == name then
            primaryButton(label, w)
        elseif button(label, w) then
            openPage(name)
        end
    end
    ImGui.Dummy(0, em(0.3))
    if dangerButton(pageIcon("Power") .. "All Off##nav", w) then
        everythingOff()
    end
    ImGui.PopStyleVar(1)
end

local function drawSidebar()
    if not (canDraw() and pcall(drawFancySidebar)) then drawPlainSidebar() end
end

-- Status line at the bottom: the latest message, fading in when it changes.
local function drawStatusBar()
    local ok = NCT.toast.ok
    local color = ok and C.green or C.red
    local t = easeOut((os.clock() - NCT.toast.time) / 0.35)
    local fancy = canDraw() and pcall(function()
        local dl = ImGui.GetWindowDrawList()
        local x, y = ImGui.GetCursorScreenPos()
        local w = availWidth()
        local h = ImGui.GetFontSize() + em(0.7)
        fillRect(dl, x, y, x + w, y + h, u32(C.panel, 0.9), 5)
        fillRect(dl, x, y, x + 3 + (1 - t) * em(2), y + h, u32(color, 0.85), 2)
        ImGui.SetCursorScreenPos(x + em(0.9) + (1 - t) * em(1), y + em(0.35))
        ImGui.PushStyleVar(ImGuiStyleVar.Alpha, 0.35 + 0.65 * t)
        textColored(color, NCT.toast.text)
        ImGui.PopStyleVar(1)
        ImGui.SetCursorScreenPos(x, y + h + 2)
        ImGui.Dummy(0, 0)
    end)
    if not fancy then wrapped(color, "> " .. NCT.toast.text) end
end

local function drawWindow()
    ImGui.SetNextWindowSize(em(48), em(44), ImGuiCond.FirstUseEver)
    ImGui.SetNextWindowPos(80, 80, ImGuiCond.FirstUseEver)

    local now = os.clock()
    anim.dt = math.min(0.1, math.max(0, now - anim.last))
    anim.last = now
    if anim.pageName ~= NCT.page then
        anim.pageName = NCT.page
        anim.pageAt = now
    end

    if ImGui.Begin("Night City Trainer", ImGuiWindowFlags.NoCollapse + ImGuiWindowFlags.NoTitleBar) then
        if canDraw() then
            pcall(function()
                local wx, wy = ImGui.GetWindowPos()
                local ww = ImGui.GetWindowSize()
                gradientRect(ImGui.GetWindowDrawList(), wx + 8, wy, wx + ww - 8, wy + 2, u32(C.yellow), u32(C.cyan, 0.8))
            end)
        end
        drawHeader()

        local _, availH = ImGui.GetContentRegionAvail()
        local bodyH = math.max(availH - em(2.6), em(6))

        ImGui.BeginChild("##nct_side", em(11), bodyH, true)
        drawSidebar()
        ImGui.EndChild()

        ImGui.SameLine()

        ImGui.PushStyleColor(ImGuiCol.ChildBg, 0, 0, 0, 0)
        ImGui.BeginChild("##nct_page", 0, bodyH, true)
        firstSection = true
        -- New pages fade in and slide a little from the left.
        local t = easeOut((now - anim.pageAt) / 0.28)
        local slide = (1 - t) * em(1.6)
        ImGui.PushStyleVar(ImGuiStyleVar.Alpha, 0.15 + 0.85 * t)
        if slide > 0.5 then ImGui.Indent(slide) end
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
        if slide > 0.5 then ImGui.Unindent(slide) end
        ImGui.PopStyleVar(1)
        if not found then NCT.page = "Home" end
        ImGui.EndChild()
        ImGui.PopStyleColor(1)

        drawStatusBar()
    end
    ImGui.End()
end

-- Small message at the top of the screen, shown while the menu is closed so
-- hotkeys still give feedback.
local function drawPopup()
    local width = GetDisplayResolution()
    local age = os.clock() - NCT.toast.time
    local appear = easeOut(age / 0.25)
    local fade = 1 - math.max(0, math.min(1, (age - 2.5) / 0.5))
    ImGui.SetNextWindowPos(width / 2, 50 + 20 * appear, ImGuiCond.Always, 0.5, 0)
    local flags = ImGuiWindowFlags.NoTitleBar + ImGuiWindowFlags.NoResize + ImGuiWindowFlags.NoMove
        + ImGuiWindowFlags.NoScrollbar + ImGuiWindowFlags.NoSavedSettings + ImGuiWindowFlags.NoInputs
        + ImGuiWindowFlags.AlwaysAutoResize + ImGuiWindowFlags.NoFocusOnAppearing
    ImGui.PushStyleVar(ImGuiStyleVar.Alpha, math.max(0.01, appear * fade))
    if ImGui.Begin("##nct_popup", flags) then
        if canDraw() then
            pcall(function()
                local wx, wy = ImGui.GetWindowPos()
                local _, wh = ImGui.GetWindowSize()
                fillRect(ImGui.GetWindowDrawList(), wx, wy + 6, wx + 3, wy + wh - 6,
                    u32(NCT.toast.ok and C.green or C.red), 2)
            end)
        end
        textColored(C.yellow, "NIGHT CITY TRAINER")
        ImGui.SameLine()
        textColored(NCT.toast.ok and C.green or C.red, NCT.toast.text)
    end
    ImGui.End()
    ImGui.PopStyleVar(1)
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
    NCT.saveTick = (NCT.saveTick or 0) + delta

    if NCT.fly then pcall(updateFly, delta) end

    -- Cutscene watch runs about 30 times a second so the helper reacts at once.
    NCT.skipTick = (NCT.skipTick or 0) + delta
    if NCT.skipTick >= 0.03 then
        NCT.skipTick = 0
        if NCT.autoSkip and getPlayer() then
            local active = inScene()
            NCT.sceneActive = active
            local key = tostring(active) .. NCT.skipSpeed
            -- Written on every change and once a second so the helper can tell we are alive.
            if key ~= NCT.lastFlag or os.clock() - (NCT.flagTime or 0) >= 1 then
                writeSkipFlag(active)
                NCT.lastFlag, NCT.flagTime = key, os.clock()
            end
        elseif NCT.lastFlag ~= nil then
            writeSkipFlag(false)
            NCT.lastFlag, NCT.sceneActive = nil, nil
        end
    end

    -- Protection that has to react within a fraction of a second.
    NCT.guardTick = (NCT.guardTick or 0) + delta
    if NCT.guardTick >= 0.05 then
        NCT.guardTick = 0
        if getPlayer() then
            if NCT.godMode then pcall(fillPool, gamedataStatPoolType.Health) end
            if NCT.noFall then
                pcall(guardFalls)
            elseif NCT.fall then
                NCT.fall = nil
                pcall(setFallShield, false)
            end
        end
    end

    NCT.combatTick = (NCT.combatTick or 0) + delta
    if NCT.combatTick >= 0.1 then
        NCT.combatTick = 0
        if getPlayer() then
            if NCT.oneHit then pcall(oneHitSweep) end
        end
    end

    NCT.aggroTick = (NCT.aggroTick or 0) + delta
    if NCT.aggroTick >= 0.5 then
        NCT.aggroTick = 0
        if NCT.invisible and getPlayer() then pcall(dropAggro) end
    end

    NCT.lootTick = (NCT.lootTick or 0) + delta
    if NCT.lootTick >= 1 then
        NCT.lootTick = 0
        if NCT.autoLoot and getPlayer() then
            local ok, taken = pcall(autoLootNearby)
            if ok and taken and taken > 0 then toast("Auto Loot: emptied " .. taken .. (taken == 1 and " body" or " bodies"), true) end
        end
    end

    pcall(stepShopBuild)
    pcall(stepBulk)
    pcall(stepJob)

    if NCT.saveTick >= 5 then
        NCT.saveTick = 0
        saveSettings()
    end

    if NCT.tick >= 0.2 then
        NCT.tick = 0

        -- Spot a save being loaded: the player disappears, then comes back.
        local present = getPlayer() ~= nil
        if present and not NCT.hadPlayer then
            NCT.hadPlayer = true
            if NCT.seenPlayer then onNewSave() end
            NCT.seenPlayer = true
        elseif not present then
            NCT.hadPlayer = false
        end

        -- Dying and respawning wipes every stat change, so everything is put back.
        local dead = false
        if present then pcall(function() dead = getPlayer():IsDead() == true end) end
        if NCT.wasDead and not dead then onNewSave() end
        NCT.wasDead = dead

        if NCT.autoSkip and present then
            pcall(autoSkipScenes)
        end
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
        if NCT.overlayOpen then
            refreshInfo()
            NCT.helperRunning = skipHelperRunning()
        end
    end

    if NCT.slowTick >= 2.0 then
        NCT.slowTick = 0
        if getPlayer() then
            if NCT.pendingRestore then restoreCheats() end
            -- Re-applied regularly so toggles survive loading another save.
            if NCT.godMode then pcall(CHEATS.godMode.apply, true) end
            if NCT.noPolice then pcall(setPolice, false) end
            if NCT.invisible then pcall(function() getPlayer():SetInvisible(true) end) end
            if NCT.fovOn then pcall(applyFov) end
            NCT.reassertCount = (NCT.reassertCount or 0) + 1
            if NCT.reassertCount % 3 == 0 then reassertStatCheats() end
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
cheatHotkey("nct_one_hit", "oneHit")
cheatHotkey("nct_auto_loot", "autoLoot")
cheatHotkey("nct_auto_skip", "autoSkip")
cheatHotkey("nct_perfect_aim", "perfectAim")
cheatHotkey("nct_instant_hacks", "instantHacks")

registerHotkey("nct_toggle_hud", "Toggle HUD", function()
    run("Toggle HUD", toggleHud)
end)

registerHotkey("nct_quick_save", "Quick save", function()
    run("Quick save", quickSave)
end)

registerHotkey("nct_cure", "Cure all debuffs", function()
    run("Cure debuffs", cureDebuffs)
end)

registerHotkey("nct_skip_hour", "Skip one hour", function()
    run("Skip time", function() return skipHours(1) end)
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
registerInput("nct_fly_left", "Fly: strafe left (hold)", function(down) NCT.keys.left = down end)
registerInput("nct_fly_right", "Fly: strafe right (hold)", function(down) NCT.keys.right = down end)
registerInput("nct_fly_up", "Fly: up (hold)", function(down) NCT.keys.up = down end)
registerInput("nct_fly_down", "Fly: down (hold)", function(down) NCT.keys.down = down end)

return NCT
