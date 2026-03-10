import { defineConfig } from "vite";

export default defineConfig(({ command }) => ({
  base: command === "build" ? process.env.PLAYGROUND_BASE_PATH ?? "/" : "/",
  server: {
    port: 5173,
  },
}));
