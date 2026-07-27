import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";

// Proxy API calls to the FastAPI service so the browser can POST the run and
// consume the Server-Sent Events stream from the same origin (no CORS, and
// SSE streams through the dev server cleanly).
const API_TARGET = "http://127.0.0.1:8000";

export default defineConfig({
    plugins: [react()],
    server: {
        port: 5173,
        proxy: {
            "/simulate": { target: API_TARGET, changeOrigin: true },
            "/datasets": { target: API_TARGET, changeOrigin: true },
        },
    },
});
