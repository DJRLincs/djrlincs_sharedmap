--[[
    DJRLincs Shared Map - Client Script
    Handles prompts, NUI control, and communication
]]

local isMapOpen = false
local currentMapId = nil
local isEditing = false
local nearAccessPoint = false
local currentAccessIndex = nil
local cachedPlayerJob = nil

-- Prompt groups
local promptGroup = GetRandomIntInRange(0, 0xFFFFFF)
local promptView = nil
local promptEdit = nil

-- Forward declaration for RefreshBlipsOnJobChange (defined in BLIP section)
local RefreshBlipsOnJobChange

-- =============================================================================
-- JOB/PERMISSION HELPERS
-- =============================================================================

-- Get player's current job from VORP character state
local function GetPlayerJob()
    if LocalPlayer and LocalPlayer.state and LocalPlayer.state.Character then
        return LocalPlayer.state.Character.Job or "none"
    end
    return "none"
end

-- Check if player can VIEW a specific location (prompt/blip visibility)
local function CanViewLocation(location)
    -- If no view restriction, everyone can see it
    if not location.viewRestrictedJobs then
        return true
    end
    
    local playerJob = GetPlayerJob()
    for _, allowedJob in ipairs(location.viewRestrictedJobs) do
        if playerJob == allowedJob then
            return true
        end
    end
    return false
end

-- Update cached job when character changes
AddStateBagChangeHandler('Character', 'global', function(bagName, key, value)
    if bagName == ('player:' .. GetPlayerServerId(PlayerId())) then
        local oldJob = cachedPlayerJob
        cachedPlayerJob = value and value.Job or nil
        if oldJob ~= cachedPlayerJob then
            if Config.Debug then
                print(string.format("^3[DJRLincs-SharedMap] Job changed: %s -> %s^0", tostring(oldJob), tostring(cachedPlayerJob)))
            end
            -- Refresh blips when job changes (for viewRestrictedJobs filtering)
            CreateThread(function()
                Wait(500) -- Brief delay to ensure job is fully updated
                RefreshBlipsOnJobChange()
            end)
        end
    end
end)

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

CreateThread(function()
    -- Create prompts (matching vorp_stores pattern)
    promptView = PromptRegisterBegin()
    PromptSetControlAction(promptView, 0x760A9C6F) -- G key
    local label = CreateVarString(10, 'LITERAL_STRING', Config.Lang.promptView)
    PromptSetText(promptView, label)
    PromptSetEnabled(promptView, true)
    PromptSetVisible(promptView, true)
    PromptSetStandardMode(promptView, true) -- REQUIRED: Enable standard mode for press detection
    PromptSetGroup(promptView, promptGroup, 0)
    PromptRegisterEnd(promptView)
    
    -- Wait for prompts to be active
    Wait(500)
    
    if Config.Debug then
        print("^2[DJRLincs-SharedMap] Client initialized - Prompt ready^0")
    end
end)

-- =============================================================================
-- MAIN LOOP - Proximity Check
-- =============================================================================

CreateThread(function()
    while true do
        local playerPed = PlayerPedId()
        local playerCoords = GetEntityCoords(playerPed)
        local closestIndex = nil
        local closestDist = 999.0
        
        -- Find closest access point (respecting view restrictions)
        for i, location in ipairs(Config.AccessLocations) do
            -- Check if player can view this location before distance check
            if CanViewLocation(location) then
                local dist = #(playerCoords - location.coords)
                if dist < location.radius and dist < closestDist then
                    closestDist = dist
                    closestIndex = i
                end
            end
        end
        
        if closestIndex then
            if not nearAccessPoint or currentAccessIndex ~= closestIndex then
                nearAccessPoint = true
                currentAccessIndex = closestIndex
                if Config.Debug then
                    print("^2[DJRLincs-SharedMap] Near: " .. Config.AccessLocations[closestIndex].name .. "^0")
                end
            end
        else
            if nearAccessPoint then
                nearAccessPoint = false
                currentAccessIndex = nil
            end
        end
        
        -- Longer wait when not near any access point
        Wait(nearAccessPoint and 500 or 2000)
    end
end)

-- =============================================================================
-- PROMPT HANDLING
-- =============================================================================

CreateThread(function()
    while true do
        Wait(0)
        
        if nearAccessPoint and not isMapOpen then
            -- Draw prompt group this frame
            local label = CreateVarString(10, 'LITERAL_STRING', Config.AccessLocations[currentAccessIndex].name)
            PromptSetActiveGroupThisFrame(promptGroup, label, 0, 0, 0, 0)
            
            -- Check for prompt press (matching vorp_stores: second param = 0)
            if PromptHasStandardModeCompleted(promptView, 0) then
                Wait(100)
                OpenMap()
            end
        end
    end
end)

-- =============================================================================
-- MAP UI CONTROL
-- =============================================================================

function OpenMap()
    if isMapOpen then return end
    
    isMapOpen = true
    
    -- Get the map group (or location name fallback) from the access point
    local mapName = nil
    local mapType = "main" -- Default to main map
    if currentAccessIndex and Config.AccessLocations[currentAccessIndex] then
        local location = Config.AccessLocations[currentAccessIndex]
        mapName = location.mapGroup or location.name -- Use mapGroup if set, else name
        mapType = location.mapType or "main" -- Use mapType if set, else main
    end
    
    -- Request map data from server using map group name and type
    TriggerServerEvent('djrlincs_sharedmap:openMap', mapName, mapType)
end

function CloseMap()
    if not isMapOpen then return end
    
    isMapOpen = false
    isEditing = false
    currentMapId = nil
    
    -- Close NUI
    SendNUIMessage({ type = 'closeMap' })
    
    -- Standard NUI focus cleanup
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    
    if Config.Debug then
        print("^2[DJRLincs-SharedMap] Map closed^0")
    end
end

-- =============================================================================
-- SERVER EVENTS
-- =============================================================================

RegisterNetEvent('djrlincs_sharedmap:openUI')
AddEventHandler('djrlincs_sharedmap:openUI', function(data)
    currentMapId = data.mapId
    isEditing = data.isEditing or false
    
    -- Send data to NUI first
    SendNUIMessage({
        type = 'openMap',
        mapData = {
            id = data.mapId,
            name = data.mapName,
            description = data.mapDescription or '',
            mapType = data.mapType or 'main', -- "main" or "guarma"
            excalidrawData = data.sceneData,
            lockedBy = data.lockedBy,
            lockedByName = data.lockedByName,
            isLocked = data.isLocked or (data.lockedBy ~= nil),
            hasPermission = data.hasPermission or false,
            canEdit = data.canEdit or false
        },
        playerName = data.playerName or 'Unknown'
    })
    
    -- Enable NUI focus
    SetNuiFocus(true, true)
    
    if Config.Debug then
        print(string.format("^2[DJRLincs-SharedMap] Opened map: %s^0", data.mapName))
    end
end)

RegisterNetEvent('djrlincs_sharedmap:notify')
AddEventHandler('djrlincs_sharedmap:notify', function(action, data)
    -- Handle lock status changes
    if action == 'lockGranted' then
        isEditing = true
        SendNUIMessage({
            type = 'lockStatus',
            isLocked = true,
            lockedBy = data.lockedBy,
            lockedByName = data.lockedByName,
            canEdit = true
        })
        ShowNotification(Config.Lang.lockAcquired)
    elseif action == 'lockReleased' then
        isEditing = false
        -- Send lockReleased event specifically so React can handle it distinctly
        SendNUIMessage({
            type = 'lockReleased'
        })
        -- Also send lockStatus for backwards compatibility
        SendNUIMessage({
            type = 'lockStatus',
            isLocked = false,
            lockedBy = nil,
            lockedByName = nil,
            canEdit = false
        })
    elseif action == 'lockDenied' then
        SendNUIMessage({
            type = 'lockStatus',
            isLocked = true,
            lockedBy = data.lockedBy,
            lockedByName = data.lockedByName,
            canEdit = false
        })
        ShowNotification(string.format(Config.Lang.lockDenied))
    elseif action == 'editorChanged' then
        -- Another player started/stopped editing
        SendNUIMessage({
            type = 'editorChanged',
            isLocked = data.isEditing or false,
            lockedByName = data.editorName or ''
        })
        if data.isEditing and data.editorName then
            -- Optional: show notification when someone else starts editing
            if Config.Debug then
                print(string.format("^3[DJRLincs-SharedMap] %s started editing^0", data.editorName))
            end
        end
    elseif action == 'mapUpdate' then
        -- Another player saved the map, update our view
        SendNUIMessage({
            type = 'updateMap',
            data = data.sceneData,
            lockedBy = data.lockedBy,
            lockedByName = data.lockedByName
        })
    elseif action == 'saved' then
        ShowNotification(Config.Lang.mapSaved)
    elseif action == 'error' then
        ShowNotification(data.message or 'An error occurred', true)
    end
end)

RegisterNetEvent('djrlincs_sharedmap:error')
AddEventHandler('djrlincs_sharedmap:error', function(message)
    ShowNotification(message, true)
end)

-- =============================================================================
-- NUI CALLBACKS
-- =============================================================================

RegisterNUICallback('close', function(data, cb)
    -- Release edit lock if we were editing
    if isEditing and currentMapId then
        TriggerServerEvent('djrlincs_sharedmap:releaseLock', currentMapId)
        if Config.Debug then
            print("^3[DJRLincs-SharedMap] Released edit lock on map close^0")
        end
    end
    
    isMapOpen = false
    isEditing = false
    currentMapId = nil
    
    -- Release NUI focus
    SetNuiFocus(false, false)
    SetNuiFocusKeepInput(false)
    
    cb('ok')
end)

RegisterNUICallback('requestLock', function(data, cb)
    TriggerServerEvent('djrlincs_sharedmap:requestLock', currentMapId)
    cb('ok')
end)

RegisterNUICallback('releaseLock', function(data, cb)
    TriggerServerEvent('djrlincs_sharedmap:releaseLock', currentMapId)
    isEditing = false
    cb('ok')
end)

RegisterNUICallback('refreshLock', function(data, cb)
    TriggerServerEvent('djrlincs_sharedmap:heartbeat', currentMapId)
    cb('ok')
end)

RegisterNUICallback('saveMap', function(data, cb)
    TriggerServerEvent('djrlincs_sharedmap:saveMap', currentMapId, data.data)
    cb('ok')
end)

RegisterNUICallback('loadMap', function(data, cb)
    TriggerServerEvent('djrlincs_sharedmap:loadMap', data.mapId)
    cb('ok')
end)

RegisterNUICallback('createMap', function(data, cb)
    TriggerServerEvent('djrlincs_sharedmap:createMap', data.name)
    cb('ok')
end)

-- =============================================================================
-- BLIPS
-- Matching vorp_stores implementation for proper blip display
-- =============================================================================

local blipHandles = {}

local function GetBlipSprite(spriteName)
    -- If it's already a number, return it directly
    if type(spriteName) == "number" then
        return spriteName
    end
    -- Otherwise hash the string
    return joaat(spriteName)
end

local function CreateLocationBlips()
    -- Clean up any existing blips first
    for _, blip in ipairs(blipHandles) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end
    blipHandles = {}
    
    local createdCount = 0
    local skippedCount = 0
    
    for i, location in ipairs(Config.AccessLocations) do
        if location.blip then
            -- Check view restriction BEFORE creating blip
            if not CanViewLocation(location) then
                skippedCount = skippedCount + 1
                if Config.Debug then
                    print(string.format("^3[DJRLincs-SharedMap] Skipped blip (view restricted): %s^0", location.name))
                end
            else
                -- Create blip using CFX native (same as vorp_stores)
                local blip = BlipAddForCoords(1664425300, location.coords.x, location.coords.y, location.coords.z)
                
                -- Set blip sprite (use false for third param like vorp_stores)
                local sprite = GetBlipSprite(location.blipSprite or Config.DefaultBlipSprite or 1047294027) -- Default: Sheriff badge
                SetBlipSprite(blip, sprite, false)
                
                -- Set blip scale if configured
                local scale = location.blipScale or Config.DefaultBlipScale or 0.2
                SetBlipScale(blip, scale)
                
                -- Set blip color modifier (matching vorp_stores pattern)
                local colorModifier = location.blipColor or Config.DefaultBlipColor or "BLIP_MODIFIER_MP_COLOR_6"
                BlipAddModifier(blip, joaat(colorModifier))
                
                -- Set blip name
                SetBlipName(blip, location.name)
                
                table.insert(blipHandles, blip)
                createdCount = createdCount + 1
                
                if Config.Debug then
                    print(string.format("^2[DJRLincs-SharedMap] Created blip: %s | Sprite: %s | Color: %s | Scale: %.2f^0", 
                        location.name, tostring(sprite), colorModifier, scale))
                end
            end
        end
    end
    
    print(string.format("^2[DJRLincs-SharedMap] Created %d blips (skipped %d view-restricted)^0", createdCount, skippedCount))
end

-- Refresh blips when job changes (to show/hide restricted locations)
RefreshBlipsOnJobChange = function()
    if Config.Debug then
        print("^3[DJRLincs-SharedMap] Refreshing blips due to job change...^0")
    end
    CreateLocationBlips()
end

CreateThread(function()
    -- Wait for player session to be ready
    repeat Wait(1000) until LocalPlayer.state.IsInSession
    Wait(500) -- Brief stability wait
    
    CreateLocationBlips()
end)

-- Cleanup blips on resource stop
AddEventHandler('onResourceStop', function(resourceName)
    if GetCurrentResourceName() ~= resourceName then return end
    
    for _, blip in ipairs(blipHandles) do
        if DoesBlipExist(blip) then
            RemoveBlip(blip)
        end
    end
end)

-- =============================================================================
-- UTILITY FUNCTIONS
-- =============================================================================

function ShowNotification(message, isError)
    -- Use VORP notification if available
    if isError then
        TriggerEvent("vorp:TipBottom", message, 4000)
    else
        TriggerEvent("vorp:TipRight", message, 4000)
    end
end

-- =============================================================================
-- COMMANDS (for testing)
-- =============================================================================

if Config.Debug then
    RegisterCommand('sharedmap', function(source, args)
        if isMapOpen then
            CloseMap()
        else
            OpenMap(tonumber(args[1]) or 1)
        end
    end, false)
end

-- =============================================================================
-- CLEANUP
-- =============================================================================

AddEventHandler('onResourceStop', function(resourceName)
    if resourceName == GetCurrentResourceName() then
        if isMapOpen then
            SetNuiFocus(false, false)
        end
    end
end)
