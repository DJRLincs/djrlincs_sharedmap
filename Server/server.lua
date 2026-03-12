--[[
    DJRLincs Shared Map - Server Script
    Handles lock management, persistence, and real-time sync
]]

local VORPcore = nil
local locks = {} -- { mapId = { charId, charName, timestamp } }
local viewers = {} -- { mapId = { source1, source2, ... } }
local activeConnections = {} -- { source = { mapId, isEditing } }

-- Rate limiting for saves (DoS protection)
local lastSaveTime = {} -- { source = timestamp }
local SAVE_RATE_LIMIT_MS = 1000 -- Minimum 1 second between saves from same player
local MAX_SAVE_SIZE = 5 * 1024 * 1024 -- 5MB max save size

-- =============================================================================
-- INITIALIZATION
-- =============================================================================

CreateThread(function()
    while VORPcore == nil do
        local success, result = pcall(function()
            return exports.vorp_core:GetCore()
        end)
        if success and result then
            VORPcore = result
            print("^2[DJRLincs-SharedMap] VORP Core initialized^0")
        else
            print("^3[DJRLincs-SharedMap] Waiting for VORP Core...^0")
            Wait(1000)
        end
    end
    
    -- Initialize database
    InitializeDatabase()
    
    -- Start lock cleanup thread
    CreateThread(LockCleanupThread)
end)

-- =============================================================================
-- WEBHOOK LOGGING
-- =============================================================================

-- Track previous map states for change detection
local previousMapStates = {} -- { mapId = { elementCount, elements } }

-- Track web viewer access for rate limiting (avoid spamming webhooks)
local webViewerAccessLog = {} -- { "ip:mapName" = timestamp }
local WEB_VIEWER_LOG_COOLDOWN = 300 -- 5 minutes between logs per IP per map

function ShouldLogWebViewerAccess(ipAddress, mapName)
    local key = (ipAddress or "unknown") .. ":" .. (mapName or "unknown")
    local now = os.time()
    local lastAccess = webViewerAccessLog[key]
    
    if not lastAccess or (now - lastAccess) >= WEB_VIEWER_LOG_COOLDOWN then
        webViewerAccessLog[key] = now
        return true
    end
    return false
end

-- Get webhook URL for a specific board (returns board-specific URL if set)
function GetBoardWebhook(mapName)
    if not mapName then return nil end
    
    for _, location in ipairs(Config.AccessLocations) do
        local locationMapName = location.mapGroup or location.name
        if locationMapName == mapName then
            if location.webhook and location.webhook ~= "" then
                return location.webhook
            end
            break
        end
    end
    return nil
end

-- Send to a specific webhook URL
function SendToWebhook(webhookUrl, embed)
    if not webhookUrl or webhookUrl == "" or webhookUrl == "YOUR_DISCORD_WEBHOOK_URL" then
        return
    end
    
    PerformHttpRequest(webhookUrl, function(err, text, headers) end, 'POST', json.encode({ embeds = embed }), { ['Content-Type'] = 'application/json' })
end

function SendWebhook(eventType, data)
    if not Config.Webhook.enabled then return end
    
    local color = 3447003 -- Blue default
    local title = "Shared Map Event"
    local description = ""
    local fields = {}
    
    if eventType == "lockAcquired" then
        if not Config.Webhook.logLockAcquired then return end
        color = 15844367 -- Gold
        title = "Map Editing Started"
        description = string.format("**%s** started editing a map", data.charName or "Unknown")
        table.insert(fields, { name = "Map Board", value = data.mapName or "Unknown", inline = true })
        
    elseif eventType == "mapEdited" then
        if not Config.Webhook.logMapEdited then return end
        color = 3066993 -- Green
        title = "Map Saved"
        description = string.format("**%s** saved changes to a map", data.charName or "Unknown")
        table.insert(fields, { name = "Map Board", value = data.mapName or "Unknown", inline = true })
        
        -- Add change summary if available
        if data.changes then
            local changeText = ""
            if data.changes.added > 0 then
                changeText = changeText .. string.format("+%d added  ", data.changes.added)
            end
            if data.changes.removed > 0 then
                changeText = changeText .. string.format("-%d removed  ", data.changes.removed)
            end
            if data.changes.modified > 0 then
                changeText = changeText .. string.format("~%d modified", data.changes.modified)
            end
            if changeText ~= "" then
                table.insert(fields, { name = "Changes", value = changeText, inline = false })
            end
            
            -- Element type breakdown
            if data.changes.types and next(data.changes.types) then
                local typeText = ""
                for elemType, count in pairs(data.changes.types) do
                    if count > 0 then
                        typeText = typeText .. string.format("%s: %d  ", elemType, count)
                    end
                end
                if typeText ~= "" then
                    table.insert(fields, { name = "Element Types", value = typeText, inline = false })
                end
            end
            
            -- Image URLs added
            if data.changes.imageUrls and #data.changes.imageUrls > 0 then
                local imageText = ""
                for i, url in ipairs(data.changes.imageUrls) do
                    if i <= 5 then -- Limit to 5 URLs to avoid embed limit
                        imageText = imageText .. url .. "\n"
                    end
                end
                if #data.changes.imageUrls > 5 then
                    imageText = imageText .. string.format("... and %d more", #data.changes.imageUrls - 5)
                end
                table.insert(fields, { name = "Images Added", value = imageText, inline = false })
            end
        end
        
    elseif eventType == "mapCreated" then
        if not Config.Webhook.logMapCreated then return end
        color = 10181046 -- Purple
        title = "New Map Created"
        description = string.format("A new map board was created")
        table.insert(fields, { name = "Map Board", value = data.mapName or "Unknown", inline = true })
        
    elseif eventType == "webViewerAccess" then
        if not Config.Webhook.logWebViewer then return end
        color = 5814783 -- Cyan
        title = "Web Viewer Access"
        description = string.format("Someone is viewing a map via web browser")
        table.insert(fields, { name = "Map Board", value = data.mapName or "Unknown", inline = true })
        if data.ipAddress then
            table.insert(fields, { name = "IP Address", value = data.ipAddress, inline = true })
        end
    end
    
    local embed = {
        {
            title = title,
            description = description,
            color = color,
            fields = fields,
            timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ"),
            footer = {
                text = "DJRLincs Shared Map"
            }
        }
    }
    
    -- Web viewer access has its own dedicated webhook
    if eventType == "webViewerAccess" then
        -- Use webViewerUrl if set, otherwise fall back to master
        local webUrl = Config.Webhook.webViewerUrl
        if webUrl and webUrl ~= "" then
            SendToWebhook(webUrl, embed)
        else
            SendToWebhook(Config.Webhook.masterUrl, embed)
        end
        return
    end
    
    -- Send to board-specific webhook if configured
    local boardWebhook = GetBoardWebhook(data.mapName)
    if boardWebhook then
        SendToWebhook(boardWebhook, embed)
    end
    
    -- Always send to master webhook
    SendToWebhook(Config.Webhook.masterUrl, embed)
end

function CalculateChanges(mapId, newDataJson)
    local changes = {
        added = 0,
        removed = 0,
        modified = 0,
        types = {},
        imageUrls = {} -- Track newly added image URLs
    }
    
    -- Parse new data
    local success, newData = pcall(json.decode, newDataJson)
    if not success or not newData then
        return changes
    end
    
    local newElements = newData.elements or {}
    local imageUrls = newData.imageUrls or {} -- New format: URLs only (not base64)
    local newElementsById = {}
    
    for _, elem in ipairs(newElements) do
        if elem.id then
            newElementsById[elem.id] = elem
            -- Track element types
            local elemType = elem.type or "unknown"
            changes.types[elemType] = (changes.types[elemType] or 0) + 1
        end
    end
    
    -- Get previous state
    local prevState = previousMapStates[mapId]
    if not prevState then
        -- First save - everything is "added"
        changes.added = #newElements
        -- Extract image URLs from newly added images
        for _, elem in ipairs(newElements) do
            if elem.type == "image" and elem.fileId and imageUrls[elem.fileId] then
                local urlData = imageUrls[elem.fileId]
                if urlData.url then
                    table.insert(changes.imageUrls, urlData.url)
                end
            end
        end
        previousMapStates[mapId] = { elementsById = newElementsById, count = #newElements, imageIds = {} }
        -- Track which image IDs we've seen
        for _, elem in ipairs(newElements) do
            if elem.type == "image" and elem.fileId then
                previousMapStates[mapId].imageIds[elem.fileId] = true
            end
        end
        return changes
    end
    
    local prevElementsById = prevState.elementsById or {}
    local prevImageIds = prevState.imageIds or {}
    
    -- Count added elements (in new but not in prev)
    for id, elem in pairs(newElementsById) do
        if not prevElementsById[id] then
            changes.added = changes.added + 1
            -- If it's a new image, get its URL
            if elem.type == "image" and elem.fileId and imageUrls[elem.fileId] then
                local urlData = imageUrls[elem.fileId]
                if urlData.url and not prevImageIds[elem.fileId] then
                    table.insert(changes.imageUrls, urlData.url)
                end
            end
        else
            -- Check if modified (version changed)
            if elem.version and prevElementsById[id].version and elem.version ~= prevElementsById[id].version then
                changes.modified = changes.modified + 1
            end
        end
    end
    
    -- Count removed elements (in prev but not in new)
    for id, _ in pairs(prevElementsById) do
        if not newElementsById[id] then
            changes.removed = changes.removed + 1
        end
    end
    
    -- Update stored state
    previousMapStates[mapId] = { elementsById = newElementsById, count = #newElements, imageIds = {} }
    for _, elem in ipairs(newElements) do
        if elem.type == "image" and elem.fileId then
            previousMapStates[mapId].imageIds[elem.fileId] = true
        end
    end
    
    return changes
end

-- =============================================================================
-- DATABASE
-- =============================================================================

function InitializeDatabase()
    MySQL.query([[
        CREATE TABLE IF NOT EXISTS djrlincs_sharedmaps (
            id INT AUTO_INCREMENT PRIMARY KEY,
            map_name VARCHAR(64) NOT NULL UNIQUE,
            excalidraw_data LONGTEXT,
            last_editor_charid INT DEFAULT NULL,
            last_editor_name VARCHAR(128) DEFAULT NULL,
            locked_by_charid INT DEFAULT NULL,
            locked_by_name VARCHAR(128) DEFAULT NULL,
            locked_at DATETIME DEFAULT NULL,
            created_at DATETIME DEFAULT CURRENT_TIMESTAMP,
            updated_at DATETIME DEFAULT CURRENT_TIMESTAMP ON UPDATE CURRENT_TIMESTAMP
        ) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
    ]], {}, function(result)
        print("^2[DJRLincs-SharedMap] Database table verified^0")
        
        -- Create default map if none exists
        MySQL.query("SELECT COUNT(*) as count FROM djrlincs_sharedmaps", {}, function(result)
            if result[1].count == 0 then
                CreateMap(Config.UI.defaultMapName)
                print("^2[DJRLincs-SharedMap] Created default map^0")
            end
        end)
    end)
end

-- =============================================================================
-- MAP CRUD OPERATIONS
-- =============================================================================

function GetAllMaps(callback)
    MySQL.query("SELECT id, map_name, locked_by_charid, locked_by_name, updated_at FROM djrlincs_sharedmaps ORDER BY id ASC", {}, function(result)
        local maps = {}
        for _, row in ipairs(result or {}) do
            table.insert(maps, {
                id = row.id,
                name = row.map_name,
                lockedBy = row.locked_by_charid,
                lockedByName = row.locked_by_name,
                updatedAt = row.updated_at
            })
        end
        callback(maps)
    end)
end

function GetMap(mapId, callback)
    MySQL.query("SELECT * FROM djrlincs_sharedmaps WHERE id = @id", {
        ['@id'] = mapId
    }, function(result)
        if result and result[1] then
            callback(result[1])
        else
            callback(nil)
        end
    end)
end

function GetMapByName(name, callback)
    MySQL.query("SELECT * FROM djrlincs_sharedmaps WHERE map_name = @name", {
        ['@name'] = name
    }, function(result)
        if result and result[1] then
            callback(result[1])
        else
            callback(nil)
        end
    end)
end

function GetOrCreateMapByName(name, callback)
    GetMapByName(name, function(map)
        if map then
            callback(map)
        else
            -- Create the map if it doesn't exist
            CreateMap(name, function(newId)
                GetMap(newId, callback)
            end)
        end
    end)
end

function CreateMap(name, callback)
    MySQL.insert("INSERT INTO djrlincs_sharedmaps (map_name, excalidraw_data) VALUES (@name, @data)", {
        ['@name'] = name,
        ['@data'] = '{"elements":[],"appState":{}}'
    }, function(id)
        -- Send webhook for new map creation
        SendWebhook('mapCreated', {
            mapName = name
        })
        
        if callback then
            callback(id)
        end
    end)
end

function SaveMap(mapId, data, charId, charName)
    MySQL.update("UPDATE djrlincs_sharedmaps SET excalidraw_data = @data, last_editor_charid = @charId, last_editor_name = @charName WHERE id = @id", {
        ['@id'] = mapId,
        ['@data'] = data,
        ['@charId'] = charId,
        ['@charName'] = charName
    })
end

function DeleteMap(mapId)
    MySQL.query("DELETE FROM djrlincs_sharedmaps WHERE id = @id", {
        ['@id'] = mapId
    })
end

-- =============================================================================
-- LOCK MANAGEMENT
-- =============================================================================

function AcquireLock(mapId, charId, charName)
    -- Check if already locked
    local existingLock = locks[mapId]
    if existingLock and existingLock.charId ~= charId then
        -- Check if lock is expired
        local now = os.time()
        local lockAge = now - existingLock.timestamp
        if lockAge < (Config.Lock.timeoutMinutes * 60) then
            return false, existingLock.charName
        end
    end
    
    -- Acquire lock
    locks[mapId] = {
        charId = charId,
        charName = charName,
        timestamp = os.time()
    }
    
    -- Update database
    MySQL.update("UPDATE djrlincs_sharedmaps SET locked_by_charid = @charId, locked_by_name = @charName, locked_at = NOW() WHERE id = @id", {
        ['@id'] = mapId,
        ['@charId'] = charId,
        ['@charName'] = charName
    })
    
    -- Notify all viewers
    NotifyViewers(mapId, 'editorChanged', {
        editorName = charName,
        isEditing = true
    })
    
    return true, nil
end

function ReleaseLock(mapId, charId)
    local lock = locks[mapId]
    if lock and lock.charId == charId then
        locks[mapId] = nil
        
        -- Update database
        MySQL.update("UPDATE djrlincs_sharedmaps SET locked_by_charid = NULL, locked_by_name = NULL, locked_at = NULL WHERE id = @id", {
            ['@id'] = mapId
        })
        
        -- Notify all viewers
        NotifyViewers(mapId, 'editorChanged', {
            editorName = '',
            isEditing = false
        })
        
        return true
    end
    return false
end

function RefreshLock(mapId, charId)
    local lock = locks[mapId]
    if lock and lock.charId == charId then
        lock.timestamp = os.time()
        return true
    end
    return false
end

function GetLockStatus(mapId)
    local lock = locks[mapId]
    if lock then
        local now = os.time()
        local lockAge = now - lock.timestamp
        if lockAge < (Config.Lock.timeoutMinutes * 60) then
            return {
                locked = true,
                charId = lock.charId,
                charName = lock.charName
            }
        else
            -- Lock expired
            locks[mapId] = nil
            MySQL.update("UPDATE djrlincs_sharedmaps SET locked_by_charid = NULL, locked_by_name = NULL, locked_at = NULL WHERE id = @id", {
                ['@id'] = mapId
            })
        end
    end
    return { locked = false }
end

function LockCleanupThread()
    while true do
        Wait(60000) -- Check every minute
        
        local now = os.time()
        local expiredLocks = {}
        
        for mapId, lock in pairs(locks) do
            local lockAge = now - lock.timestamp
            if lockAge >= (Config.Lock.timeoutMinutes * 60) then
                table.insert(expiredLocks, mapId)
            end
        end
        
        for _, mapId in ipairs(expiredLocks) do
            print(string.format("^3[DJRLincs-SharedMap] Lock expired for map %d^0", mapId))
            locks[mapId] = nil
            
            MySQL.update("UPDATE djrlincs_sharedmaps SET locked_by_charid = NULL, locked_by_name = NULL, locked_at = NULL WHERE id = @id", {
                ['@id'] = mapId
            })
            
            NotifyViewers(mapId, 'lockReleased', {})
        end
    end
end

-- =============================================================================
-- VIEWER MANAGEMENT
-- =============================================================================

function AddViewer(mapId, source)
    if not viewers[mapId] then
        viewers[mapId] = {}
    end
    
    -- Remove from previous map if any
    if activeConnections[source] then
        local prevMapId = activeConnections[source].mapId
        RemoveViewer(prevMapId, source)
    end
    
    viewers[mapId][source] = true
    activeConnections[source] = {
        mapId = mapId,
        isEditing = false
    }
end

function RemoveViewer(mapId, source)
    if viewers[mapId] then
        viewers[mapId][source] = nil
    end
    activeConnections[source] = nil
end

function NotifyViewers(mapId, action, data)
    if not viewers[mapId] then return end
    
    for viewerSource, _ in pairs(viewers[mapId]) do
        TriggerClientEvent('djrlincs_sharedmap:notify', viewerSource, action, data)
    end
end

function BroadcastStateUpdate(mapId, sceneData, excludeSource)
    if not viewers[mapId] then return end
    
    local lockStatus = GetLockStatus(mapId)
    
    for viewerSource, _ in pairs(viewers[mapId]) do
        if viewerSource ~= excludeSource then
            TriggerClientEvent('djrlincs_sharedmap:notify', viewerSource, 'mapUpdate', {
                sceneData = sceneData,
                lockedBy = lockStatus.charId,
                lockedByName = lockStatus.charName
            })
        end
    end
end

-- =============================================================================
-- PERMISSION CHECKS
-- =============================================================================

-- Helper to find location config by mapGroup or name
function GetLocationConfigByMapName(mapName)
    for _, location in ipairs(Config.AccessLocations) do
        local locationMapName = location.mapGroup or location.name
        if locationMapName == mapName then
            return location
        end
    end
    return nil
end

function CanEdit(source, mapName)
    if not VORPcore then 
        if Config.Debug then print("^1[DJRLincs-SharedMap] CanEdit: VORPcore not loaded^0") end
        return false 
    end
    
    local User = VORPcore.getUser(source)
    if not User then 
        if Config.Debug then print("^1[DJRLincs-SharedMap] CanEdit: User not found for source " .. tostring(source) .. "^0") end
        return false 
    end
    
    local Character = User.getUsedCharacter
    if not Character then 
        if Config.Debug then print("^1[DJRLincs-SharedMap] CanEdit: Character not found^0") end
        return false 
    end
    
    local mode = Config.Permissions.editMode
    local job = Character.job or "none"
    
    if Config.Debug then
        print(string.format("^3[DJRLincs-SharedMap] CanEdit check: mode=%s, playerJob=%s, mapName=%s^0", mode, job, mapName or "nil"))
    end
    
    if mode == "all" then
        if Config.Debug then print("^2[DJRLincs-SharedMap] CanEdit: mode=all, granted^0") end
        return true
    elseif mode == "ace" then
        local hasAce = IsPlayerAceAllowed(source, Config.Permissions.acePermission)
        if Config.Debug then print(string.format("^3[DJRLincs-SharedMap] CanEdit: ace check = %s^0", tostring(hasAce))) end
        return hasAce
    elseif mode == "job" then
        -- First check location-specific allowedJobs
        if mapName then
            local locationConfig = GetLocationConfigByMapName(mapName)
            if locationConfig and locationConfig.allowedJobs then
                -- Empty allowedJobs = everyone can edit this board
                if #locationConfig.allowedJobs == 0 then
                    if Config.Debug then print("^2[DJRLincs-SharedMap] CanEdit: Empty allowedJobs = everyone, granted^0") end
                    return true
                end
                if Config.Debug then
                    print(string.format("^3[DJRLincs-SharedMap] CanEdit: Checking location jobs for %s: %s^0", 
                        mapName, table.concat(locationConfig.allowedJobs, ", ")))
                end
                for _, allowedJob in ipairs(locationConfig.allowedJobs) do
                    if job == allowedJob then
                        if Config.Debug then print("^2[DJRLincs-SharedMap] CanEdit: Job match on location! granted^0") end
                        return true
                    end
                end
                -- Location has specific jobs and player's job not in list
                if Config.Debug then print("^1[DJRLincs-SharedMap] CanEdit: Job not in location allowedJobs, denied^0") end
                return false
            end
        end
        
        -- Fallback to global allowedJobs if location doesn't have specific ones
        if Config.Debug then
            print(string.format("^3[DJRLincs-SharedMap] CanEdit: Checking global jobs: %s^0", 
                table.concat(Config.Permissions.allowedJobs or {}, ", ")))
        end
        for _, allowedJob in ipairs(Config.Permissions.allowedJobs) do
            if job == allowedJob then
                if Config.Debug then print("^2[DJRLincs-SharedMap] CanEdit: Job match on global! granted^0") end
                return true
            end
        end
        if Config.Debug then print("^1[DJRLincs-SharedMap] CanEdit: No job match, denied^0") end
        return false
    elseif mode == "whitelist" then
        local charId = Character.charIdentifier
        for _, id in ipairs(Config.Permissions.whitelist) do
            if charId == id then
                if Config.Debug then print("^2[DJRLincs-SharedMap] CanEdit: Whitelist match, granted^0") end
                return true
            end
        end
        if Config.Debug then print("^1[DJRLincs-SharedMap] CanEdit: Not in whitelist, denied^0") end
        return false
    end
    
    if Config.Debug then print("^1[DJRLincs-SharedMap] CanEdit: Unknown mode, denied^0") end
    return false
end

function GetCharacterInfo(source)
    if not VORPcore then return nil, nil end
    
    local User = VORPcore.getUser(source)
    if not User then return nil, nil end
    
    local Character = User.getUsedCharacter
    if not Character then return nil, nil end
    
    local charId = Character.charIdentifier
    -- Always use character first/last name, never the username
    local charName = (Character.firstname or 'Unknown') .. ' ' .. (Character.lastname or '')
    charName = charName:gsub("^%s+", ""):gsub("%s+$", "") -- Trim whitespace
    
    if charName == '' or charName == ' ' then
        charName = 'Unknown'
    end
    
    return charId, charName
end

-- =============================================================================
-- NET EVENTS
-- =============================================================================

RegisterNetEvent('djrlincs_sharedmap:openMap')
AddEventHandler('djrlincs_sharedmap:openMap', function(locationName, mapType)
    local source = source
    local charId, charName = GetCharacterInfo(source)
    local receivedMapType = mapType or "main" -- Default to main if not provided
    
    if not charId then
        TriggerClientEvent('djrlincs_sharedmap:error', source, 'Character not found')
        return
    end
    
    -- Use location name to get or create the map
    local mapName = locationName or Config.UI.defaultMapName
    
    GetAllMaps(function(maps)
        GetOrCreateMapByName(mapName, function(map)
            if not map then
                TriggerClientEvent('djrlincs_sharedmap:error', source, 'Failed to load map')
                return
            end
            
            local canEdit = CanEdit(source, mapName) -- Pass mapName for per-board job check
            local lockStatus = GetLockStatus(map.id)
            local isEditing = lockStatus.locked and lockStatus.charId == charId
            
            -- Add to viewers
            AddViewer(map.id, source)
            
            TriggerClientEvent('djrlincs_sharedmap:openUI', source, {
                mapId = map.id,
                mapName = map.map_name,
                mapDescription = '',
                mapType = receivedMapType, -- "main" or "guarma"
                playerName = charName,
                maps = maps,
                sceneData = map.excalidraw_data or '{"elements":[],"appState":{}}',
                hasPermission = canEdit, -- Has ACE/job permission to edit
                canEdit = isEditing, -- Currently has the lock (actively editing)
                isEditing = isEditing,
                isLocked = lockStatus.locked,
                lockedBy = lockStatus.charId,
                lockedByName = lockStatus.charName or ''
            })
        end)
    end)
end)

RegisterNetEvent('djrlincs_sharedmap:requestLock')
AddEventHandler('djrlincs_sharedmap:requestLock', function(mapId)
    local source = source
    local charId, charName = GetCharacterInfo(source)
    
    if not charId then return end
    
    -- Get map to check per-board job permissions
    GetMap(mapId, function(map)
        if not map then return end
        
        local mapName = map.map_name
        
        if not CanEdit(source, mapName) then
            TriggerClientEvent('djrlincs_sharedmap:notify', source, 'error', {
                message = Config.Lang.noPermission
            })
            return
        end
        
        local success, existingEditor = AcquireLock(mapId, charId, charName)
        
        if success then
            activeConnections[source].isEditing = true
            TriggerClientEvent('djrlincs_sharedmap:notify', source, 'lockGranted', {
                lockedBy = charId,
                lockedByName = charName
            })
            
            -- Send webhook notification
            SendWebhook('lockAcquired', {
                mapName = mapName,
                charName = charName
            })
            
            if Config.Debug then
                print(string.format("^2[DJRLincs-SharedMap] Lock granted to %s for map %d^0", charName, mapId))
            end
        else
            local lockStatus = GetLockStatus(mapId)
            TriggerClientEvent('djrlincs_sharedmap:notify', source, 'lockDenied', {
                lockedBy = lockStatus.charId,
                lockedByName = lockStatus.charName or existingEditor
            })
        end
    end)
end)

RegisterNetEvent('djrlincs_sharedmap:releaseLock')
AddEventHandler('djrlincs_sharedmap:releaseLock', function(mapId)
    local source = source
    local charId, charName = GetCharacterInfo(source)
    
    if not charId then return end
    
    if ReleaseLock(mapId, charId) then
        if activeConnections[source] then
            activeConnections[source].isEditing = false
        end
        TriggerClientEvent('djrlincs_sharedmap:notify', source, 'lockReleased', {})
        
        if Config.Debug then
            print(string.format("^3[DJRLincs-SharedMap] Lock released by %s for map %d^0", charName, mapId))
        end
    end
end)

RegisterNetEvent('djrlincs_sharedmap:heartbeat')
AddEventHandler('djrlincs_sharedmap:heartbeat', function(mapId)
    local source = source
    local charId, _ = GetCharacterInfo(source)
    
    if charId then
        RefreshLock(mapId, charId)
    end
end)

RegisterNetEvent('djrlincs_sharedmap:saveMap')
AddEventHandler('djrlincs_sharedmap:saveMap', function(mapId, sceneData)
    local source = source
    local charId, charName = GetCharacterInfo(source)
    
    if not charId then return end
    
    -- Rate limiting: prevent spam saves
    local now = GetGameTimer()
    if lastSaveTime[source] and (now - lastSaveTime[source]) < SAVE_RATE_LIMIT_MS then
        if Config.Debug then
            print(string.format("^1[DJRLincs-SharedMap] Rate limited save from %s^0", charName))
        end
        return
    end
    lastSaveTime[source] = now
    
    -- Size validation: prevent huge saves
    if not sceneData or type(sceneData) ~= "string" then
        TriggerClientEvent('djrlincs_sharedmap:notify', source, 'error', {
            message = 'Invalid save data'
        })
        return
    end
    
    if #sceneData > MAX_SAVE_SIZE then
        local sizeMB = string.format("%.2f", #sceneData / (1024 * 1024))
        TriggerClientEvent('djrlincs_sharedmap:notify', source, 'error', {
            message = 'Save data too large (' .. sizeMB .. 'MB). Max is 5MB.'
        })
        print(string.format("^1[DJRLincs-SharedMap] Rejected oversized save from %s: %sMB^0", charName, sizeMB))
        return
    end
    
    -- Verify the player has the lock
    local lockStatus = GetLockStatus(mapId)
    if not lockStatus.locked or lockStatus.charId ~= charId then
        TriggerClientEvent('djrlincs_sharedmap:notify', source, 'error', {
            message = 'You do not have edit access'
        })
        return
    end
    
    -- Calculate changes before saving
    local changes = CalculateChanges(mapId, sceneData)
    
    -- Save to database
    SaveMap(mapId, sceneData, charId, charName)
    
    -- Get map name for webhook
    GetMap(mapId, function(map)
        if map then
            -- Send webhook with change details
            SendWebhook('mapEdited', {
                mapName = map.map_name,
                charName = charName,
                changes = changes
            })
        end
    end)
    
    -- Notify the saver
    TriggerClientEvent('djrlincs_sharedmap:notify', source, 'saved', {})
    
    -- Broadcast to all viewers (real-time sync)
    BroadcastStateUpdate(mapId, sceneData, source)
    
    if Config.Debug then
        print(string.format("^2[DJRLincs-SharedMap] Map %d saved by %s^0", mapId, charName))
    end
end)

RegisterNetEvent('djrlincs_sharedmap:loadMap')
AddEventHandler('djrlincs_sharedmap:loadMap', function(mapId)
    local source = source
    
    GetMap(mapId, function(map)
        if not map then
            TriggerClientEvent('djrlincs_sharedmap:notify', source, 'error', {
                message = 'Map not found'
            })
            return
        end
        
        -- Update viewer tracking
        AddViewer(mapId, source)
        
        local lockStatus = GetLockStatus(mapId)
        
        TriggerClientEvent('djrlincs_sharedmap:notify', source, 'mapLoaded', {
            mapId = map.id,
            mapName = map.map_name,
            sceneData = map.excalidraw_data or '{"elements":[],"appState":{}}',
            lockedBy = lockStatus.charId,
            lockedByName = lockStatus.charName or ''
        })
    end)
end)

RegisterNetEvent('djrlincs_sharedmap:createMap')
AddEventHandler('djrlincs_sharedmap:createMap', function(name)
    local source = source
    local charId, charName = GetCharacterInfo(source)
    
    if not charId then return end
    if not CanEdit(source) then
        TriggerClientEvent('djrlincs_sharedmap:notify', source, 'error', {
            message = Config.Lang.noPermission
        })
        return
    end
    
    CreateMap(name, function(newMapId)
        if newMapId then
            -- Notify creator
            TriggerClientEvent('djrlincs_sharedmap:notify', source, 'mapCreated', {
                mapId = newMapId,
                mapName = name
            })
            
            -- Refresh map list for all
            GetAllMaps(function(updatedMaps)
                for viewerSource, _ in pairs(activeConnections) do
                    TriggerClientEvent('djrlincs_sharedmap:notify', viewerSource, 'mapList', {
                        maps = updatedMaps
                    })
                end
            end)
            
            if Config.Debug then
                print(string.format("^2[DJRLincs-SharedMap] Map '%s' created by %s^0", name, charName))
            end
        else
            TriggerClientEvent('djrlincs_sharedmap:notify', source, 'error', {
                message = 'Failed to create map (name may already exist)'
            })
        end
    end)
end)

RegisterNetEvent('djrlincs_sharedmap:closed')
AddEventHandler('djrlincs_sharedmap:closed', function()
    local source = source
    local charId, _ = GetCharacterInfo(source)
    
    if activeConnections[source] then
        local mapId = activeConnections[source].mapId
        local wasEditing = activeConnections[source].isEditing
        
        -- Release lock if was editing
        if wasEditing and charId then
            ReleaseLock(mapId, charId)
        end
        
        -- Remove from viewers
        RemoveViewer(mapId, source)
    end
end)


-- =============================================================================
-- PLAYER DISCONNECT HANDLING
-- =============================================================================

AddEventHandler('playerDropped', function(reason)
    local source = source
    local charId, charName = GetCharacterInfo(source)
    
    if activeConnections[source] then
        local mapId = activeConnections[source].mapId
        local wasEditing = activeConnections[source].isEditing
        
        -- Release lock if was editing
        if wasEditing and charId then
            ReleaseLock(mapId, charId)
            if Config.Debug then
                print(string.format("^3[DJRLincs-SharedMap] Lock released due to disconnect: %s^0", charName or 'Unknown'))
            end
        end
        
        -- Remove from viewers
        RemoveViewer(mapId, source)
    end
end)

-- =============================================================================
-- WEB VIEWER HTTP HANDLERS
-- =============================================================================

-- Get all unique map groups from config (for web viewer dropdown)
local function GetLocations()
    local locations = {}
    local seen = {}
    local id = 1
    
    for _, loc in ipairs(Config.AccessLocations or {}) do
        local mapName = loc.mapGroup or loc.name
        if not seen[mapName] then
            seen[mapName] = true
            table.insert(locations, {
                id = id,
                name = mapName,
                mapType = loc.mapType or "main" -- Include mapType for web viewer
            })
            id = id + 1
        end
    end
    return locations
end

-- Get mapType for a location name by looking up in config
local function GetMapTypeForLocation(locationName)
    for _, loc in ipairs(Config.AccessLocations or {}) do
        local mapName = loc.mapGroup or loc.name
        if mapName == locationName then
            return loc.mapType or "main"
        end
    end
    return "main" -- Default to main map
end

-- JSON encode helper
local function JsonEncode(data)
    -- Simple JSON encoder for Lua tables
    if type(data) == "table" then
        local isArray = #data > 0
        local result = isArray and "[" or "{"
        local first = true
        
        if isArray then
            for _, v in ipairs(data) do
                if not first then result = result .. "," end
                first = false
                result = result .. JsonEncode(v)
            end
        else
            for k, v in pairs(data) do
                if not first then result = result .. "," end
                first = false
                result = result .. '"' .. tostring(k) .. '":' .. JsonEncode(v)
            end
        end
        
        return result .. (isArray and "]" or "}")
    elseif type(data) == "string" then
        return '"' .. data:gsub('"', '\\"'):gsub('\n', '\\n'):gsub('\r', '\\r') .. '"'
    elseif type(data) == "number" or type(data) == "boolean" then
        return tostring(data)
    elseif data == nil then
        return "null"
    end
    return '""'
end

-- Serve the web viewer HTML page
SetHttpHandler(function(req, res)
    local path = req.path or ""
    print("[SharedMap HTTP] Incoming request: " .. tostring(path))
    
    if not Config.WebViewer or not Config.WebViewer.enabled then
        res.send('Web viewer is disabled')
        return
    end
    
    -- Main viewer page
    if path == "/viewer" or path == "/viewer/" then
        -- Check password if required
        if Config.WebViewer.requirePassword then
            local auth = req.headers and req.headers["Authorization"]
            local providedPassword = req.headers and req.headers["X-Password"]
            
            -- Also check query param
            if not providedPassword and req.path then
                local passMatch = path:match("password=([^&]+)")
                if passMatch then
                    providedPassword = passMatch
                end
            end
        end
        
        -- Serve the HTML viewer
        local html = LoadResourceFile(GetCurrentResourceName(), "web/viewer.html")
        if html then
            res.writeHead(200, { 
                ["Content-Type"] = "text/html",
                ["Cache-Control"] = "no-cache, no-store, must-revalidate",
                ["Pragma"] = "no-cache"
            })
            res.send(html)
        else
            res.writeHead(404)
            res.send("Viewer not found")
        end
        return
    end
    
    -- API: Get locations list
    if path == "/api/locations" then
        local locations = GetLocations()
        res.writeHead(200, { 
            ["Content-Type"] = "application/json",
            ["Access-Control-Allow-Origin"] = "*"
        })
        res.send(JsonEncode(locations))
        return
    end
    
    -- API: Get map data by location name
    if path:match("^/api/map/") then
        print("[SharedMap] Route matched: /api/map/")
        local locationName = path:gsub("^/api/map/", "")
        print("[SharedMap] Raw location (before decode): " .. tostring(locationName))
        locationName = locationName:gsub("%%20", " ") -- URL decode spaces
        locationName = locationName:gsub("%%([0-9A-Fa-f][0-9A-Fa-f])", function(hex)
            return string.char(tonumber(hex, 16))
        end)
        
        print("[SharedMap] Web API request for map: " .. tostring(locationName))
        
        -- Get client IP for logging
        local clientIp = "Unknown"
        if req.headers then
            clientIp = req.headers["X-Forwarded-For"] or req.headers["x-forwarded-for"] or req.address or "Unknown"
            -- Take first IP if there are multiple (proxy chain)
            if clientIp and clientIp:find(",") then
                clientIp = clientIp:match("([^,]+)")
            end
        end
        
        -- Log web viewer access (rate limited to once per 5 min per IP per map)
        if ShouldLogWebViewerAccess(clientIp, locationName) then
            SendWebhook('webViewerAccess', {
                mapName = locationName,
                ipAddress = clientIp
            })
        end
        
        -- Find the map by name
        print("[SharedMap] Querying database for: " .. tostring(locationName))
        
        MySQL.query("SELECT * FROM djrlincs_sharedmaps WHERE map_name = @name", {
            ['@name'] = locationName
        }, function(result)
            print("[SharedMap] MySQL callback - result: " .. tostring(result and #result or "nil"))
            if result and result[1] then
                local lockStatus = GetLockStatus(result[1].id)
                local mapData = {
                    id = result[1].id,
                    name = result[1].map_name,
                    excalidrawData = result[1].excalidraw_data or '{"elements":[],"appState":{}}',
                    lastEditor = result[1].last_editor_name,
                    updatedAt = result[1].updated_at,
                    isLocked = lockStatus.locked,
                    lockedByName = lockStatus.charName or nil,
                    mapType = GetMapTypeForLocation(locationName) -- Include mapType
                }
                res.writeHead(200, { 
                    ["Content-Type"] = "application/json",
                    ["Access-Control-Allow-Origin"] = "*"
                })
                res.send(JsonEncode(mapData))
            else
                -- Return empty map data with correct mapType (for new maps that haven't been saved yet)
                local emptyMapData = {
                    id = 0,
                    name = locationName,
                    excalidrawData = '{"elements":[],"appState":{}}',
                    lastEditor = nil,
                    updatedAt = nil,
                    isLocked = false,
                    lockedByName = nil,
                    mapType = GetMapTypeForLocation(locationName)
                }
                res.writeHead(200, { 
                    ["Content-Type"] = "application/json",
                    ["Access-Control-Allow-Origin"] = "*"
                })
                res.send(JsonEncode(emptyMapData))
            end
        end)
        return
    end
    
    -- API: Get all maps
    if path == "/api/maps" then
        GetAllMaps(function(maps)
            res.writeHead(200, { 
                ["Content-Type"] = "application/json",
                ["Access-Control-Allow-Origin"] = "*"
            })
            res.send(JsonEncode(maps))
        end)
        return
    end
    
    -- API: Get tile configuration
    if path == "/api/tileconfig" then
        local config = {
            -- In-game NUI settings
            source = (Config.MapTiles and Config.MapTiles.source) or "rockstar",
            variant = (Config.MapTiles and Config.MapTiles.variant) or "detailed",
            maxZoom = ((Config.MapTiles and Config.MapTiles.source == "local") and 7 or 6),
            -- Web viewer uses separate setting (always local full_maps)
            webVariant = (Config.MapTiles and Config.MapTiles.webVariant) or (Config.MapTiles and Config.MapTiles.variant) or "detailed"
        }
        res.writeHead(200, { 
            ["Content-Type"] = "application/json",
            ["Access-Control-Allow-Origin"] = "*"
        })
        res.send(JsonEncode(config))
        return
    end
    
    -- API: Get full map image (for web viewer)
    -- /api/fullmap/{variant}/{zoom} - returns the pre-stitched full map image
    -- Example: /api/fullmap/detailed/4 -> tiles/full_maps/detailed_zoom4.webp
    local variant, zoom = path:match("/api/fullmap/(%w+)/(%d+)")
    if variant and zoom then
        zoom = tonumber(zoom)
        -- Only serve zoom 1-6 (webp format, reasonable size for web)
        if zoom >= 1 and zoom <= 6 then
            local resourceName = GetCurrentResourceName()
            local fullMapPath = string.format("tiles/full_maps/%s_zoom%d.webp", variant, zoom)
            local content = LoadResourceFile(resourceName, fullMapPath)
            if content then
                res.writeHead(200, {
                    ["Content-Type"] = "image/webp",
                    ["Access-Control-Allow-Origin"] = "*",
                    ["Cache-Control"] = "public, max-age=604800" -- Cache for 7 days
                })
                res.send(content)
                return
            else
                -- Try fallback to detailed variant if requested variant not found
                if variant ~= "detailed" then
                    fullMapPath = string.format("tiles/full_maps/detailed_zoom%d.webp", zoom)
                    content = LoadResourceFile(resourceName, fullMapPath)
                    if content then
                        res.writeHead(200, {
                            ["Content-Type"] = "image/webp",
                            ["Access-Control-Allow-Origin"] = "*",
                            ["Cache-Control"] = "public, max-age=604800"
                        })
                        res.send(content)
                        return
                    end
                end
            end
        end
        res.writeHead(404, { ["Access-Control-Allow-Origin"] = "*" })
        res.send("Full map not found")
        return
    end
    
    -- API: Get Guarma map image
    -- /api/guarmamap - returns the Guarma map image
    if path == "/api/guarmamap" then
        local resourceName = GetCurrentResourceName()
        local guarmaPath = "tiles/Guarma/PartialGuarmaMapNEW.webp"
        local content = LoadResourceFile(resourceName, guarmaPath)
        if content then
            res.writeHead(200, {
                ["Content-Type"] = "image/webp",
                ["Access-Control-Allow-Origin"] = "*",
                ["Cache-Control"] = "public, max-age=604800"
            })
            res.send(content)
            return
        end
        res.writeHead(404, { ["Access-Control-Allow-Origin"] = "*" })
        res.send("Guarma map not found")
        return
    end
    
    -- Serve static files from web folder
    if path:match("^/web/") then
        local filePath = path:gsub("^/", "")
        local content = LoadResourceFile(GetCurrentResourceName(), filePath)
        if content then
            local contentType = "text/plain"
            if path:match("%.html$") then contentType = "text/html"
            elseif path:match("%.css$") then contentType = "text/css"
            elseif path:match("%.js$") then contentType = "application/javascript"
            elseif path:match("%.json$") then contentType = "application/json"
            end
            res.writeHead(200, { ["Content-Type"] = contentType })
            res.send(content)
        else
            res.writeHead(404)
            res.send("File not found")
        end
        return
    end
    
    -- Tile serving: /api/tile/{z}/{x}_{y}.webp or /api/tile/{z}/{x}/{y}
    -- Serves local tiles if Config.MapTiles.source == "local", otherwise proxies Rockstar CDN
    if path:match("^/api/tile/") then
        -- Helper function to load local tile (webp only)
        local function tryLoadLocalTile(z, x, y)
            local resourceName = GetCurrentResourceName()
            local variant = (Config.MapTiles and Config.MapTiles.variant) or "detailed"
            local tilePath = string.format("tiles/%s/%s/%s_%s.webp", variant, z, x, y)
            local content = LoadResourceFile(resourceName, tilePath)
            if content then
                return content, "image/webp"
            end
            return nil, nil
        end
        
        -- Try to match local tile format first: /api/tile/3/0_0.webp
        local z, xy = path:match("/api/tile/(%d+)/(%d+_%d+)%.webp")
        
        if Config.MapTiles and Config.MapTiles.source == "local" and z and xy then
            -- Parse x_y from xy
            local x, y = xy:match("(%d+)_(%d+)")
            if x and y then
                local content, contentType = tryLoadLocalTile(z, x, y)
                if content then
                    res.writeHead(200, {
                        ["Content-Type"] = contentType,
                        ["Access-Control-Allow-Origin"] = "*",
                        ["Cache-Control"] = "public, max-age=604800" -- Cache for 7 days
                    })
                    res.send(content)
                    return
                end
            end
            -- Tile not found, return 404
            res.writeHead(404, { ["Access-Control-Allow-Origin"] = "*" })
            res.send("")
            return
        end
        
        -- Rockstar CDN format: /api/tile/3/0/0 (used by web viewer)
        -- Browser always tries local tiles first, then falls back to Rockstar CDN
        local z2, x, y = path:match("/api/tile/(%d+)/(%d+)/(%d+)")
        if z2 and x and y then
            -- Always try local tiles first for browser version
            local content, contentType = tryLoadLocalTile(z2, x, y)
            if content then
                res.writeHead(200, {
                    ["Content-Type"] = contentType,
                    ["Access-Control-Allow-Origin"] = "*",
                    ["Cache-Control"] = "public, max-age=604800" -- Cache for 7 days
                })
                res.send(content)
                return
            end
            
            -- Fall back to Rockstar CDN if local tile not found
            local tileUrl = string.format("https://s.rsg.sc/sc/images/games/RDR2/map/game/%s/%s/%s.jpg", z2, x, y)
            
            PerformHttpRequest(tileUrl, function(statusCode, body, headers)
                if statusCode == 200 and body then
                    res.writeHead(200, {
                        ["Content-Type"] = "image/jpeg",
                        ["Access-Control-Allow-Origin"] = "*",
                        ["Cache-Control"] = "public, max-age=86400" -- Cache for 24 hours
                    })
                    res.send(body)
                else
                    res.writeHead(404, { ["Access-Control-Allow-Origin"] = "*" })
                    res.send("")
                end
            end, "GET")
            return
        end
    end
    
    -- Default response
    print("[SharedMap] No route matched for path: " .. tostring(path))
    res.writeHead(404)
    res.send("Not found")
end)
