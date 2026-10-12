const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname);

// 1. UPDATE TOKENS WITH DARK + LIGHT MODES
const tokens = {
  "$name": "CoRoute Design System Tokens",
  "$version": "3.19.0",
  "$description": "Design tokens for CoRoute mobile application - High-contrast glove ergonomics, night navigation, and outdoor sunlight glare resistance.",
  "global": {
    "spacing": {
      "s4": { "$value": "4px", "$type": "dimension" },
      "s8": { "$value": "8px", "$type": "dimension" },
      "s12": { "$value": "12px", "$type": "dimension" },
      "s16": { "$value": "16px", "$type": "dimension" },
      "s20": { "$value": "20px", "$type": "dimension" },
      "s24": { "$value": "24px", "$type": "dimension" },
      "s32": { "$value": "32px", "$type": "dimension" }
    },
    "radii": {
      "sm": { "$value": "8px", "$type": "dimension" },
      "md": { "$value": "12px", "$type": "dimension" },
      "lg": { "$value": "16px", "$type": "dimension" },
      "xl": { "$value": "24px", "$type": "dimension" },
      "xxl": { "$value": "32px", "$type": "dimension" },
      "pill": { "$value": "9999px", "$type": "dimension" }
    },
    "typography": {
      "fontFamily": {
        "primary": { "$value": "Plus Jakarta Sans, sans-serif", "$type": "fontFamily" },
        "mono": { "$value": "JetBrains Mono, monospace", "$type": "fontFamily" }
      },
      "fontSize": {
        "xs": { "$value": "11px", "$type": "dimension" },
        "sm": { "$value": "12px", "$type": "dimension" },
        "body": { "$value": "14px", "$type": "dimension" },
        "title": { "$value": "16px", "$type": "dimension" },
        "heading": { "$value": "20px", "$type": "dimension" },
        "hero": { "$value": "32px", "$type": "dimension" }
      }
    },
    "touchTarget": {
      "minGloveTarget": { "$value": "48px", "$type": "dimension", "$description": "Strict floor for touch accessibility" },
      "primaryGloveTarget": { "$value": "56px", "$type": "dimension", "$description": "Standard glove button dimension" },
      "heroGloveTarget": { "$value": "64px", "$type": "dimension", "$description": "In-flight primary modal actions" },
      "oversizedCard": { "$value": "160px", "$type": "dimension", "$description": "Stop reason grid tiles" }
    }
  },
  "dark": {
    "color": {
      "background": {
        "deep": { "$value": "#070A0F", "$type": "color", "$description": "Primary screen canvas background" },
        "card": { "$value": "#0F1622", "$type": "color", "$description": "Card and container surface" },
        "surface": { "$value": "#162030", "$type": "color", "$description": "Elevated modal and bottom sheet surface" },
        "sheet": { "$value": "#0F172A", "$type": "color" }
      },
      "brand": {
        "neonCyan": { "$value": "#00E5FF", "$type": "color", "$description": "Primary telemetry and brand accent" },
        "neonCyanMuted": { "$value": "rgba(0, 229, 255, 0.15)", "$type": "color" },
        "cyanGlow": { "$value": "rgba(0, 229, 255, 0.6)", "$type": "color" }
      },
      "safety": {
        "sosRed": { "$value": "#FF1744", "$type": "color", "$description": "Critical emergency SOS highlight" },
        "sosRedDark": { "$value": "#B71C1C", "$type": "color" },
        "warningAmber": { "$value": "#FF9100", "$type": "color", "$description": "Caution, distance gap & fuel deficit alert" },
        "successGreen": { "$value": "#00E676", "$type": "color", "$description": "Safe status, convoy online & normal fuel" },
        "purpleAccent": { "$value": "#B388FF", "$type": "color", "$description": "Regroup marker and dynamic meeting point" }
      },
      "text": {
        "primary": { "$value": "#F1F5F9", "$type": "color", "$description": "High-contrast headings and primary labels" },
        "secondary": { "$value": "#94A3B8", "$type": "color", "$description": "Supporting captions and secondary info" },
        "tertiary": { "$value": "#64748B", "$type": "color" },
        "disabled": { "$value": "#475569", "$type": "color" }
      },
      "border": {
        "default": { "$value": "#1E293B", "$type": "color" },
        "active": { "$value": "#00E5FF", "$type": "color" },
        "warning": { "$value": "#FF9100", "$type": "color" }
      }
    }
  },
  "light": {
    "color": {
      "background": {
        "deep": { "$value": "#F8FAFC", "$type": "color", "$description": "Outdoor daylight canvas background" },
        "card": { "$value": "#FFFFFF", "$type": "color", "$description": "Card surface with high contrast" },
        "surface": { "$value": "#F1F5F9", "$type": "color", "$description": "Secondary panel surface" },
        "sheet": { "$value": "#FFFFFF", "$type": "color" }
      },
      "brand": {
        "neonCyan": { "$value": "#00838F", "$type": "color", "$description": "High-contrast deep cyan for direct sunlight visibility" },
        "neonCyanMuted": { "$value": "rgba(0, 131, 143, 0.12)", "$type": "color" },
        "cyanGlow": { "$value": "rgba(0, 131, 143, 0.35)", "$type": "color" }
      },
      "safety": {
        "sosRed": { "$value": "#DC2626", "$type": "color", "$description": "Direct sunlight high-contrast SOS red" },
        "sosRedDark": { "$value": "#991B1B", "$type": "color" },
        "warningAmber": { "$value": "#BD5B00", "$type": "color", "$description": "Direct sunlight high-contrast amber" },
        "successGreen": { "$value": "#16A34A", "$type": "color", "$description": "Sunlight clear green" },
        "purpleAccent": { "$value": "#7C3AED", "$type": "color", "$description": "Sunlight vibrant violet" }
      },
      "text": {
        "primary": { "$value": "#0F172A", "$type": "color", "$description": "Deep obsidian for direct sunlight readability" },
        "secondary": { "$value": "#475569", "$type": "color", "$description": "Deep slate for secondary text" },
        "tertiary": { "$value": "#94A3B8", "$type": "color" },
        "disabled": { "$value": "#CBD5E1", "$type": "color" }
      },
      "border": {
        "default": { "$value": "#CBD5E1", "$type": "color" },
        "active": { "$value": "#00838F", "$type": "color" },
        "warning": { "$value": "#BD5B00", "$type": "color" }
      }
    }
  },
  "$themes": [
    {
      "id": "dark",
      "name": "CoRoute Dark (Cyberpunk / Night Navigation)",
      "selectedTokenSets": { "global": "enabled", "dark": "enabled" }
    },
    {
      "id": "light",
      "name": "CoRoute Light (Outdoor Sunlight High-Contrast)",
      "selectedTokenSets": { "global": "enabled", "light": "enabled" }
    }
  ]
};

fs.writeFileSync(path.join(dir, 'coroute_figma_tokens.json'), JSON.stringify(tokens, null, 2), 'utf8');
console.log('✅ Updated coroute_figma_tokens.json with Dark and Light mode themes!');
