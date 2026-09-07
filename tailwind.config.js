/** @type {import('tailwindcss').Config} */
module.exports = {
  content: [
    "./lib/**/*.{ex,heex}",
    "./priv/static/**/*.js",
    "./web/**/*.{html,js}"
  ],
  darkMode: ["class", '[data-theme="dark"]'],
  theme: {
    extend: {
      fontFamily: {
        sans: ['Segoe UI', 'Inter', 'system-ui', 'sans-serif'],
        mono: ['JetBrains Mono', 'Cascadia Code', 'Consolas', 'monospace'],
      },
      colors: {
        background: "hsl(var(--background) / <alpha-value>)",
        foreground: "hsl(var(--foreground) / <alpha-value>)",
        card: {
          DEFAULT: "hsl(var(--card) / <alpha-value>)",
          foreground: "hsl(var(--card-foreground) / <alpha-value>)",
        },
        popover: {
          DEFAULT: "hsl(var(--popover) / <alpha-value>)",
          foreground: "hsl(var(--popover-foreground) / <alpha-value>)",
        },
        primary: {
          DEFAULT: "hsl(var(--primary) / <alpha-value>)",
          foreground: "hsl(var(--primary-foreground) / <alpha-value>)",
        },
        secondary: {
          DEFAULT: "hsl(var(--secondary) / <alpha-value>)",
          foreground: "hsl(var(--secondary-foreground) / <alpha-value>)",
        },
        muted: {
          DEFAULT: "hsl(var(--muted) / <alpha-value>)",
          foreground: "hsl(var(--muted-foreground) / <alpha-value>)",
        },
        accent: {
          DEFAULT: "hsl(var(--accent) / <alpha-value>)",
          foreground: "hsl(var(--accent-foreground) / <alpha-value>)",
        },
        destructive: {
          DEFAULT: "hsl(var(--destructive) / <alpha-value>)",
          foreground: "hsl(var(--destructive-foreground) / <alpha-value>)",
        },
        border: "hsl(var(--border) / <alpha-value>)",
        input: "hsl(var(--input) / <alpha-value>)",
        ring: "hsl(var(--ring) / <alpha-value>)",
      },
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
          "primary": "#fafafa",
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
        },
        light: {
          "color-scheme": "light",
          "primary": "#09090b",
          "primary-content": "#ffffff",
          "secondary": "#f4f4f5",
          "secondary-content": "#09090b",
          "accent": "#ef4444",
          "accent-content": "#ffffff",
          "neutral": "#f4f4f5",
          "neutral-content": "#09090b",
          "base-100": "#ffffff",
          "base-200": "#f4f4f5",
          "base-300": "#e4e4e7",
          "base-content": "#09090b",
          "info": "#0284c7",
          "info-content": "#ffffff",
          "success": "#059669",
          "success-content": "#ffffff",
          "warning": "#d97706",
          "warning-content": "#ffffff",
          "error": "#dc2626",
          "error-content": "#ffffff",
          "--rounded-box": "0.5rem",
          "--rounded-btn": "0.375rem",
          "--rounded-badge": "0.25rem",
        }
      }
    ],
    base: true,
    styled: true,
    utils: true,
  }
}
