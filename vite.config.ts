import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Tauri serves the built assets from disk, so relative paths are required.
// It also owns the dev port, and a failure to bind must be loud rather than
// silently moving to another port the app is not pointed at.
export default defineConfig({
  plugins: [react()],
  base: "./",
  clearScreen: false,
  server: { port: 5173, strictPort: true },
  build: { outDir: "dist", emptyOutDir: true, target: "es2021" },
});
