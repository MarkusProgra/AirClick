import { defineConfig } from "vite"
import react from "@vitejs/plugin-react"

// Plain HTTP on localhost is a secure context, so getUserMedia works without
// a self-signed certificate warning (unlike hosting on the LAN).
export default defineConfig({
  plugins: [react()],
  server: { port: 5174 },
})