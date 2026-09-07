/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./lib/**/*.{ex,heex}",
    "./priv/static/**/*.js"
  ],
  darkMode: ["class", '[data-theme="dark"]'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['Poppins', '-apple-system', 'BlinkMacSystemFont', 'Segoe UI', 'Roboto', 'sans-serif'],
        mono: ['JetBrains Mono', 'ui-monospace', 'SFMono-Regular', 'Menlo', 'Monaco', 'Consolas', 'monospace'],
      },
      colors: {
        obsidian: '#09090b',
        panel: '#121215',
        surface: '#18181b',
      }
    },
  },
  plugins: [
    require("daisyui")
  ],
  daisyui: {
    themes: [
      {
        dark: {
          "color-scheme": "dark",
          "primary": "#ffffff",
          "primary-content": "#09090b",
          "secondary": "#27272a",
          "secondary-content": "#fafafa",
          "accent": "#ef4444",
          "accent-content": "#ffffff",
          "neutral": "#18181b",
          "neutral-content": "#f4f4f5",
          "base-100": "#09090b",
          "base-200": "#121215",
          "base-300": "#18181b",
          "base-content": "#fafafa",
          "info": "#38bdf8",
          "info-content": "#09090b",
          "success": "#10b981",
          "success-content": "#ffffff",
          "warning": "#f59e0b",
          "warning-content": "#09090b",
          "error": "#ef4444",
          "error-content": "#ffffff",
          "--rounded-box": "0.5rem",
          "--rounded-btn": "0.375rem",
          "--rounded-badge": "0.25rem",
          "--animation-btn": "0.15s",
          "--animation-input": "0.15s",
          "--btn-focus-scale": "0.98",
          "--border-btn": "1px",
          "--tab-border": "1px",
          "--tab-radius": "0.375rem",
        }
      }
    ],
    base: true,
    styled: true,
    utils: true,
  }
}
