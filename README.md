# DJRLincs Shared Map

A collaborative map planning tool for **RedM** servers using [Excalidraw](https://excalidraw.com/) with the RDR2 game map as a background. Perfect for law enforcement, gangs, or any group that needs to plan routes, mark locations, or share tactical information.

![License](https://img.shields.io/badge/license-MIT-blue.svg)
![RedM](https://img.shields.io/badge/platform-RedM-red.svg)
![VORP](https://img.shields.io/badge/framework-VORP-green.svg)

## Features

- **Full Excalidraw Integration** - Draw lines, arrows, shapes, text, freehand sketches, and more
- **RDR2 Map Background** - High-resolution game map with multiple zoom levels (LOD system)
- **Guarma Support** - Separate Guarma island map for those tropical adventures
- **Single Editor Mode** - Only one person edits at a time, preventing conflicts
- **Multiple Map Boards** - Create separate boards for different groups (Sheriff, Gang, etc.)
- **Job-Based Permissions** - Control who can view vs edit each board
- **Real-time Sync** - Viewers see changes as they happen
- **Web Viewer** - View maps from a web browser (read-only)
- **Discord Webhooks** - Log edits and access to Discord
- **Persistent Storage** - All drawings saved to MySQL
- **Auto-save** - Automatic saving while editing
- **Lock Timeout** - Edit locks auto-expire after inactivity
- **Image Support** - Add images via URL (nuuls.com, postimg.cc, etc.)

## Demo Video

[![DJRLincs Shared Map Demo](https://img.youtube.com/vi/8BFyxULqNzA/maxresdefault.jpg)](https://youtu.be/8BFyxULqNzA)

## Requirements

- [VORP Core](https://github.com/VORPCORE/vorp-core-lua)
- [oxmysql](https://github.com/overextended/oxmysql)

## Installation

1. Click the green **Code** button at the top right of this page
2. Select **Download ZIP**
3. Extract the ZIP to your `resources` folder
4. Rename the extracted folder to `djrlincs_sharedmap` (remove `-main` suffix)
5. Add to your `server.cfg`:
   ```
   ensure djrlincs_sharedmap
   ```
6. The database table will be created automatically on first start

### Optional: High-Resolution Map Tiles

By default, the resource uses Rockstar's Social Club CDN for map tiles (works out of the box).

For higher detail (zoom level 7) or offline use, you can download self-hosted tiles:

1. Download tiles from: https://map-tiles.b-cdn.net/files/rdr3%20tiles%20-%20webp.zip
2. Extract to: `djrlincs_sharedmap/tiles/` (structure: `tiles/detailed/3/0_0.webp`, etc.)
3. Set `Config.MapTiles.source = "local"` in config.lua

**Note:** Tile files are ~300-500MB and are NOT included in this repository.

## Configuration

All configuration is in `Config/config.lua`:

### Access Locations

Define where players can access map boards:

```lua
Config.AccessLocations = {
    {
        name = "Valentine Sheriff Office",
        mapGroup = "Sheriff Board",    -- Locations with same mapGroup share the same board
        mapType = "main",              -- "main" or "guarma"
        coords = vector3(-277.62, 805.51, 119.38),
        radius = 2.0,
        blip = true,
        blipSprite = 1047294027,       -- Sheriff badge
        viewRestrictedJobs = { "sheriff", "deputy" },  -- Only these jobs see the blip/prompt
        allowedJobs = { "sheriff", "deputy" },         -- Only these jobs can edit
        webhook = "",                  -- Per-board webhook (optional)
    },
}
```

### Permission Modes

```lua
Config.Permissions = {
    editMode = "job",  -- "all", "ace", "job", or "whitelist"
    acePermission = "djrlincs.sharedmap.edit",
    allowedJobs = { "sheriff", "deputy" },
    whitelist = { 12345, 67890 },  -- Character IDs
}
```

### Discord Webhooks

```lua
Config.Webhook = {
    enabled = true,
    masterUrl = "YOUR_DISCORD_WEBHOOK_URL",
    logMapEdited = true,
    logLockAcquired = true,
    logWebViewer = true,
}
```

### Web Viewer

Access maps from a web browser (read-only):

```lua
Config.WebViewer = {
    enabled = true,
    requirePassword = false,
    password = "changeme",
}
```

Access at: `http://YOUR_SERVER_IP:30120/djrlincs_sharedmap/viewer`

## Usage

1. Walk to a configured access location (shows blip on map if enabled)
2. Press **G** to open the shared map
3. Click **Start Editing** to take control (if you have permission)
4. Use Excalidraw tools to draw routes, markers, notes
5. Changes auto-save, or press **Ctrl+S**
6. Click **Stop Editing** when done
7. Press **ESC** or close button to exit

### Controls

| Key | Action |
|-----|--------|
| **G** | Open map (when near access point) |
| **ESC** | Close map (saves if editing) |
| **Backspace** | Close map (view mode only) |
| **Ctrl+S** | Manual save |
| Scroll/Pinch | Zoom in/out |
| Drag | Pan the map |

## ACE Permission

Add to your server.cfg for admin editing access:
```
add_ace group.admin djrlincs.sharedmap.edit allow
```

## For Developers

### Modifying the UI

The NUI is built with React + TypeScript + Vite:

```bash
cd react-project
npm install
npm run dev    # Development server with hot reload
npm run build  # Build to ../nui/
```

### Project Structure

```
djrlincs_sharedmap/
├── Client/           # Client-side Lua
├── Config/           # Configuration
├── Server/           # Server-side Lua
├── nui/              # Built React app (don't edit directly)
├── react-project/    # React source code
├── sql/              # Database schema
├── tiles/            # Map tile images (optional, download separately)
├── web/              # Web viewer HTML
└── fxmanifest.lua
```

## Troubleshooting

### Map doesn't open
- Check you're within the `radius` of an access location
- Check `viewRestrictedJobs` if the blip/prompt isn't showing
- Enable `Config.Debug = true` and check server console

### Can't edit
- Verify your character's job matches `allowedJobs`
- Check if someone else has the edit lock
- Wait for lock timeout (default 5 minutes) or ask them to release

### Images not loading
- Use direct image URLs (ending in .jpg, .png, .webp)
- Don't use Discord CDN URLs (they expire after 24 hours)
- Don't use Imgur (region blocked in UK and other countries)
- Recommended hosts: nuuls.com, postimg.cc

## Credits

- [Excalidraw](https://github.com/excalidraw/excalidraw) - The amazing drawing library
- [VORP Framework](https://github.com/VORPCORE) - RedM framework
- RDR2 Map Tiles - Rockstar Games / Social Club

## License

MIT License - See [LICENSE](LICENSE) file

## Support

- **Issues:** Open a GitHub issue
- **CFX Forums:** [Forum Thread Link]

---

Made with ❤️ by DJRLincs
