import { Excalidraw } from '@excalidraw/excalidraw';
import { useEffect, useState, useCallback, useRef } from 'react';
import type { ExcalidrawImperativeAPI, BinaryFiles, AppState, BinaryFileData } from '@excalidraw/excalidraw/types/types';
import type { ExcalidrawElement } from '@excalidraw/excalidraw/types/element/types';
import './App.css';

// Check if running in FiveM/RedM NUI
// Check multiple indicators for NUI environment (needed early for config)
const isNUI = (() => {
  try {
    // Check if GetParentResourceName exists and works
    if (typeof (window as any).GetParentResourceName === 'function') {
      return true;
    }
    // Also check if we're in a CEF browser (no location.protocol like http:)
    if (window.location.protocol === 'nui:' || window.location.href.includes('nui://')) {
      return true;
    }
    // If no http/https protocol, likely NUI
    if (!window.location.protocol.startsWith('http')) {
      return true;
    }
    return false;
  } catch {
    // If any error, assume NUI (safer default)
    return true;
  }
})();

// Tile configuration - Rockstar Social Club map tiles
const TILE_URL = 'https://s.rsg.sc/sc/images/games/RDR2/map/game/{z}/{x}/{y}.jpg';
const TILE_SIZE = 256;

// Map type configuration
type MapType = 'main' | 'guarma';

// Guarma map configuration (single image, no tiles available)
const GUARMA_CONFIG = {
  // Browser mode: served from public folder
  // NUI mode: served from resource folder  
  imageUrl: isNUI ? 'nui://djrlincs_sharedmap/tiles/Guarma/PartialGuarmaMapNEW.webp' : '/PartialGuarmaMapNEW.webp',
  width: 1296,
  height: 1424,
  // Scale to similar visual size as main map
  mapSize: 6000, // Slightly smaller than main map's 8192
};

// LOD (Level of Detail) configuration
// Using chunked approach - each chunk is 4x4 tiles (1024px canvas), avoiding browser limits
const LOD_THRESHOLDS = [
  { minZoom: 0, tileZoom: 3 },     // 0-10% = zoom 3 
  { minZoom: 10, tileZoom: 4 },    // 10-50% = zoom 4
  { minZoom: 50, tileZoom: 5 },    // 50-100% = zoom 5
  { minZoom: 100, tileZoom: 6 },   // 100%+ = zoom 6 - max detail
];

// Chunk configuration - each chunk is CHUNK_TILES x CHUNK_TILES tiles
// 4x4 tiles = 1024px canvas per chunk (safe for all browsers)
const CHUNK_TILES = 4;
const CHUNK_SIZE = CHUNK_TILES * TILE_SIZE; // 1024px per chunk canvas

// Get tile zoom level for a given Excalidraw zoom percentage
const getTileZoomForCanvasZoom = (canvasZoom: number): number => {
  const zoomPercent = canvasZoom * 100;
  for (let i = LOD_THRESHOLDS.length - 1; i >= 0; i--) {
    if (zoomPercent >= LOD_THRESHOLDS[i].minZoom) {
      return LOD_THRESHOLDS[i].tileZoom;
    }
  }
  return LOD_THRESHOLDS[0].tileZoom;
};

// Base map scale (consistent across LOD levels)
const BASE_MAP_SIZE = 8192; // Consistent visual size

// Debounce time for auto-save (ms)
const SAVE_DEBOUNCE_MS = 2000;

// Lock heartbeat interval (ms)
const HEARTBEAT_INTERVAL_MS = 30000;

// LOD change debounce (ms) - don't reload tiles too often
const LOD_DEBOUNCE_MS = 200;

const resourceName = (() => {
  try {
    if (typeof (window as any).GetParentResourceName === 'function') {
      return (window as any).GetParentResourceName();
    }
  } catch {}
  return 'djrlincs_sharedmap';
})();

// LocalStorage key for browser testing persistence (per-location)
const getLocalStorageKey = (mapId: number | string) => `djrlincs_sharedmap_data_${mapId}`;

// Default map groups for browser testing (matches Config.AccessLocations mapGroups)
const DEFAULT_LOCATIONS: MapData[] = [
  { id: 1, name: 'Sheriff Board', description: 'Shared Sheriff map board', mapType: 'main' },
  { id: 2, name: 'Blackwater Board', description: 'Blackwater Offices map board', mapType: 'main' },
  { id: 3, name: 'Pirates of Guarma', description: 'Guarma Island planning board', mapType: 'guarma' },
];

// NUI callback helper
const nuiCallback = async (event: string, data: any = {}, mapId?: number) => {
  if (!isNUI) {
    console.log(`[NUI Callback] ${event}:`, data);
    // In browser mode, save to localStorage for testing persistence
    if (event === 'saveMap' && data.data && mapId) {
      try {
        localStorage.setItem(getLocalStorageKey(mapId), data.data);
        console.log(`[Browser Mode] Saved to localStorage for map ${mapId}`);
      } catch (err) {
        console.error('Failed to save to localStorage:', err);
      }
    }
    return;
  }
  try {
    await fetch(`https://${resourceName}/${event}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify(data),
    });
  } catch (error) {
    console.error(`NUI callback error (${event}):`, error);
  }
};

// Load saved data from localStorage (browser mode only)
const loadFromLocalStorage = (mapId: number): string | null => {
  if (isNUI) return null;
  try {
    return localStorage.getItem(getLocalStorageKey(mapId));
  } catch {
    return null;
  }
};

// Helper to fetch image URLs and convert to BinaryFileData for Excalidraw
const fetchImageUrlsToFiles = async (
  imageUrls: Record<string, { url: string; mimeType: string }>
): Promise<BinaryFiles> => {
  const files: BinaryFiles = {};
  
  const fetchPromises = Object.entries(imageUrls).map(async ([id, { url, mimeType }]) => {
    try {
      const response = await fetch(url);
      if (!response.ok) {
        console.warn(`Failed to fetch image ${id} from ${url}: ${response.status}`);
        return;
      }
      const blob = await response.blob();
      const dataUrl = await new Promise<string>((resolve, reject) => {
        const reader = new FileReader();
        reader.onloadend = () => resolve(reader.result as string);
        reader.onerror = reject;
        reader.readAsDataURL(blob);
      });
      
      files[id] = {
        id,
        dataURL: dataUrl,
        mimeType: mimeType || 'image/png',
        created: Date.now(),
        lastRetrieved: Date.now(),
        sourceUrl: url, // Preserve URL for future saves
      } as any;
    } catch (err) {
      console.warn(`Failed to load image ${id} from ${url}:`, err);
    }
  });
  
  await Promise.all(fetchPromises);
  return files;
};

interface MapData {
  id: number;
  name: string;
  description?: string;
  excalidrawData?: string;
  lockedBy?: number;
  lockedByName?: string;
  isLocked?: boolean;
  canEdit?: boolean;
  hasPermission?: boolean;
  mapType?: MapType;
}

interface NUIMessage {
  type: string;
  mapData?: MapData;
  playerName?: string;
  data?: string;
  isLocked?: boolean;
  lockedBy?: number;
  lockedByName?: string;
  canEdit?: boolean;
  hasPermission?: boolean;
}

function App() {
  const [excalidrawAPI, setExcalidrawAPI] = useState<ExcalidrawImperativeAPI | null>(null);
  const [mapLoaded, setMapLoaded] = useState(false);
  // ALWAYS start hidden - show only when NUI message received OR confirmed browser mode
  const [isVisible, setIsVisible] = useState(false);
  const [isFullscreen, setIsFullscreen] = useState(false); // Start in windowed mode
  const [canEdit, setCanEdit] = useState(false);
  const [hasPermission, setHasPermission] = useState(false);
  const [isLocked, setIsLocked] = useState(false);
  const [lockedByName, setLockedByName] = useState<string>('');
  const [currentMapId, setCurrentMapId] = useState<number>(1);
  const [currentMapName, setCurrentMapName] = useState<string>('');
  const [maps] = useState<MapData[]>(isNUI ? [] : DEFAULT_LOCATIONS);
  const [_playerName, setPlayerName] = useState<string>('');
  const [savedElements, setSavedElements] = useState<ExcalidrawElement[]>([]);
  const [currentTileZoom, setCurrentTileZoom] = useState<number>(4);
  const [isLoadingTiles, setIsLoadingTiles] = useState(false);
  const [loadingProgress, setLoadingProgress] = useState<string>('');
  const [_loadedChunkCount, setLoadedChunkCount] = useState<number>(0);
  const [showImageUrlModal, setShowImageUrlModal] = useState(false);
  const [imageUrlInput, setImageUrlInput] = useState('');
  const [imageUrlError, setImageUrlError] = useState('');
  const [currentMapType, setCurrentMapType] = useState<MapType>('main');
  
  const saveTimeoutRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const heartbeatIntervalRef = useRef<ReturnType<typeof setInterval> | null>(null);
  const lastSavedDataRef = useRef<string>('');
  const lodDebounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  const lastTileZoomRef = useRef<number>(4);
  
  // Chunk-based tile loading refs  
  const loadedChunksRef = useRef<Set<string>>(new Set()); // Track loaded chunks by "zoom-cx-cy"
  const chunkCanvasesRef = useRef<Map<string, HTMLCanvasElement>>(new Map()); // Cache chunk canvases
  const lastViewportRef = useRef<{x: number, y: number, zoom: number}>({x: 0, y: 0, zoom: 1});
  const viewportDebounceRef = useRef<ReturnType<typeof setTimeout> | null>(null);
  
  // Pending image URLs to load after map is ready
  const pendingImageUrlsRef = useRef<Record<string, { url: string; mimeType: string }> | null>(null);

  // Load from localStorage on mount and when map changes (browser testing only)
  useEffect(() => {
    if (!isNUI) {
      // In browser mode, enable visibility and edit mode
      setIsVisible(true);
      setCanEdit(true);
      setHasPermission(true);
      
      // Find the current map and set name + type
      const currentMap = DEFAULT_LOCATIONS.find(m => m.id === currentMapId);
      setCurrentMapName(currentMap?.name || 'Test Map');
      setCurrentMapType(currentMap?.mapType ?? 'main');
      
      // Show the root element
      document.getElementById('root')?.classList.add('visible');
      
      const savedData = loadFromLocalStorage(currentMapId);
      if (savedData) {
        try {
          const parsed = JSON.parse(savedData);
          if (parsed.elements && Array.isArray(parsed.elements)) {
            // Filter out background map elements (we'll add our own fresh ones)
            const userElements = parsed.elements.filter(
              (el: ExcalidrawElement) =>
                el.id !== 'rdr2-map-background' &&
                el.id !== 'guarma-map-background' &&
                !String(el.id).startsWith('chunk-') &&
                !String(el.id).startsWith('guarma-bg-')
            );
            console.log(`[Browser Mode] Loaded ${userElements.length} elements from localStorage for map ${currentMapId}`);
            setSavedElements(userElements);
            
            // Store pending images - they'll be loaded after map is ready
            if (parsed.imageUrls && Object.keys(parsed.imageUrls).length > 0) {
              pendingImageUrlsRef.current = parsed.imageUrls;
              console.log(`[Browser Mode] Queued ${Object.keys(parsed.imageUrls).length} images to load`);
            } else if (parsed.files && Object.keys(parsed.files).length > 0) {
              // Legacy: convert files to imageUrls format
              const legacyUrls: Record<string, { url: string; mimeType: string }> = {};
              for (const [id, file] of Object.entries(parsed.files as Record<string, any>)) {
                if (file.sourceUrl) {
                  legacyUrls[id] = { url: file.sourceUrl, mimeType: file.mimeType };
                }
              }
              if (Object.keys(legacyUrls).length > 0) {
                pendingImageUrlsRef.current = legacyUrls;
              }
            }
          }
        } catch (err) {
          console.error('Failed to parse localStorage data:', err);
        }
      } else {
        // No saved data for this map, clear elements
        setSavedElements([]);
      }
    }
  }, [currentMapId]);

  // Force background color when Excalidraw API is ready
  useEffect(() => {
    if (excalidrawAPI) {
      excalidrawAPI.updateScene({
        appState: {
          viewBackgroundColor: '#fdfdfd',
          zoom: { value: 0.3 as any },
        },
      });
    }
  }, [excalidrawAPI]);

  // Load pending images after map is ready
  useEffect(() => {
    if (!excalidrawAPI || !mapLoaded) return;
    
    const pendingUrls = pendingImageUrlsRef.current;
    if (!pendingUrls || Object.keys(pendingUrls).length === 0) return;
    
    // Clear the ref so we don't load twice
    pendingImageUrlsRef.current = null;
    
    console.log(`[SharedMap] Loading ${Object.keys(pendingUrls).length} pending images...`);
    
    fetchImageUrlsToFiles(pendingUrls).then(files => {
      if (Object.keys(files).length > 0) {
        excalidrawAPI.addFiles(Object.values(files));
        console.log(`[SharedMap] Added ${Object.keys(files).length} images, refreshing scene...`);
        
        // Force scene refresh to show the images
        const currentElements = excalidrawAPI.getSceneElements();
        excalidrawAPI.updateScene({
          elements: [...currentElements],
        });
      }
    }).catch(err => {
      console.error('[SharedMap] Failed to load pending images:', err);
    });
  }, [excalidrawAPI, mapLoaded]);

  // Intercept the native image button to show our URL modal instead
  useEffect(() => {
    if (!excalidrawAPI) return;
    
    const interceptImageButton = () => {
      // Find the image tool button in the Excalidraw toolbar
      const imageButton = document.querySelector('[data-testid="toolbar-image"]');
      if (imageButton && !imageButton.hasAttribute('data-intercepted')) {
        imageButton.setAttribute('data-intercepted', 'true');
        
        // Add click handler that shows our modal
        imageButton.addEventListener('click', (e) => {
          e.preventDefault();
          e.stopPropagation();
          if (canEdit) {
            setShowImageUrlModal(true);
          }
        }, true); // Use capture phase to intercept before Excalidraw
        
        console.log('[SharedMap] Image button intercepted for URL-based insertion');
      }
    };
    
    // Try to intercept immediately and also after a delay (in case toolbar loads late)
    interceptImageButton();
    const timer = setTimeout(interceptImageButton, 500);
    const timer2 = setTimeout(interceptImageButton, 1500);
    
    return () => {
      clearTimeout(timer);
      clearTimeout(timer2);
    };
  }, [excalidrawAPI, canEdit]);

  // =========================================================================
  // SAVE AND CLOSE FUNCTIONS (must be defined before ESC handler)
  // =========================================================================

  const saveToServer = useCallback((immediate = false) => {
    if (!excalidrawAPI || !canEdit) return;
    
    // Get all elements except the background map chunks
    const elements = excalidrawAPI.getSceneElements().filter(
      el => el.id !== 'rdr2-map-background' && 
            el.id !== 'guarma-map-background' && 
            !el.isDeleted && 
            !String(el.id).startsWith('chunk-') &&
            !String(el.id).startsWith('guarma-bg-')
    );
    
    // Get user-added files (images) - exclude map tile chunks
    const allFiles = excalidrawAPI.getFiles();
    const imageUrls: Record<string, { url: string; mimeType: string }> = {};
    const files: Record<string, { dataURL: string; mimeType: string }> = {};
    
    // Max size for inline base64 images (100KB each)
    const MAX_INLINE_IMAGE_SIZE = 100 * 1024;
    
    for (const [fileId, fileData] of Object.entries(allFiles)) {
      // Skip chunk files (map tiles) and guarma background
      if (!fileId.startsWith('chunk-') && !fileId.startsWith('guarma-bg-') && !fileId.startsWith('full-map-bg-')) {
        const sourceUrl = (fileData as any).sourceUrl;
        if (sourceUrl) {
          // Save URL reference (efficient for external images)
          imageUrls[fileId] = {
            url: sourceUrl,
            mimeType: fileData.mimeType,
          };
        } else if (fileData.dataURL) {
          // No URL - save base64 if small enough (e.g., pasted images)
          const dataUrlStr = String(fileData.dataURL);
          if (dataUrlStr.length <= MAX_INLINE_IMAGE_SIZE) {
            files[fileId] = {
              dataURL: dataUrlStr,
              mimeType: fileData.mimeType,
            };
          } else {
            console.warn(`Skipping large image ${fileId} (${(dataUrlStr.length / 1024).toFixed(1)}KB > 100KB limit)`);
          }
        }
      }
    }
    
    const dataToSave = JSON.stringify({
      elements,
      appState: {},
      imageUrls, // URL references
      files,     // Base64 data for small pasted images
    });
    
    // Check total save size (max 5MB)
    const MAX_SAVE_SIZE = 5 * 1024 * 1024;
    if (dataToSave.length > MAX_SAVE_SIZE) {
      const sizeMB = (dataToSave.length / (1024 * 1024)).toFixed(2);
      console.error(`[SharedMap] Save data too large: ${sizeMB}MB (max 5MB). Try removing some elements.`);
      return;
    }
    
    // Don't save if nothing changed
    if (dataToSave === lastSavedDataRef.current) return;
    
    const doSave = () => {
      lastSavedDataRef.current = dataToSave;
      nuiCallback('saveMap', { data: dataToSave }, currentMapId);
    };
    
    if (immediate) {
      if (saveTimeoutRef.current) {
        clearTimeout(saveTimeoutRef.current);
      }
      doSave();
    } else {
      // Debounce saves
      if (saveTimeoutRef.current) {
        clearTimeout(saveTimeoutRef.current);
      }
      saveTimeoutRef.current = setTimeout(doSave, SAVE_DEBOUNCE_MS);
    }
  }, [excalidrawAPI, canEdit, currentMapId]);

  const closeMap = useCallback(() => {
    // ALWAYS force save pending changes before closing if we have edit permission
    if (canEdit && excalidrawAPI) {
      console.log('[SharedMap] ESC pressed - forcing save before close');
      saveToServer(true);
    }
    
    // Clear heartbeat
    if (heartbeatIntervalRef.current) {
      clearInterval(heartbeatIntervalRef.current);
    }
    
    // Clear chunk caches so they reload on next open
    loadedChunksRef.current.clear();
    chunkCanvasesRef.current.clear();
    lastSavedDataRef.current = '';
    lastTileZoomRef.current = 4;
    lastViewportRef.current = { x: 0, y: 0, zoom: 1 };
    
    setIsVisible(false);
    // Hide the root element
    document.getElementById('root')?.classList.remove('visible');
    setMapLoaded(false);
    setSavedElements([]);
    setLoadedChunkCount(0);
    
    // Notify Lua
    nuiCallback('close');
  }, [canEdit, excalidrawAPI, saveToServer]);

  // Request edit lock from server
  const requestEditLock = useCallback(() => {
    nuiCallback('requestLock');
  }, []);

  // Release edit lock and return to view-only mode
  const releaseEditLock = useCallback(() => {
    // Force save any pending changes before releasing
    if (excalidrawAPI) {
      console.log('[SharedMap] Releasing lock - saving changes first');
      saveToServer(true);
    }
    
    // Clear heartbeat
    if (heartbeatIntervalRef.current) {
      clearInterval(heartbeatIntervalRef.current);
      heartbeatIntervalRef.current = null;
    }
    
    // Reset to view-only mode immediately for responsiveness
    setCanEdit(false);
    setIsLocked(false);
    setLockedByName('');
    
    // Notify server to release the lock
    nuiCallback('releaseLock');
  }, [excalidrawAPI, saveToServer]);

  // Track ESC key presses for double-tap emergency close
  const lastEscPressRef = useRef<number>(0);
  const DOUBLE_TAP_THRESHOLD = 500; // ms

  // Handle ESC key to close (with double-tap recovery)
  useEffect(() => {
    const handleKeyDown = (e: KeyboardEvent) => {
      // Emergency close: Backspace when in view-only mode
      if (e.key === 'Backspace' && isVisible && !canEdit) {
        // Only if not focused on an input
        const activeElement = document.activeElement;
        if (!activeElement || (activeElement.tagName !== 'INPUT' && activeElement.tagName !== 'TEXTAREA')) {
          e.preventDefault();
          console.log('[SharedMap] Backspace pressed in view mode - closing');
          closeMap();
          return;
        }
      }
      
      if (e.key === 'Escape' && isVisible) {
        const now = Date.now();
        
        // If modal is open, close it instead of the whole map
        if (showImageUrlModal) {
          setShowImageUrlModal(false);
          setImageUrlInput('');
          setImageUrlError('');
          lastEscPressRef.current = 0; // Reset double-tap
          return;
        }
        
        // Check for double-tap ESC (emergency close even if editing)
        if (canEdit && (now - lastEscPressRef.current) < DOUBLE_TAP_THRESHOLD) {
          console.log('[SharedMap] Double-ESC detected - emergency close');
          // Force release lock and close
          releaseEditLock();
          setTimeout(() => closeMap(), 100); // Brief delay to ensure lock release
          lastEscPressRef.current = 0;
          return;
        }
        
        lastEscPressRef.current = now;
        closeMap();
      }
    };
    
    window.addEventListener('keydown', handleKeyDown);
    return () => window.removeEventListener('keydown', handleKeyDown);
  }, [isVisible, showImageUrlModal, closeMap, canEdit, releaseEditLock]);

  // Listen for NUI messages from Lua
  useEffect(() => {
    const handleMessage = (event: MessageEvent<NUIMessage>) => {
      const data = event.data;
      
      switch (data.type) {
        case 'openMap':
          if (data.mapData) {
            setCurrentMapId(data.mapData.id);
            setCurrentMapName(data.mapData.name ?? 'Unknown Location');
            setHasPermission(data.mapData.hasPermission ?? false);
            setCanEdit(data.mapData.canEdit ?? false);
            setIsLocked(data.mapData.isLocked ?? false);
            setLockedByName(data.mapData.lockedByName ?? '');
            setPlayerName(data.playerName ?? '');
            setCurrentMapType(data.mapData.mapType ?? 'main');
            
            // Parse saved excalidraw data
            if (data.mapData.excalidrawData) {
              try {
                const parsed = JSON.parse(data.mapData.excalidrawData);
                if (parsed.elements && Array.isArray(parsed.elements)) {
                  // Filter out background map elements (we'll add our own fresh ones)
                  const userElements = parsed.elements.filter(
                    (el: ExcalidrawElement) => 
                      el.id !== 'rdr2-map-background' && 
                      el.id !== 'guarma-map-background' && 
                      !String(el.id).startsWith('chunk-') &&
                      !String(el.id).startsWith('guarma-bg-')
                  );
                  setSavedElements(userElements);
                  
                  // Store pending images - they'll be loaded after map is ready
                  if (parsed.imageUrls && Object.keys(parsed.imageUrls).length > 0) {
                    pendingImageUrlsRef.current = parsed.imageUrls;
                    console.log(`[NUI] Queued ${Object.keys(parsed.imageUrls).length} images to load`);
                  } else if (parsed.files && Object.keys(parsed.files).length > 0) {
                    // Legacy: convert files to imageUrls format for the loader
                    // (files that have a sourceUrl can be re-fetched)
                    const legacyUrls: Record<string, { url: string; mimeType: string }> = {};
                    for (const [id, file] of Object.entries(parsed.files as Record<string, any>)) {
                      if (file.sourceUrl) {
                        legacyUrls[id] = { url: file.sourceUrl, mimeType: file.mimeType };
                      } else if (file.dataURL && excalidrawAPI) {
                        // No URL, use base64 directly (truly legacy data)
                        excalidrawAPI.addFiles([file]);
                      }
                    }
                    if (Object.keys(legacyUrls).length > 0) {
                      pendingImageUrlsRef.current = legacyUrls;
                    }
                  }
                }
              } catch (err) {
                console.error('Failed to parse saved excalidraw data:', err);
              }
            }
            
            // Clear chunk caches to force reload
            loadedChunksRef.current.clear();
            chunkCanvasesRef.current.clear();
            lastSavedDataRef.current = '';
            lastTileZoomRef.current = 4;
            lastViewportRef.current = { x: 0, y: 0, zoom: 1 };
            setLoadedChunkCount(0);
            
            setIsVisible(true);
            // Show the root element (hidden by default CSS)
            document.getElementById('root')?.classList.add('visible');
            setMapLoaded(false); // Reset to trigger reload
          }
          break;
          
        case 'closeMap':
          closeMap();
          break;
          
        case 'updateMap':
          // Another player saved - update our view
          if (data.data && excalidrawAPI) {
            try {
              const parsed = JSON.parse(data.data);
              if (parsed.elements) {
                const userElements = parsed.elements.filter(
                  (el: ExcalidrawElement) => 
                    el.id !== 'rdr2-map-background' && 
                    el.id !== 'guarma-map-background' && 
                    !String(el.id).startsWith('chunk-') &&
                    !String(el.id).startsWith('guarma-bg-')
                );
                const currentElements = excalidrawAPI.getSceneElements();
                // Keep all background elements (main map chunks or guarma background)
                const bgElements = currentElements.filter(el => 
                  el.id === 'rdr2-map-background' || 
                  el.id === 'guarma-map-background' || 
                  String(el.id).startsWith('chunk-') ||
                  String(el.id).startsWith('guarma-bg-')
                );
                if (bgElements.length > 0) {
                  excalidrawAPI.updateScene({
                    elements: [...bgElements, ...userElements],
                  });
                }
                
                // Update images - prefer imageUrls (new), fallback to files (legacy)
                if (parsed.imageUrls && Object.keys(parsed.imageUrls).length > 0) {
                  fetchImageUrlsToFiles(parsed.imageUrls).then(files => {
                    if (Object.keys(files).length > 0) {
                      excalidrawAPI.addFiles(Object.values(files));
                      // Force refresh to show images
                      const elems = excalidrawAPI.getSceneElements();
                      excalidrawAPI.updateScene({ elements: [...elems] });
                    }
                  });
                } else if (parsed.files) {
                  excalidrawAPI.addFiles(Object.values(parsed.files));
                }
              }
            } catch (err) {
              console.error('Failed to parse update data:', err);
            }
          }
          setLockedByName(data.lockedByName ?? '');
          break;
          
        case 'lockStatus':
          setIsLocked(data.isLocked ?? false);
          setLockedByName(data.lockedByName ?? '');
          setCanEdit(data.canEdit ?? false);
          break;
          
        case 'lockReleased':
          // Lock was released (either by us, timeout, or server)
          setCanEdit(false);
          setIsLocked(false);
          setLockedByName('');
          break;
          
        case 'editorChanged':
          // Another player started/stopped editing
          if (data.isLocked) {
            setIsLocked(true);
            setLockedByName(data.lockedByName ?? '');
          } else {
            setIsLocked(false);
            setLockedByName('');
          }
          break;
      }
    };
    
    window.addEventListener('message', handleMessage);
    return () => window.removeEventListener('message', handleMessage);
  }, [excalidrawAPI]);

  // Heartbeat to keep lock alive
  useEffect(() => {
    if (canEdit && isVisible) {
      heartbeatIntervalRef.current = setInterval(() => {
        nuiCallback('refreshLock');
      }, HEARTBEAT_INTERVAL_MS);
    }
    
    return () => {
      if (heartbeatIntervalRef.current) {
        clearInterval(heartbeatIntervalRef.current);
      }
    };
  }, [canEdit, isVisible]);

  // Handle switching to a different map/location (browser testing only)
  const handleMapChange = useCallback((newMapId: number) => {
    if (newMapId === currentMapId) return;
    
    // Save current map before switching
    if (canEdit && excalidrawAPI) {
      saveToServer(true);
    }
    
    // Clear chunk cache for new map view  
    loadedChunksRef.current.clear();
    chunkCanvasesRef.current.clear();
    setLoadedChunkCount(0);
    lastSavedDataRef.current = '';
    
    // Find the map and set name + type
    const newMap = maps.find(m => m.id === newMapId);
    if (newMap) {
      setCurrentMapName(newMap.name);
      setCurrentMapType(newMap.mapType ?? 'main');
    }
    
    // Reset mapLoaded so initial load triggers again with new savedElements
    setMapLoaded(false);
    
    // Switch to new map - this will trigger the useEffect to load from localStorage
    setCurrentMapId(newMapId);
    
    // Clear current elements (will be repopulated on initial load)
    if (excalidrawAPI) {
      excalidrawAPI.updateScene({
        elements: [],
      });
    }
    
    console.log(`Switched to map ${newMapId}: ${newMap?.name}`);
  }, [currentMapId, canEdit, excalidrawAPI, saveToServer, maps]);

  // Insert image from URL
  const insertImageFromUrl = useCallback(async (url: string) => {
    if (!excalidrawAPI || !url.trim()) return;
    
    setImageUrlError('');
    
    // URL validation - block problematic domains
    const blockedDomains = [
      // Discord - URLs expire after 24 hours (2025 policy change)
      'discord.com',
      'discordapp.com',
      'cdn.discord.com',
      'cdn.discordapp.com',
      'media.discordapp.net',
      // Imgur - region blocked in some countries (UK)
      'imgur.com',
      'i.imgur.com'
    ];
    
    const lowerUrl = url.toLowerCase();
    
    for (const domain of blockedDomains) {
      if (lowerUrl.includes(domain)) {
        if (domain.includes('discord')) {
          setImageUrlError('Discord URLs are not allowed. Discord CDN links expire after 24 hours. Use https://nuuls.com/ or https://postimg.cc/ instead.');
        } else if (domain.includes('imgur')) {
          setImageUrlError('Imgur is blocked in some regions (UK). Use https://nuuls.com/ or https://postimg.cc/ instead.');
        } else {
          setImageUrlError('This image host is not supported. Use https://nuuls.com/ or https://postimg.cc/ instead.');
        }
        return;
      }
    }
    
    // Basic URL format validation
    if (!lowerUrl.startsWith('http://') && !lowerUrl.startsWith('https://')) {
      setImageUrlError('URL must start with http:// or https://');
      return;
    }
    
    // Check for valid image URL
    const hasImageExtension = 
      lowerUrl.endsWith('.jpg') || 
      lowerUrl.endsWith('.jpeg') || 
      lowerUrl.endsWith('.png') || 
      lowerUrl.endsWith('.webp') ||
      lowerUrl.includes('nuuls.com') ||
      lowerUrl.includes('postimg.cc') ||
      lowerUrl.includes('i.postimg.cc');
    
    if (!hasImageExtension) {
      setImageUrlError('Please use a direct image URL (ending in .jpg, .png, .webp) or use nuuls.com or postimg.cc');
      return;
    }
    
    try {
      // Fetch the image
      const response = await fetch(url);
      if (!response.ok) {
        throw new Error('Failed to fetch image');
      }
      
      const blob = await response.blob();
      
      // Check image size (max 5MB)
      const MAX_IMAGE_SIZE = 5 * 1024 * 1024; // 5MB
      if (blob.size > MAX_IMAGE_SIZE) {
        const sizeMB = (blob.size / (1024 * 1024)).toFixed(2);
        setImageUrlError(`Image is too large (${sizeMB}MB). Maximum size is 5MB. Please compress the image or use a smaller one.`);
        return;
      }
      
      const mimeType = blob.type || 'image/png';
      
      // Convert to base64
      const reader = new FileReader();
      const dataUrl = await new Promise<string>((resolve, reject) => {
        reader.onload = () => resolve(reader.result as string);
        reader.onerror = reject;
        reader.readAsDataURL(blob);
      });
      
      // Get image dimensions
      const img = new Image();
      const dimensions = await new Promise<{width: number, height: number}>((resolve, reject) => {
        img.onload = () => resolve({ width: img.width, height: img.height });
        img.onerror = reject;
        img.src = dataUrl;
      });
      
      // Generate unique ID
      const fileId = `img-${Date.now()}-${Math.random().toString(36).substr(2, 9)}`;
      
      // Get center of current viewport
      const appState = excalidrawAPI.getAppState();
      const centerX = -appState.scrollX;
      const centerY = -appState.scrollY;
      
      // Scale image to reasonable size (max 500px)
      const maxSize = 500;
      let width = dimensions.width;
      let height = dimensions.height;
      if (width > maxSize || height > maxSize) {
        const scale = maxSize / Math.max(width, height);
        width *= scale;
        height *= scale;
      }
      
      // Create file data with source URL for efficient storage
      const fileData: BinaryFileData = {
        id: fileId as any,
        mimeType: mimeType as any,
        dataURL: dataUrl as any,
        created: Date.now(),
        sourceUrl: url, // Store original URL for saving (not base64)
      } as any;
      
      // Create image element
      const imageElement: ExcalidrawElement = {
        id: fileId,
        type: 'image',
        x: centerX - width / 2,
        y: centerY - height / 2,
        width,
        height,
        angle: 0,
        strokeColor: 'transparent',
        backgroundColor: 'transparent',
        fillStyle: 'solid',
        strokeWidth: 0,
        strokeStyle: 'solid',
        roughness: 0,
        opacity: 100,
        groupIds: [],
        frameId: null,
        roundness: null,
        seed: Math.floor(Math.random() * 100000),
        version: 1,
        versionNonce: Math.floor(Math.random() * 100000),
        isDeleted: false,
        boundElements: null,
        updated: Date.now(),
        link: null,
        locked: false,
        fileId: fileId,
        status: 'saved',
        scale: [1, 1],
      } as any;
      
      // Add file and element
      excalidrawAPI.addFiles([fileData]);
      const currentElements = excalidrawAPI.getSceneElements();
      excalidrawAPI.updateScene({
        elements: [...currentElements, imageElement],
      });
      
      // Close modal
      setShowImageUrlModal(false);
      setImageUrlInput('');
      console.log('Image inserted from URL:', url);
      
    } catch (error) {
      console.error('Failed to insert image from URL:', error);
      setImageUrlError('Failed to load image. Make sure the URL is accessible and points to a valid image.');
    }
  }, [excalidrawAPI]);

  // Calculate which chunks are visible in the current viewport
  const getVisibleChunks = useCallback((scrollX: number, scrollY: number, zoom: number, tileZoom: number) => {
    const gridSize = Math.pow(2, tileZoom); // Total tiles in each dimension
    const numChunks = Math.ceil(gridSize / CHUNK_TILES); // Number of chunks in each dimension
    const chunkWorldSize = BASE_MAP_SIZE / numChunks; // Size of each chunk in Excalidraw coords
    
    // Viewport size in world coordinates
    const viewportWidth = window.innerWidth / zoom;
    const viewportHeight = window.innerHeight / zoom;
    
    // Map bounds (centered at origin)
    const mapLeft = -BASE_MAP_SIZE / 2;
    const mapTop = -BASE_MAP_SIZE / 2;
    
    // Center of viewport in world coordinates (Excalidraw scroll is negated)
    const centerX = -scrollX;
    const centerY = -scrollY;
    
    // Viewport bounds
    const viewLeft = centerX - viewportWidth / 2;
    const viewRight = centerX + viewportWidth / 2;
    const viewTop = centerY - viewportHeight / 2;
    const viewBottom = centerY + viewportHeight / 2;
    
    // Convert to chunk indices with buffer
    const startChunkX = Math.max(0, Math.floor((viewLeft - mapLeft) / chunkWorldSize) - 1);
    const endChunkX = Math.min(numChunks - 1, Math.ceil((viewRight - mapLeft) / chunkWorldSize) + 1);
    const startChunkY = Math.max(0, Math.floor((viewTop - mapTop) / chunkWorldSize) - 1);
    const endChunkY = Math.min(numChunks - 1, Math.ceil((viewBottom - mapTop) / chunkWorldSize) + 1);
    
    const chunks: Array<{cx: number, cy: number}> = [];
    for (let cy = startChunkY; cy <= endChunkY; cy++) {
      for (let cx = startChunkX; cx <= endChunkX; cx++) {
        chunks.push({cx, cy});
      }
    }
    
    return { chunks, numChunks, chunkWorldSize };
  }, []);

  // Load a single chunk (4x4 tiles) and return its canvas
  const loadChunk = useCallback(async (
    cx: number, 
    cy: number, 
    tileZoom: number
  ): Promise<HTMLCanvasElement> => {
    const canvas = document.createElement('canvas');
    canvas.width = CHUNK_SIZE;
    canvas.height = CHUNK_SIZE;
    const ctx = canvas.getContext('2d')!;
    // Don't fill - leave transparent
    
    const gridSize = Math.pow(2, tileZoom);
    const startTileX = cx * CHUNK_TILES;
    const startTileY = cy * CHUNK_TILES;
    
    // Load tiles for this chunk
    const loadTile = (localX: number, localY: number): Promise<void> => {
      return new Promise((resolve) => {
        const tileX = startTileX + localX;
        const tileY = startTileY + localY;
        
        // Skip tiles outside the map
        if (tileX >= gridSize || tileY >= gridSize) {
          resolve();
          return;
        }
        
        const img = new Image();
        img.crossOrigin = 'anonymous';
        img.onload = () => {
          ctx.drawImage(img, localX * TILE_SIZE, localY * TILE_SIZE, TILE_SIZE, TILE_SIZE);
          resolve();
        };
        img.onerror = () => resolve();
        img.src = TILE_URL.replace('{z}', String(tileZoom)).replace('{x}', String(tileX)).replace('{y}', String(tileY));
      });
    };
    
    // Load all tiles in chunk in parallel
    const tilePromises: Promise<void>[] = [];
    for (let ly = 0; ly < CHUNK_TILES; ly++) {
      for (let lx = 0; lx < CHUNK_TILES; lx++) {
        tilePromises.push(loadTile(lx, ly));
      }
    }
    await Promise.all(tilePromises);
    
    return canvas;
  }, []);

  // Load visible chunks and update Excalidraw
  const loadVisibleChunks = useCallback(async (
    scrollX: number, 
    scrollY: number, 
    zoom: number, 
    tileZoom: number, 
    isInitialLoad: boolean = false
  ) => {
    if (!excalidrawAPI) return;
    
    const { chunks, numChunks, chunkWorldSize } = getVisibleChunks(scrollX, scrollY, zoom, tileZoom);
    
    // Filter to chunks we haven't loaded yet
    const newChunks = chunks.filter(c => {
      const key = `${tileZoom}-${c.cx}-${c.cy}`;
      return !loadedChunksRef.current.has(key);
    });
    
    if (newChunks.length === 0 && !isInitialLoad) {
      console.log('All visible chunks already loaded');
      return;
    }
    
    setIsLoadingTiles(true);
    console.log(`Loading ${newChunks.length} new chunks at zoom ${tileZoom}`);
    
    let loadedCount = 0;
    const newElements: ExcalidrawElement[] = [];
    const newFiles: BinaryFiles = {};
    
    // Map origin
    const mapLeft = -BASE_MAP_SIZE / 2;
    const mapTop = -BASE_MAP_SIZE / 2;
    
    // Load chunks
    for (const chunk of newChunks) {
      const key = `${tileZoom}-${chunk.cx}-${chunk.cy}`;
      setLoadingProgress(`Loading chunk ${++loadedCount}/${newChunks.length}...`);
      
      const canvas = await loadChunk(chunk.cx, chunk.cy, tileZoom);
      chunkCanvasesRef.current.set(key, canvas);
      loadedChunksRef.current.add(key);
      
      // Create Excalidraw image element for this chunk
      const fileId = `chunk-${key}-${Date.now()}` as any;
      const dataUrl = canvas.toDataURL('image/jpeg', 0.95);
      
      // Position chunk in world coordinates
      const chunkX = mapLeft + chunk.cx * chunkWorldSize;
      const chunkY = mapTop + chunk.cy * chunkWorldSize;
      
      const imageElement: ExcalidrawElement = {
        id: `chunk-${key}`,
        type: 'image',
        x: chunkX,
        y: chunkY,
        width: chunkWorldSize,
        height: chunkWorldSize,
        angle: 0,
        strokeColor: 'transparent',
        backgroundColor: 'transparent',
        fillStyle: 'solid',
        strokeWidth: 0,
        strokeStyle: 'solid',
        roughness: 0,
        opacity: 100,
        groupIds: [],
        frameId: null,
        index: `a${String(chunk.cy * numChunks + chunk.cx).padStart(4, '0')}`,
        roundness: null,
        seed: chunk.cx * 1000 + chunk.cy,
        version: Date.now(),
        versionNonce: Math.random() * 1000000 | 0,
        isDeleted: false,
        boundElements: null,
        updated: Date.now(),
        link: null,
        locked: true,
        status: 'saved',
        fileId: fileId,
        scale: [1, 1],
      } as any;
      
      newElements.push(imageElement);
      newFiles[fileId] = {
        id: fileId,
        mimeType: 'image/jpeg',
        dataURL: dataUrl as any,
        created: Date.now(),
        lastRetrieved: Date.now(),
      };
    }
    
    // Get current elements (excluding chunk backgrounds from different zoom levels)
    const currentElements = excalidrawAPI.getSceneElements().filter(el => {
      if (typeof el.id === 'string' && el.id.startsWith('chunk-')) {
        // Keep chunks from current zoom level, remove others
        return el.id.startsWith(`chunk-${tileZoom}-`);
      }
      return true; // Keep user elements
    });
    
    // Add new files
    excalidrawAPI.addFiles(Object.values(newFiles));
    
    // Determine elements to keep
    const elementsToUse = isInitialLoad ? savedElements : currentElements.filter(el => {
      // Filter out chunk elements we're replacing
      if (typeof el.id === 'string' && el.id.startsWith('chunk-')) {
        const existingKey = el.id.replace('chunk-', '').split('-').slice(0, 3).join('-');
        return !newChunks.some(c => `${tileZoom}-${c.cx}-${c.cy}` === existingKey);
      }
      return true;
    });
    
    // Sort - chunks should be at the back, user elements on top
    const chunkElements = [...elementsToUse.filter(el => String(el.id).startsWith('chunk-')), ...newElements];
    const userElements = elementsToUse.filter(el => !String(el.id).startsWith('chunk-'));
    
    excalidrawAPI.updateScene({
      elements: [...chunkElements, ...userElements],
    });

    if (isInitialLoad && chunkElements.length > 0) {
      excalidrawAPI.scrollToContent(chunkElements[0], { fitToViewport: true });
    }
    
    setIsLoadingTiles(false);
    setLoadingProgress('');
    setLoadedChunkCount(loadedChunksRef.current.size);
    console.log(`Loaded ${loadedCount} chunks at zoom ${tileZoom}, total: ${loadedChunksRef.current.size}`);
  }, [excalidrawAPI, savedElements, getVisibleChunks, loadChunk]);

  // Load Guarma background (single image instead of tiles)
  const loadGuarmaBackground = useCallback(async () => {
    if (!excalidrawAPI) return;
    
    setIsLoadingTiles(true);
    setLoadingProgress('Loading Guarma map...');
    console.log('Loading Guarma map background');
    
    try {
      // Load the Guarma image
      const img = new Image();
      img.crossOrigin = 'anonymous';
      
      await new Promise<void>((resolve, reject) => {
        img.onload = () => resolve();
        img.onerror = () => reject(new Error('Failed to load Guarma map image'));
        img.src = GUARMA_CONFIG.imageUrl;
      });
      
      // Create canvas and draw image
      const canvas = document.createElement('canvas');
      canvas.width = GUARMA_CONFIG.width;
      canvas.height = GUARMA_CONFIG.height;
      const ctx = canvas.getContext('2d')!;
      ctx.drawImage(img, 0, 0);
      
      // Generate file data
      const fileId = `guarma-bg-${Date.now()}` as any;
      const dataUrl = canvas.toDataURL('image/webp', 0.95);
      
      // Calculate map dimensions (maintain aspect ratio, fit to mapSize)
      const aspectRatio = GUARMA_CONFIG.width / GUARMA_CONFIG.height;
      let mapWidth: number, mapHeight: number;
      if (aspectRatio > 1) {
        mapWidth = GUARMA_CONFIG.mapSize;
        mapHeight = GUARMA_CONFIG.mapSize / aspectRatio;
      } else {
        mapHeight = GUARMA_CONFIG.mapSize;
        mapWidth = GUARMA_CONFIG.mapSize * aspectRatio;
      }
      
      // Center the map
      const mapX = -mapWidth / 2;
      const mapY = -mapHeight / 2;
      
      // Create background element
      const bgElement: ExcalidrawElement = {
        id: 'guarma-map-background',
        type: 'image',
        x: mapX,
        y: mapY,
        width: mapWidth,
        height: mapHeight,
        angle: 0,
        strokeColor: 'transparent',
        backgroundColor: 'transparent',
        fillStyle: 'solid',
        strokeWidth: 0,
        strokeStyle: 'solid',
        roughness: 0,
        opacity: 100,
        groupIds: [],
        frameId: null,
        index: 'a0000',
        roundness: null,
        seed: 1,
        version: Date.now(),
        versionNonce: Math.random() * 1000000 | 0,
        isDeleted: false,
        boundElements: null,
        updated: Date.now(),
        link: null,
        locked: true,
        status: 'saved',
        fileId: fileId,
        scale: [1, 1],
      } as any;
      
      // Add file
      excalidrawAPI.addFiles([{
        id: fileId,
        mimeType: 'image/webp',
        dataURL: dataUrl as any,
        created: Date.now(),
        lastRetrieved: Date.now(),
      }]);
      
      // Update scene with background + saved user elements
      excalidrawAPI.updateScene({
        elements: [bgElement, ...savedElements],
      });
      
      // Center on the map
      excalidrawAPI.scrollToContent(bgElement, { fitToViewport: true });
      
      console.log('Guarma map loaded successfully');
    } catch (error) {
      console.error('Failed to load Guarma map:', error);
    } finally {
      setIsLoadingTiles(false);
      setLoadingProgress('');
    }
  }, [excalidrawAPI, savedElements]);

  const handleChange = useCallback((_elements: readonly ExcalidrawElement[], appState: AppState) => {
    if (canEdit && mapLoaded) {
      saveToServer();
    }
    
    // Don't process viewport changes until map is fully loaded
    // Skip tile loading for Guarma maps (single image instead of tiles)
    if (!excalidrawAPI || !mapLoaded || isLoadingTiles || currentMapType === 'guarma') return;
    
    const newTileZoom = getTileZoomForCanvasZoom(appState.zoom.value);
    const viewX = appState.scrollX;
    const viewY = appState.scrollY;
    
    // Check if LOD level changed
    if (newTileZoom !== lastTileZoomRef.current) {
      if (lodDebounceRef.current) {
        clearTimeout(lodDebounceRef.current);
      }
      
      lodDebounceRef.current = setTimeout(() => {
        console.log(`LOD change: zoom ${Math.round(appState.zoom.value * 100)}% -> tile zoom ${newTileZoom}`);
        lastTileZoomRef.current = newTileZoom;
        setCurrentTileZoom(newTileZoom);
        // Reset chunks for new LOD level
        loadedChunksRef.current.clear();
        chunkCanvasesRef.current.clear();
        setLoadedChunkCount(0);
        loadVisibleChunks(viewX, viewY, appState.zoom.value, newTileZoom, false);
      }, LOD_DEBOUNCE_MS);
      return;
    }
    
    // Check if viewport moved significantly - load new chunks
    const lastView = lastViewportRef.current;
    const viewportMoved = 
      Math.abs(viewX - lastView.x) > 200 || 
      Math.abs(viewY - lastView.y) > 200;
    
    if (viewportMoved) {
      lastViewportRef.current = { x: viewX, y: viewY, zoom: appState.zoom.value };
      
      if (viewportDebounceRef.current) {
        clearTimeout(viewportDebounceRef.current);
      }
      
      // Short debounce for panning
      viewportDebounceRef.current = setTimeout(() => {
        loadVisibleChunks(viewX, viewY, appState.zoom.value, currentTileZoom, false);
      }, 150);
    }
  }, [canEdit, mapLoaded, saveToServer, excalidrawAPI, isLoadingTiles, currentTileZoom, loadVisibleChunks, currentMapType]);

  // Initial load - also triggered when switching maps (currentMapId changes)
  useEffect(() => {
    if (!excalidrawAPI || mapLoaded || !isVisible) return;
    
    // Small delay to ensure savedElements is updated from localStorage
    const timer = setTimeout(async () => {
      if (currentMapType === 'guarma') {
        // Guarma uses single image background
        await loadGuarmaBackground();
      } else {
        // Main map uses tile chunks
        const initialTileZoom = 4;
        lastTileZoomRef.current = initialTileZoom;
        setCurrentTileZoom(initialTileZoom);
        await loadVisibleChunks(0, 0, 0.1, initialTileZoom, true);
      }
      // Small delay before enabling map interactions
      setTimeout(() => {
        setMapLoaded(true);
      }, 100);
    }, 50);
    
    return () => clearTimeout(timer);
  }, [excalidrawAPI, mapLoaded, isVisible, loadVisibleChunks, loadGuarmaBackground, currentMapId, currentMapType]);

  // Inject laser pointer button into toolbar
  useEffect(() => {
    if (!excalidrawAPI) return;

    // Wait for toolbar to be rendered
    const injectLaserButton = () => {
      const toolbar = document.querySelector('.App-toolbar__extra-tools-trigger');
      if (!toolbar || !toolbar.parentElement) return false;
      
      // Check if we already injected
      if (document.querySelector('.custom-laser-toolbar-button')) return true;
      
      // Create laser button
      const laserBtn = document.createElement('button');
      laserBtn.className = 'custom-laser-toolbar-button';
      laserBtn.title = 'Laser pointer (K)';
      laserBtn.innerHTML = `
        <svg aria-hidden="true" focusable="false" role="img" viewBox="0 0 20 20" width="20" height="20">
          <g fill="none" stroke="currentColor" stroke-width="1.25" stroke-linecap="round" stroke-linejoin="round" transform="rotate(90 10 10)">
            <path clip-rule="evenodd" d="m9.644 13.69 7.774-7.773a2.357 2.357 0 0 0-3.334-3.334l-7.773 7.774L8 12l1.643 1.69Z"></path>
            <path d="m13.25 3.417 3.333 3.333M10 10l2-2M5 15l3-3M2.156 17.894l1-1M5.453 19.029l-.144-1.407M2.377 11.887l.866 1.118M8.354 17.273l-1.194-.758M.953 14.652l1.408.13"></path>
          </g>
        </svg>
      `;
      laserBtn.addEventListener('click', () => {
        excalidrawAPI.setActiveTool({ type: 'laser' });
      });
      
      // Insert after the More Tools trigger
      toolbar.parentElement.insertBefore(laserBtn, toolbar.nextSibling);
      return true;
    };

    // Try immediately and retry a few times
    if (!injectLaserButton()) {
      const interval = setInterval(() => {
        if (injectLaserButton()) {
          clearInterval(interval);
        }
      }, 100);
      
      // Stop trying after 5 seconds
      setTimeout(() => clearInterval(interval), 5000);
    }
  }, [excalidrawAPI]);

  // Don't render if not visible (NUI mode)
  if (!isVisible) {
    return null;
  }

  // Toggle fullscreen
  const toggleFullscreen = () => setIsFullscreen(prev => !prev);

  return (
    <div
      style={{
        position: 'fixed',
        top: 0,
        left: 0,
        width: '100%',
        height: '100vh',
        background: isFullscreen ? 'transparent' : 'rgba(0, 0, 0, 0.5)',
        display: 'flex',
        alignItems: 'center',
        justifyContent: 'center',
      }}
    >
      <div 
        style={{ 
          width: isFullscreen ? "100%" : "75%",
          height: isFullscreen ? "100%" : "80%",
          borderRadius: isFullscreen ? 0 : 12,
          overflow: 'hidden',
          boxShadow: isFullscreen ? 'none' : '0 8px 32px rgba(0, 0, 0, 0.5)',
          border: isFullscreen ? 'none' : '1px solid rgba(255, 255, 255, 0.1)',
          position: 'relative',
        }} 
        className="custom-styles"
      >
      {/* Status bar */}
      <div style={{
        position: 'absolute',
        top: 10,
        right: 10,
        zIndex: 100,
        background: 'rgba(0,0,0,0.7)',
        color: 'white',
        padding: '8px 16px',
        borderRadius: 4,
        fontSize: 14,
        display: 'flex',
        gap: 16,
        alignItems: 'center',
      }}>
        {/* Location name / selector */}
        {!isNUI && maps.length > 1 ? (
          <select
            value={currentMapId}
            onChange={(e) => handleMapChange(Number(e.target.value))}
            style={{
              background: '#333',
              color: '#ffd43b',
              border: '1px solid #555',
              borderRadius: 4,
              padding: '4px 8px',
              fontSize: 14,
              cursor: 'pointer',
            }}
          >
            {maps.map(m => (
              <option key={m.id} value={m.id}>{m.name}</option>
            ))}
          </select>
        ) : (
          <span style={{ color: '#ffd43b', fontWeight: 'bold' }}>
            📍 {currentMapName}
          </span>
        )}
        {isLoadingTiles && (
          <span style={{ color: '#74c0fc' }}>⏳ {loadingProgress || 'Loading...'}</span>
        )}
        {isLocked && lockedByName && !canEdit && (
          <span style={{ color: '#ff6b6b' }}>
            🔒 Editing: {lockedByName}
          </span>
        )}
        {canEdit ? (
          <button
            onClick={releaseEditLock}
            title="Stop editing and release lock for others"
            style={{
              background: '#69db7c',
              color: '#1a1a2e',
              border: 'none',
              borderRadius: 4,
              padding: '4px 12px',
              fontSize: 13,
              cursor: 'pointer',
              fontWeight: 'bold',
            }}
          >
            ✏️ Stop Editing
          </button>
        ) : hasPermission && !isLocked ? (
          <button
            onClick={requestEditLock}
            style={{
              background: '#4c6ef5',
              color: 'white',
              border: 'none',
              borderRadius: 4,
              padding: '4px 12px',
              fontSize: 13,
              cursor: 'pointer',
              fontWeight: 'bold',
            }}
          >
            ✏️ Start Editing
          </button>
        ) : !canEdit && (
          <span style={{ color: '#ffd43b' }}>👁️ View Only</span>
        )}
        <button
          onClick={toggleFullscreen}
          title={isFullscreen ? 'Exit Fullscreen' : 'Enter Fullscreen'}
          style={{
            background: '#333',
            color: 'white',
            border: '1px solid #555',
            borderRadius: 4,
            padding: '4px 10px',
            fontSize: 13,
            cursor: 'pointer',
            display: 'flex',
            alignItems: 'center',
            gap: 4,
          }}
        >
          {isFullscreen ? '⊡' : '⊞'} {isFullscreen ? 'Window' : 'Fullscreen'}
        </button>
        <span style={{ color: '#aaa' }}>Press ESC to close</span>
      </div>

      {/* Image URL Modal */}
      {showImageUrlModal && (
        <div style={{
          position: 'absolute',
          top: 0,
          left: 0,
          right: 0,
          bottom: 0,
          background: 'rgba(0,0,0,0.7)',
          display: 'flex',
          alignItems: 'center',
          justifyContent: 'center',
          zIndex: 200,
        }}>
          <div style={{
            background: '#1e1e1e',
            borderRadius: 8,
            padding: 24,
            width: 400,
            maxWidth: '90%',
          }}>
            <h3 style={{ color: 'white', margin: '0 0 16px 0' }}>Insert Image from URL</h3>
            <input
              type="text"
              value={imageUrlInput}
              onChange={(e) => setImageUrlInput(e.target.value)}
              placeholder="https://example.com/image.png"
              autoFocus
              style={{
                width: '100%',
                padding: '8px 12px',
                fontSize: 14,
                borderRadius: 4,
                border: '1px solid #555',
                background: '#2d2d2d',
                color: 'white',
                boxSizing: 'border-box',
              }}
              onKeyDown={(e) => {
                if (e.key === 'Enter') {
                  insertImageFromUrl(imageUrlInput);
                } else if (e.key === 'Escape') {
                  setShowImageUrlModal(false);
                  setImageUrlInput('');
                  setImageUrlError('');
                }
              }}
            />
            {imageUrlError && (
              <p style={{ color: '#ff6b6b', margin: '8px 0 0 0', fontSize: 13 }}>{imageUrlError}</p>
            )}
            <div style={{ display: 'flex', gap: 8, marginTop: 16, justifyContent: 'flex-end' }}>
              <button
                onClick={() => {
                  setShowImageUrlModal(false);
                  setImageUrlInput('');
                  setImageUrlError('');
                }}
                style={{
                  background: '#555',
                  color: 'white',
                  border: 'none',
                  borderRadius: 4,
                  padding: '8px 16px',
                  cursor: 'pointer',
                }}
              >
                Cancel
              </button>
              <button
                onClick={() => insertImageFromUrl(imageUrlInput)}
                style={{
                  background: '#4c6ef5',
                  color: 'white',
                  border: 'none',
                  borderRadius: 4,
                  padding: '8px 16px',
                  cursor: 'pointer',
                }}
              >
                Insert
              </button>
            </div>
          </div>
        </div>
      )}

      <Excalidraw 
        theme="dark"
        excalidrawAPI={(api: ExcalidrawImperativeAPI) => setExcalidrawAPI(api)}
        onChange={handleChange}
        viewModeEnabled={!canEdit}
        initialData={{
          appState: {
            viewBackgroundColor: "#fdfdfd",
            zoom: { value: 0.3 as any },
          },
        }}
        UIOptions={{
          // Image tool enabled - we intercept clicks to show our URL modal
        }}
      />
      </div>
    </div>
  );
}

export default App;
