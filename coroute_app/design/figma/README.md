# CoRoute Figma Design & Prototyping Package (v3.19.0)

Production-grade Figma design system, tokens, 12 vector artboards (Dark Mode + Light Mode), and turnkey interactive prototyping for CoRoute Mobile.

---

## 🚀 Option 1: 1-Click Importer & Interactive Prototype Plugin (Recommended)

Generate all 12 screens across **Dark Mode** and **Light Mode**, complete with section banners, a visual flow guide, and **native Figma prototype wiring** (interactive click noodles).

### Instructions:
1. Open your Figma document: [Untitled (R6zbBasBwwtAj4DOlgW9RY)](https://www.figma.com/design/R6zbBasBwwtAj4DOlgW9RY/Untitled?t=TdJXIr2UKAnbCrhS-0)
2. Open Figma Menu (top-left Figma icon) $\rightarrow$ **Plugins** $\rightarrow$ **Development** $\rightarrow$ **Import plugin from manifest...**
3. Select this manifest file:
   📁 [`coroute_app/design/figma/plugin/manifest.json`](./plugin/manifest.json)
4. Run the plugin:
   * Press `Ctrl+P` (or `Cmd+P` on Mac), type `CoRoute Mobile Screen Importer`, and press `Enter`.
   * *Or* right-click canvas $\rightarrow$ **Plugins** $\rightarrow$ **Development** $\rightarrow$ **CoRoute Mobile Screen Importer**.
5. **Test Interactive Prototype**:
   * Click **Present ▶** in the top-right toolbar of Figma (or press `Ctrl+Alt+Enter`).
   * Tap any shortcut on the Cockpit dock (`STOP`, `LINK`, `185k`, `CFG`), tap bottom sheet titles, tap cards, or tap the **DARK ⇄ / LIGHT ⇄** status pill to switch themes live!

---

## 🎨 Option 2: Instant Drag & Drop (Zero Plugin Setup)

If you prefer dragging screens directly onto the canvas, 12 standalone, zero-emoji, pixel-perfect `.svg` files are ready:

### 🌙 Dark Mode Suite (Cyberpunk / Night Navigation):
* [`figma_artboard_1_cockpit.svg`](./figma_artboard_1_cockpit.svg) — **Live Cockpit Map Screen** (Decluttered dock, SOS, fuel chip, route polyline)
* [`figma_artboard_2_quick_settings.svg`](./figma_artboard_2_quick_settings.svg) — **Glove Quick Settings Modal** (Guardian link & Fuel hero actions, 2x3 grid)
* [`figma_artboard_3_guardian.svg`](./figma_artboard_3_guardian.svg) — **Ride Guardian Link Sharing** (Web tracking URL, copy action, active observers)
* [`figma_artboard_4_fuel.svg`](./figma_artboard_4_fuel.svg) — **Fuel Estimation & Range Radar** (185km usable range, tank gauge, convoy deficit alert, nearest pump)
* [`figma_artboard_5_group_settings.svg`](./figma_artboard_5_group_settings.svg) — **Redesigned Group Settings** (Guardian hero card, feature toggles, safety sliders)
* [`figma_artboard_6_stop_picker.svg`](./figma_artboard_6_stop_picker.svg) — **Quick Stop Reason Picker** (4 oversized glove action tiles with pure vector icons)

### ☀️ Light Mode Suite (Outdoor Sunlight High-Contrast):
* [`figma_artboard_1_cockpit_light.svg`](./figma_artboard_1_cockpit_light.svg) — **Live Cockpit Map Screen [Light]**
* [`figma_artboard_2_quick_settings_light.svg`](./figma_artboard_2_quick_settings_light.svg) — **Glove Quick Settings Modal [Light]**
* [`figma_artboard_3_guardian_light.svg`](./figma_artboard_3_guardian_light.svg) — **Ride Guardian Link Sharing [Light]**
* [`figma_artboard_4_fuel_light.svg`](./figma_artboard_4_fuel_light.svg) — **Fuel Estimation & Range Radar [Light]**
* [`figma_artboard_5_group_settings_light.svg`](./figma_artboard_5_group_settings_light.svg) — **Redesigned Group Settings [Light]**
* [`figma_artboard_6_stop_picker_light.svg`](./figma_artboard_6_stop_picker_light.svg) — **Quick Stop Reason Picker [Light]**

---

## 💎 Option 3: Design Tokens for Tokens Studio & Figma Variables

File: [`coroute_figma_tokens.json`](./coroute_figma_tokens.json)

* **Dual-Mode Specification**: Includes full definitions for `dark` (Cyberpunk / Night) and `light` (Outdoor Sunlight) modes.
* **Tokens Studio for Figma**: Import via Tokens Studio $\rightarrow$ Tools $\rightarrow$ Load Tokens to automatically create themed Token Sets.
* **Figma Variables**: Maps directly to Figma Color Variable Collections (Canvas, Surface, Card, Brand Cyan, SOS Red, Warning Amber, Success Green).
* **Glove Ergonomics**: Strict 48dp floor, 56dp primary glove targets, 64dp hero actions, and 160dp oversized grid tiles.

---

## ⚡ Interactive Prototyping Flow Architecture

```
[ Screen 1: Cockpit Map ]
    ├── Tap 'STOP' ───────────────► [ Screen 6: Stop Reason Picker ] ──► Tap Reason / Done ──► Back to Cockpit
    ├── Tap 'LINK' ───────────────► [ Screen 3: Ride Guardian Link ]  ──► Tap Done ──────────► Back to Cockpit
    ├── Tap '185k' ───────────────► [ Screen 4: Fuel Range Radar ]   ──► Tap Broadcast / Done► Back to Cockpit
    ├── Tap 'CFG' ────────────────► [ Screen 2: Quick Settings ]
    │                                   ├── Tap 'Guardian Link' ──► [ Screen 3: Ride Guardian ]
    │                                   ├── Tap 'Fuel / Range' ───► [ Screen 4: Fuel Radar ]
    │                                   ├── Tap 'Full Settings'──► [ Screen 5: Group Settings ]
    │                                   └── Tap 'Done' ───────────► Back to Cockpit
    ├── Tap Bottom Sheet Title ───► [ Screen 5: Group Settings ]
    │                                   ├── Tap 'Share Link' ─────► [ Screen 3: Ride Guardian ]
    │                                   └── Tap 'Save & Return' ──► Back to Cockpit
    └── Tap Status Bar 'DARK ⇄' ──► [ Screen 1: Light Cockpit Map ] (Live Theme Swap)
```
*(Exact symmetrical interactions wired for both Dark and Light Mode)*
