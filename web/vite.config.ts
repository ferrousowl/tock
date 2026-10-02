import { defineConfig } from "vite";

// Relative base so the build works from any path (GitHub Pages project sites included).
export default defineConfig({ base: "./", build: { target: "es2022" } });
