import React from 'react'
import ReactDOM from 'react-dom/client'
import App from './App'
import './index.css'

// Force lower device pixel ratio to prevent canvas overflow on high-DPI displays
Object.defineProperty(window, 'devicePixelRatio', {
  get: () => 1
});

// Set Excalidraw asset path for loading fonts and other assets
window.EXCALIDRAW_ASSET_PATH = 'https://esm.sh/@excalidraw/excalidraw@0.17.6/dist/prod/';

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
)
