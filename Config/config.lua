Config = {}

-------------------------------------------------------------------------------
-- GENERAL SETTINGS
-------------------------------------------------------------------------------
Config.Debug = false -- Enable debug prints (set to true for troubleshooting)

-------------------------------------------------------------------------------
-- BLIP DEFAULTS
-- Global defaults for blips - can be overridden per-location
-- Sprite list: https://github.com/femga/rdr3_discoveries/tree/master/useful_info_from_rpfs/blip_sprites
-- Color list: https://github.com/femga/rdr3_discoveries/tree/master/useful_info_from_rpfs/blip_modifiers
-------------------------------------------------------------------------------
Config.DefaultBlipSprite = 1047294027  -- Sheriff badge (numeric hash)
Config.DefaultBlipScale = 0.2           -- 0.1 to 1.0
Config.DefaultBlipColor = "BLIP_MODIFIER_MP_COLOR_6" -- Sheriff blue

-- Common sprite hashes:
--   1047294027  = Sheriff badge
--   1475879922  = General store
--   -1327110633 = Stable
--   1879260108  = Saloon
--   249721687   = Bank
--   -145868367  = Gunsmith
--   350569997   = Church
--   -2090472724 = Barber
--   1369919445  = Butcher

-- Common color modifiers:
--   BLIP_MODIFIER_MP_COLOR_1  = White
--   BLIP_MODIFIER_MP_COLOR_2  = Red
--   BLIP_MODIFIER_MP_COLOR_5  = Yellow/Gold
--   BLIP_MODIFIER_MP_COLOR_6  = Light Blue (Sheriff)
--   BLIP_MODIFIER_MP_COLOR_11 = Cyan
--   BLIP_MODIFIER_MP_COLOR_17 = Orange
--   BLIP_MODIFIER_MP_COLOR_21 = Green
--   BLIP_MODIFIER_MP_COLOR_26 = Tan/Brown
--   BLIP_MODIFIER_MP_COLOR_32 = Grey

-------------------------------------------------------------------------------
-- ACCESS LOCATIONS
-- Players must be near these coordinates to open the shared map
-- mapGroup: Locations with the same mapGroup share the same map board
--           If not set, uses the location name as its own unique map
--
-- MAP TYPE (mapType):
--   "main"   = Main RDR2 map with tile loading (default if not specified)
--   "guarma" = Guarma island map (single image, no tiles)
--
-- BLIP SETTINGS:
--   blip = true/false       -- Whether to show a map blip (required)
--   blipSprite, blipScale, blipColor -- OPTIONAL: Only used when blip=true
--                                       Falls back to Config.DefaultBlip* if not set
--
-- VIEW RESTRICTION (viewRestrictedJobs):
--   If set, ONLY players with these jobs can see the prompt AND blip.
--   If NOT set (nil), everyone can see the prompt/blip (but may be view-only).
--   This is different from allowedJobs which controls EDIT permission.
-------------------------------------------------------------------------------
Config.AccessLocations = {
    {
        name = "Valentine Sheriff Office",
        mapGroup = "Sheriff Board", -- Shared with other Sheriff locations
        mapType = "main", -- "main" (default) or "guarma"
        coords = vector3(-277.62, 805.51, 119.38),
        heading = 180.0,
        radius = 2.0,
        blip = true,
        blipSprite = 1047294027,                   -- Sheriff badge (numeric hash)
        blipScale = 0.2,                            -- Optional: override default scale
        blipColor = "BLIP_MODIFIER_MP_COLOR_6",    -- Optional: override default color (Sheriff blue)
        -- VIEW RESTRICTION: Only these jobs can see the prompt/blip (nil = everyone)
        viewRestrictedJobs = { "sheriff", "deputy" },
        -- EDIT RESTRICTION: Only these jobs can edit (still need Start Editing button)
        allowedJobs = { "sheriff", "deputy" },
        -- Per-board webhook (optional - uses master if empty)
        webhook = "",
    },
    {
        name = "Rhodes Sheriff Office",
        mapGroup = "Sheriff Board", -- Same mapGroup = same shared map
        mapType = "main", -- Same mapType as other Sheriff Board locations
        coords = vector3(1232.49, -1295.61, 76.90),
        heading = 0.0,
        radius = 2.0,
        blip = true,
        blipSprite = 1047294027,                   -- Sheriff badge
        blipScale = 0.2,
        blipColor = "BLIP_MODIFIER_MP_COLOR_6",    -- Sheriff blue
        viewRestrictedJobs = { "sheriff", "deputy" }, -- Same view restriction
        allowedJobs = { "sheriff", "deputy" }, -- Same board, same job restrictions
        webhook = "", -- Same board shares the webhook from first location
    },
    {
        name = "Blackwater Offices",
        mapGroup = "Blackwater Board", -- Unique map for this location
        mapType = "main", -- "main" for standard RDR2 map
        coords = vector3(-756.17, -1287.47, 43.53),
        heading = 90.0,
        radius = 2.0,
        blip = true,
        blipSprite = 1047294027,                   -- Sheriff badge
        blipScale = 0.2,
        blipColor = "BLIP_MODIFIER_MP_COLOR_5",    -- Yellow/Gold (different from Sheriff)
        -- viewRestrictedJobs = nil,               -- Everyone can VIEW (see prompt/blip)
        allowedJobs = { "marshal", "sheriff", "lawman" },     -- But only these can EDIT
        webhook = "", -- Uses master webhook
    },
    {
        name = "Pirates of Guarma",
        mapGroup = "Guarma Board", -- Unique Guarma planning board
        mapType = "guarma", -- Uses single Guarma map image instead of tiles
        coords = vector3(-292.08, 791.22, 118.33), -- Near Valentine Sheriff (for testing)
        heading = 180.0,
        radius = 2.0,
        blip = true,
        blipSprite = 1879260108,                   -- Saloon (pirate-ish)
        blipScale = 0.2,
        blipColor = "BLIP_MODIFIER_MP_COLOR_17",   -- Orange (treasure map vibe)
        -- viewRestrictedJobs = nil,               -- Everyone can view
        allowedJobs = {},                          -- Anyone can edit (test board)
        webhook = "",
    },
    -- Example: No blip, just a prompt when nearby (blipSprite/Scale/Color not needed)
    -- {
    --     name = "Secret Hideout",
    --     mapGroup = "Gang Board",
    --     coords = vector3(0.0, 0.0, 0.0),
    --     heading = 0.0,
    --     radius = 2.0,
    --     blip = false,  -- No blip on map, just proximity prompt
    --     viewRestrictedJobs = { "outlaw" },
    --     allowedJobs = { "outlaw" },
    -- },
}

-------------------------------------------------------------------------------
-- PERMISSIONS
-- Who can edit vs view the shared maps
-------------------------------------------------------------------------------
Config.Permissions = {
    -- "all" = everyone can edit
    -- "ace" = requires ace permission (see below)
    -- "job" = requires specific job(s) - checks per-location allowedJobs first
    -- "whitelist" = requires character ID in whitelist
    editMode = "job",

    -- ACE permission required if editMode = "ace"
    acePermission = "djrlincs.sharedmap.edit",

    -- FALLBACK jobs if a location doesn't have its own allowedJobs
    -- When editMode = "job", first checks location.allowedJobs, then this list
    allowedJobs = {
        -- "sheriff",
        -- "deputy",
        -- "marshal",
    },

    -- Character IDs allowed if editMode = "whitelist"
    whitelist = {
        -- 12345,
        -- 67890,
    },
}

-------------------------------------------------------------------------------
-- LOCK SETTINGS
-- Only one person can edit at a time
-------------------------------------------------------------------------------
Config.Lock = {
    timeoutMinutes = 5, -- Lock expires after this many minutes of inactivity
    heartbeatSeconds = 30, -- Client sends heartbeat to keep lock alive
}

-------------------------------------------------------------------------------
-- UI SETTINGS
-------------------------------------------------------------------------------
Config.UI = {
    -- Default map name (fallback when no location is configured)
    defaultMapName = "Main Planning Map",
}

-------------------------------------------------------------------------------
-- WEBHOOK LOGGING (Optional Discord logging)
-------------------------------------------------------------------------------
Config.Webhook = {
    enabled = false, -- Set to true and add your webhook URL to enable Discord logging
    
    -- Master webhook - receives ALL events from all boards
    masterUrl = "", -- Your Discord webhook URL here
    
    -- Web viewer webhook - logs browser access separately
    webViewerUrl = "", -- Leave empty to use master, or set dedicated webhook
    
    -- What events to log
    logMapCreated = true,
    logMapEdited = true,
    logLockAcquired = true,
    logWebViewer = true, -- Log when someone views via web browser
}

-------------------------------------------------------------------------------
-- WEB VIEWER SETTINGS
-- Allow viewing maps via web browser (read-only)
--
-- Web viewer uses pre-stitched full map images (zoom levels 1-6) served
-- directly from the server, avoiding CORS issues with external tile CDNs.
-- Requires the tiles/full_maps/ folder with stitched map images.
-------------------------------------------------------------------------------
Config.WebViewer = {
    enabled = true, -- Web viewer using full map images (no CORS issues)
    
    -- The port to access the web viewer (default is your server port)
    -- Access via: http://YOUR_SERVER_IP:PORT/djrlincs_sharedmap/viewer
    -- Example: http://localhost:30120/djrlincs_sharedmap/viewer
    
    -- Password protection (optional)
    requirePassword = false,
    password = "changeme", -- Change this if requirePassword is true
}

-------------------------------------------------------------------------------
-- MAP TILES SETTINGS
-- Configure where map background tiles come from
-- Both in-game NUI and web viewer use the same tile source
-------------------------------------------------------------------------------
Config.MapTiles = {
    -- TILE SOURCE (affects both in-game NUI and web viewer)
    -- "rockstar" = Use Rockstar Social Club CDN (default, always works)
    -- "local" = Use self-hosted tiles from /tiles folder (higher detail, zoom 7)
    source = "rockstar",
    
    -- Tile variant (only used when source = "local")
    -- "detailed" = Full color detailed map (default)
    -- "darkmode" = Dark themed map
    -- "black" = Black and white map
    variant = "detailed",
    
    -- If using local tiles (source = "local"):
    -- 1. Download from: https://map-tiles.b-cdn.net/files/rdr3%20tiles%20-%20webp.zip
    -- 2. Extract to: resources/[DJR-CUSTOM]/djrlincs_sharedmap/tiles/
    --    Structure should be: tiles/detailed/3/0_0.webp, tiles/darkmode/3/0_0.webp, etc.
    -- 3. Set source = "local" above and choose your preferred variant
    --
    -- Local tiles provide zoom level 7 (higher detail than Rockstar CDN's max of 6)
    -- WARNING: Local tiles are ~300-500MB and will NOT be streamed to clients via FiveM.
    --          They are served via HTTP handler on-demand when the map UI loads.
}

-------------------------------------------------------------------------------
-- LOCALIZATION
-------------------------------------------------------------------------------
Config.Lang = {
    promptView = "View Map",
    mapOpened = "Opened map",
    mapClosed = "Closed map",
    lockAcquired = "You are now editing the map",
    lockDenied = "Map is currently being edited by another player",
    lockReleased = "Editing session ended",
    lockTimeout = "Editing session timed out",
    noPermission = "You don't have permission to edit maps",
    mapSaved = "Map saved successfully",
    mapCreated = "New map created",
    mapDeleted = "Map deleted",
    mapSwitched = "Switched to map: %s",
    viewerJoined = "Now viewing the map",
    editorDisconnected = "The editor has disconnected",
}
