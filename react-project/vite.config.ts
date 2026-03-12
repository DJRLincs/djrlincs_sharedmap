import { defineConfig } from 'vite'
import react from '@vitejs/plugin-react'
import path from 'path'
import fs from 'fs'

// Custom plugin to serve tiles from parent directory
function serveTilesPlugin() {
  return {
    name: 'serve-tiles',
    configureServer(server: any) {
      server.middlewares.use('/tiles', (req: any, res: any, next: any) => {
        const tilePath = path.resolve(__dirname, '../tiles', req.url.slice(1));
        if (fs.existsSync(tilePath)) {
          const ext = path.extname(tilePath).toLowerCase();
          const contentType = ext === '.webp' ? 'image/webp' : ext === '.jpg' ? 'image/jpeg' : 'application/octet-stream';
          res.setHeader('Content-Type', contentType);
          res.setHeader('Cache-Control', 'public, max-age=86400');
          fs.createReadStream(tilePath).pipe(res);
        } else {
          res.statusCode = 404;
          res.end('Tile not found');
        }
      });
    }
  };
}

// https://vitejs.dev/config/
export default defineConfig({
  base: '',
  plugins: [react(), serveTilesPlugin()],
  build: {
    outDir: '../nui',
    emptyOutDir: true,
    sourcemap: false,
    minify: 'esbuild',
    rollupOptions: {
      output: {
        assetFileNames: 'assets/[name][extname]',
        chunkFileNames: 'assets/[name].js',
        entryFileNames: 'assets/[name].js',
      }
    },
  },
  server: {
    port: 5174,
    cors: true,
    strictPort: false,
    hmr: {
      host: 'localhost',
    },
    // Allow accessing parent directory
    fs: {
      allow: ['..', '../tiles'],
    },
  },
  define: {
    // Required for Excalidraw
    'process.env.IS_PREACT': JSON.stringify('false'),
  },
})
