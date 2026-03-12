/// <reference types="vite/client" />

declare global {
  interface Window {
    EXCALIDRAW_ASSET_PATH: string;
    GetParentResourceName?: () => string;
  }
}

export {};
