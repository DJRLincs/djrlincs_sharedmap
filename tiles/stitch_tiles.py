#!/usr/bin/env python3
"""
Tile Stitcher - Combines tile images into full map images as webp
Processes all zoom levels for each map style (detailed, darkmode, black)
"""

import os
import re
from pathlib import Path
from PIL import Image

TILE_SIZE = 256
SCRIPT_DIR = Path(__file__).parent

def get_tile_dimensions(folder_path: Path) -> tuple[int, int]:
    """Scan folder to find max x and y tile indices."""
    max_x = 0
    max_y = 0
    
    for file in folder_path.glob("*.webp"):
        match = re.match(r"(\d+)_(\d+)\.webp", file.name)
        if match:
            x, y = int(match.group(1)), int(match.group(2))
            max_x = max(max_x, x)
            max_y = max(max_y, y)
    
    return max_x + 1, max_y + 1  # +1 because 0-indexed

def stitch_tiles(folder_path: Path, output_path: Path, style: str, zoom_level: int):
    """Stitch tiles from a folder into a single image."""
    cols, rows = get_tile_dimensions(folder_path)
    
    if cols == 0 or rows == 0:
        print(f"  No tiles found in {folder_path}")
        return False
    
    width = cols * TILE_SIZE
    height = rows * TILE_SIZE
    
    print(f"  Level {zoom_level}: {cols}x{rows} tiles = {width}x{height}px")
    
    # WebP max dimension is 16383 pixels
    WEBP_MAX = 16383
    use_webp = width <= WEBP_MAX and height <= WEBP_MAX
    
    if not use_webp:
        # Change extension to jpg for large images
        output_path = output_path.with_suffix('.jpg')
        print(f"    (Too large for WebP, saving as JPEG)")
    
    # Create empty canvas
    canvas = Image.new('RGB', (width, height), color=(0, 0, 0))
    
    # Load and paste each tile
    tiles_loaded = 0
    for x in range(cols):
        for y in range(rows):
            tile_path = folder_path / f"{x}_{y}.webp"
            if tile_path.exists():
                try:
                    tile = Image.open(tile_path)
                    canvas.paste(tile, (x * TILE_SIZE, y * TILE_SIZE))
                    tiles_loaded += 1
                except Exception as e:
                    print(f"    Warning: Failed to load {tile_path}: {e}")
    
    print(f"    Loaded {tiles_loaded}/{cols * rows} tiles")
    
    # Save as webp or jpeg depending on size
    output_path.parent.mkdir(parents=True, exist_ok=True)
    
    if use_webp:
        canvas.save(output_path, 'WEBP', quality=90)
    else:
        canvas.save(output_path, 'JPEG', quality=90)
    
    file_size_mb = output_path.stat().st_size / (1024 * 1024)
    print(f"    Saved: {output_path.name} ({file_size_mb:.2f} MB)")
    
    return True

def main():
    styles = ['detailed', 'darkmode', 'black']
    zoom_levels = range(1, 8)  # 1-7
    
    output_dir = SCRIPT_DIR / "full_maps"
    output_dir.mkdir(exist_ok=True)
    
    for style in styles:
        style_dir = SCRIPT_DIR / style
        if not style_dir.exists():
            print(f"Skipping {style} - folder not found")
            continue
        
        print(f"\nProcessing {style} maps...")
        
        for zoom in zoom_levels:
            zoom_dir = style_dir / str(zoom)
            if not zoom_dir.exists():
                print(f"  Level {zoom} - not found, skipping")
                continue
            
            output_file = output_dir / f"{style}_zoom{zoom}.webp"
            stitch_tiles(zoom_dir, output_file, style, zoom)
    
    print(f"\nDone! Full maps saved to: {output_dir}")

if __name__ == "__main__":
    main()
