const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname);

const darkSvgs = [
  { id: 'cockpit_idle_dark', name: '1. Cockpit [Dark] - Idle (Speed on Markers)', file: 'figma_artboard_1_cockpit_idle.svg' },
  { id: 'cockpit_orbit_dark', name: '2. Cockpit [Dark] - Orbit Popup Open', file: 'figma_artboard_2_cockpit_orbit.svg' },
  { id: 'popup_settings_dark', name: '3. Cockpit [Dark] - Quick Settings Popup', file: 'figma_artboard_3_popup_quick_settings.svg' },
  { id: 'popup_guardian_dark', name: '4. Cockpit [Dark] - Ride Guardian Popup', file: 'figma_artboard_4_popup_guardian.svg' },
  { id: 'popup_fuel_dark', name: '5. Cockpit [Dark] - Fuel Radar Popup', file: 'figma_artboard_5_popup_fuel.svg' },
  { id: 'popup_group_dark', name: '6. Cockpit [Dark] - Group Settings Popup', file: 'figma_artboard_6_popup_group.svg' },
  { id: 'popup_stop_dark', name: '7. Cockpit [Dark] - Stop Reason Popup', file: 'figma_artboard_7_popup_stop.svg' }
];

const lightSvgs = [
  { id: 'cockpit_idle_light', name: '1. Cockpit [Light] - Idle (Speed on Markers)', file: 'figma_artboard_1_cockpit_idle_light.svg' },
  { id: 'cockpit_orbit_light', name: '2. Cockpit [Light] - Orbit Popup Open', file: 'figma_artboard_2_cockpit_orbit_light.svg' },
  { id: 'popup_settings_light', name: '3. Cockpit [Light] - Quick Settings Popup', file: 'figma_artboard_3_popup_quick_settings_light.svg' },
  { id: 'popup_guardian_light', name: '4. Cockpit [Light] - Ride Guardian Popup', file: 'figma_artboard_4_popup_guardian_light.svg' },
  { id: 'popup_fuel_light', name: '5. Cockpit [Light] - Fuel Radar Popup', file: 'figma_artboard_5_popup_fuel_light.svg' },
  { id: 'popup_group_light', name: '6. Cockpit [Light] - Group Settings Popup', file: 'figma_artboard_6_popup_group_light.svg' },
  { id: 'popup_stop_light', name: '7. Cockpit [Light] - Stop Reason Popup', file: 'figma_artboard_7_popup_stop_light.svg' }
];

const allScreens = [
  ...darkSvgs.map(s => ({ ...s, theme: 'dark', svg: fs.readFileSync(path.join(dir, s.file), 'utf8') })),
  ...lightSvgs.map(s => ({ ...s, theme: 'light', svg: fs.readFileSync(path.join(dir, s.file), 'utf8') }))
];

const pluginCode = `// CoRoute Mobile Prototyping & Screen Importer Plugin (v3.19.0)
// Complete In-Cockpit Popup Architecture with Draggable Orbit Control & Speeds for All Users

const screensData = ${JSON.stringify(allScreens)};

async function run() {
  await figma.loadFontAsync({ family: "Inter", style: "Regular" });
  await figma.loadFontAsync({ family: "Inter", style: "Bold" });

  // 0. Remove any older frames from previous generation for a pristine canvas
  const oldNodes = figma.currentPage.children.filter(n =>
    n.name && (
      n.name.includes('Cockpit') ||
      n.name.includes('Live Cockpit') ||
      n.name.includes('Glove Quick Settings') ||
      n.name.includes('Ride Guardian') ||
      n.name.includes('Fuel Estimation') ||
      n.name.includes('Fuel Range') ||
      n.name.includes('Group Settings') ||
      n.name.includes('Quick Stop') ||
      n.name.includes('CoRoute') ||
      n.name.includes('Interactive Prototyping')
    )
  );
  oldNodes.forEach(n => {
    try { n.remove(); } catch (e) {}
  });

  const screenNodes = {};
  const allCreated = [];

  // Helper to create header section banners
  function createBanner(text, subtext, x, y, isDark) {
    const frame = figma.createFrame();
    frame.name = text;
    frame.x = x;
    frame.y = y;
    frame.resize(3360, 68);
    frame.fills = [{ type: 'SOLID', color: isDark ? { r: 0.04, g: 0.06, b: 0.09 } : { r: 0.95, g: 0.97, b: 0.99 } }];
    frame.strokes = [{ type: 'SOLID', color: isDark ? { r: 0.12, g: 0.16, b: 0.23 } : { r: 0.88, g: 0.91, b: 0.94 } }];
    frame.strokeWeight = 1.5;
    frame.cornerRadius = 16;

    const t = figma.createText();
    t.fontName = { family: "Inter", style: "Bold" };
    t.characters = text.toUpperCase();
    t.fontSize = 18;
    t.x = 24;
    t.y = 16;
    t.fills = [{ type: 'SOLID', color: isDark ? { r: 0.0, g: 0.9, b: 1.0 } : { r: 0.0, g: 0.51, b: 0.56 } }];
    frame.appendChild(t);

    const sub = figma.createText();
    sub.fontName = { family: "Inter", style: "Regular" };
    sub.characters = "  •  " + subtext;
    sub.fontSize = 14;
    sub.x = 24 + t.width + 12;
    sub.y = 19;
    sub.fills = [{ type: 'SOLID', color: isDark ? { r: 0.58, g: 0.64, b: 0.72 } : { r: 0.39, g: 0.45, b: 0.54 } }];
    frame.appendChild(sub);

    figma.currentPage.appendChild(frame);
    allCreated.push(frame);
    return frame;
  }

  // 1. Create Dark Mode Header Banner
  createBanner(
    "🌙 CoRoute Dark Mode Suite: In-Cockpit Popups & Draggable Orbit",
    "Live speed on all markers • Draggable Orbit control • All screens render as in-cockpit popup overlays",
    0, 0, true
  );

  // 2. Render Dark Mode Screens (Row 1 at y = 90)
  for (let i = 0; i < 7; i++) {
    const s = screensData[i];
    try {
      const node = figma.createNodeFromSvg(s.svg);
      node.name = s.name;
      node.x = i * 480;
      node.y = 90;
      figma.currentPage.appendChild(node);
      screenNodes[s.id] = node;
      allCreated.push(node);
    } catch (e) {
      console.error("Error creating " + s.name, e);
    }
  }

  // 3. Create Light Mode Header Banner
  createBanner(
    "☀️ CoRoute Light Mode Suite: In-Cockpit Popups & Draggable Orbit",
    "High-contrast outdoor glare resistance • Draggable thumb reach • Seamless in-cockpit popups",
    0, 1020, false
  );

  // 4. Render Light Mode Screens (Row 2 at y = 1110)
  for (let i = 7; i < 14; i++) {
    const s = screensData[i];
    try {
      const node = figma.createNodeFromSvg(s.svg);
      node.name = s.name;
      node.x = (i - 7) * 480;
      node.y = 1110;
      figma.currentPage.appendChild(node);
      screenNodes[s.id] = node;
      allCreated.push(node);
    } catch (e) {
      console.error("Error creating " + s.name, e);
    }
  }

  // 5. Connect Interactive Prototype Wiring
  async function wireNode(sourceFrame, searchPredicate, targetFrame, description) {
    if (!sourceFrame || !targetFrame) return;
    try {
      let targetClickable = sourceFrame.findOne(searchPredicate);
      if (!targetClickable) targetClickable = sourceFrame;

      const actionObj = {
        type: 'NODE',
        destinationId: targetFrame.id,
        navigation: 'NAVIGATE',
        transition: {
          type: 'DISSOLVE',
          easing: { type: 'EASE_OUT' },
          duration: 0.18
        },
        preserveScrollPosition: true
      };

      const reaction = {
        trigger: { type: 'ON_CLICK' },
        action: actionObj,
        actions: [actionObj]
      };

      if (targetClickable.setReactionsAsync) {
        await targetClickable.setReactionsAsync([reaction]);
      } else if (targetClickable.reactions) {
        targetClickable.reactions = [reaction];
      }
    } catch (err) {
      console.log("Wiring note for " + description + ":", err.message);
    }
  }

  // Wire Themes (Dark and Light mode popup loops)
  for (const t of ['dark', 'light']) {
    const idle = screenNodes['cockpit_idle_' + t];
    const orbit = screenNodes['cockpit_orbit_' + t];
    const settings = screenNodes['popup_settings_' + t];
    const guardian = screenNodes['popup_guardian_' + t];
    const fuel = screenNodes['popup_fuel_' + t];
    const group = screenNodes['popup_group_' + t];
    const stop = screenNodes['popup_stop_' + t];

    if (!idle) continue;

    // --- COCKPIT IDLE SCREEN WIRING ---
    // Tap Draggable Orbit FAB -> Opens Orbit Popup Open State
    await wireNode(idle, n => n.name === 'btn_orbit_fab', orbit, 'Idle -> Orbit Open');

    // Bottom Dock: STOP -> Stop Reason Popup
    await wireNode(idle, n => n.name === 'btn_dock_stop' || (n.characters && n.characters === 'STOP'), stop, 'Idle -> Stop Popup');

    // Bottom Dock: FUEL -> Fuel Radar Popup
    await wireNode(idle, n => n.name === 'btn_dock_fuel' || (n.characters && n.characters === 'FUEL'), fuel, 'Idle -> Fuel Popup');

    // Bottom Dock: LINK -> Guardian Link Popup
    await wireNode(idle, n => n.name === 'btn_dock_guardian' || (n.characters && n.characters === 'LINK'), guardian, 'Idle -> Guardian Popup');

    // Bottom Dock: MORE -> Quick Settings Popup
    await wireNode(idle, n => n.name === 'btn_dock_more' || (n.characters && n.characters === 'MORE'), settings, 'Idle -> Settings Popup');

    // Bottom Sheet: Convoy Title -> Group Settings Popup
    await wireNode(idle, n => n.name === 'btn_convoy_header' || (n.characters && n.characters.includes('Bangalore Highway Convoy')), group, 'Idle -> Group Popup');

    // Bottom Sheet: Usable Range Strip -> Fuel Radar Popup
    await wireNode(idle, n => n.name === 'btn_fuel_strip' || (n.characters && n.characters.includes('Usable Range')), fuel, 'Idle -> Fuel Popup');

    // --- COROUTE ORBIT POPUP CARD WIRING ---
    if (orbit) {
      // Tap backdrop -> Closes back to Idle Cockpit
      await wireNode(orbit, n => n.name === 'btn_orbit_backdrop', idle, 'Orbit Backdrop -> Idle');

      // Tile 1: Intercom -> Returns to Idle (active VOX feedback)
      await wireNode(orbit, n => n.name === 'btn_orbit_intercom', idle, 'Orbit Intercom -> Idle');

      // Tile 2: Group -> Opens Group Settings Popup
      await wireNode(orbit, n => n.name === 'btn_orbit_group', group, 'Orbit -> Group Popup');

      // Tile 3: Fuel -> Opens Fuel Radar Popup
      await wireNode(orbit, n => n.name === 'btn_orbit_fuel', fuel, 'Orbit -> Fuel Popup');

      // Tile 4: Route -> Opens Fuel / Essentials Popup
      await wireNode(orbit, n => n.name === 'btn_orbit_route', fuel, 'Orbit -> Fuel Popup');

      // Tile 5: Guardian -> Opens Guardian Link Popup
      await wireNode(orbit, n => n.name === 'btn_orbit_guardian', guardian, 'Orbit -> Guardian Popup');

      // Tile 6: More -> Opens Glove Quick Settings Popup
      await wireNode(orbit, n => n.name === 'btn_orbit_more', settings, 'Orbit -> Settings Popup');
    }

    // --- QUICK SETTINGS POPUP MODAL WIRING ---
    if (settings) {
      // Done button or backdrop -> Back to Idle
      await wireNode(settings, n => n.name === 'btn_close_popup' || (n.characters && n.characters === 'Done'), idle, 'Settings Done -> Idle');
      await wireNode(settings, n => n.name === 'btn_modal_backdrop', idle, 'Settings Backdrop -> Idle');

      // Hero Guardian -> Guardian Popup
      await wireNode(settings, n => n.name === 'btn_hero_guardian' || (n.characters && n.characters.includes('Guardian Link')), guardian, 'Settings -> Guardian');

      // Hero Fuel -> Fuel Popup
      await wireNode(settings, n => n.name === 'btn_hero_fuel' || (n.characters && n.characters.includes('Fuel / Range')), fuel, 'Settings -> Fuel');

      // Open Group Settings -> Group Popup
      await wireNode(settings, n => n.name === 'btn_open_group_settings' || (n.characters && n.characters.includes('Open Group Settings')), group, 'Settings -> Group');
    }

    // --- RIDE GUARDIAN POPUP MODAL WIRING ---
    if (guardian) {
      await wireNode(guardian, n => n.name === 'btn_close_popup' || (n.characters && n.characters === 'Done'), idle, 'Guardian Done -> Idle');
      await wireNode(guardian, n => n.name === 'btn_modal_backdrop', idle, 'Guardian Backdrop -> Idle');
      await wireNode(guardian, n => n.name === 'btn_return_cockpit', idle, 'Guardian Return -> Idle');
    }

    // --- FUEL RADAR POPUP MODAL WIRING ---
    if (fuel) {
      await wireNode(fuel, n => n.name === 'btn_close_popup' || (n.characters && n.characters === 'Done'), idle, 'Fuel Done -> Idle');
      await wireNode(fuel, n => n.name === 'btn_modal_backdrop', idle, 'Fuel Backdrop -> Idle');
      await wireNode(fuel, n => n.name === 'btn_broadcast_refuel', idle, 'Broadcast Refuel -> Idle');
    }

    // --- GROUP SETTINGS POPUP MODAL WIRING ---
    if (group) {
      await wireNode(group, n => n.name === 'btn_close_popup' || (n.characters && n.characters === 'Done'), idle, 'Group Done -> Idle');
      await wireNode(group, n => n.name === 'btn_modal_backdrop', idle, 'Group Backdrop -> Idle');
      await wireNode(group, n => n.name === 'btn_save_group', idle, 'Save Group -> Idle');
      await wireNode(group, n => n.name === 'btn_group_guardian_share', guardian, 'Group -> Guardian');
    }

    // --- STOP REASON PICKER POPUP MODAL WIRING ---
    if (stop) {
      await wireNode(stop, n => n.name === 'btn_close_popup' || (n.characters && n.characters === 'Done'), idle, 'Stop Done -> Idle');
      await wireNode(stop, n => n.name === 'btn_modal_backdrop', idle, 'Stop Backdrop -> Idle');
      await wireNode(stop, n => n.name === 'btn_stop_fuel', idle, 'Stop Fuel -> Idle');
      await wireNode(stop, n => n.name === 'btn_stop_mechanical', idle, 'Stop Mechanical -> Idle');
      await wireNode(stop, n => n.name === 'btn_stop_rest', idle, 'Stop Rest -> Idle');
      await wireNode(stop, n => n.name === 'btn_stop_regroup', idle, 'Stop Regroup -> Idle');
      await wireNode(stop, n => n.name === 'btn_clear_stop', idle, 'Clear Stop -> Idle');
    }
  }

  // Cross-Theme Switching (Tap Status Bar 'DARK ⇄' / 'LIGHT ⇄' on ANY screen)
  const screensList = ['cockpit_idle', 'cockpit_orbit', 'popup_settings', 'popup_guardian', 'popup_fuel', 'popup_group', 'popup_stop'];
  for (const s of screensList) {
    const darkNode = screenNodes[s + '_dark'];
    const lightNode = screenNodes[s + '_light'];
    if (darkNode && lightNode) {
      await wireNode(darkNode, n => n.name === 'btn_theme_toggle' || (n.characters && n.characters.includes('DARK')), lightNode, 'Dark ' + s + ' -> Light ' + s);
      await wireNode(lightNode, n => n.name === 'btn_theme_toggle' || (n.characters && n.characters.includes('LIGHT')), darkNode, 'Light ' + s + ' -> Dark ' + s);
    }
  }

  // 6. Draw Visual Flow Summary Guide Card on Canvas
  const flowCard = figma.createFrame();
  flowCard.name = "⚡ In-Cockpit Popup Architecture & Interactive Prototyping Guide";
  flowCard.x = 0;
  flowCard.y = 2030;
  flowCard.resize(3360, 220);
  flowCard.fills = [{ type: 'SOLID', color: { r: 0.04, g: 0.07, b: 0.12 } }];
  flowCard.strokes = [{ type: 'SOLID', color: { r: 0.0, g: 0.9, b: 1.0 } }];
  flowCard.strokeWeight = 2;
  flowCard.cornerRadius = 24;

  const fTitle = figma.createText();
  fTitle.fontName = { family: "Inter", style: "Bold" };
  fTitle.characters = "COROUTE IN-COCKPIT POPUP ARCHITECTURE ACTIVE — CLICK 'PRESENT ▶' TO TEST LIVE";
  fTitle.fontSize = 20;
  fTitle.x = 32;
  fTitle.y = 26;
  fTitle.fills = [{ type: 'SOLID', color: { r: 0.0, g: 0.9, b: 1.0 } }];
  flowCard.appendChild(fTitle);

  const fDesc = figma.createText();
  fDesc.fontName = { family: "Inter", style: "Regular" };
  fDesc.characters =
    "All 14 screens maintain the live cockpit map in the background with zero detached screens:\\n" +
    "• LIVE CONVOY SPEEDS: Every rider marker on the map shows real-time telemetry (SB • 72 KM/H, VP • 68 KM/H, RK • 64 KM/H).\\n" +
    "• DRAGGABLE COROUTE ORBIT: Tap the golden orbit FAB to open the 6-tile Quick Access popup card (Intercom, Group, Fuel, Route, Guardian, More).\\n" +
    "• IN-COCKPIT POPUP MODALS: Quick Settings, Guardian Link, Fuel Radar, Group Settings, and Stop Reason Picker render directly as map overlays.\\n" +
    "• BUTTERY DISMISS: Tap 'Done', any action, or the dimmed backdrop to return smoothly to the Live Cockpit Map.\\n" +
    "• DUAL-MODE PROTO: Tap 'DARK ⇄' / 'LIGHT ⇄' in the top status bar on any screen to switch themes seamlessly.";
  fDesc.fontSize = 13;
  fDesc.lineHeight = { value: 24, unit: 'PIXELS' };
  fDesc.x = 32;
  fDesc.y = 66;
  fDesc.fills = [{ type: 'SOLID', color: { r: 0.8, g: 0.86, b: 0.94 } }];
  flowCard.appendChild(fDesc);

  figma.currentPage.appendChild(flowCard);
  allCreated.push(flowCard);

  // Zoom to fit all 14 screens and guide in the viewport
  figma.currentPage.selection = allCreated;
  figma.viewport.scrollAndZoomIntoView(allCreated);

  figma.notify("✅ CoRoute: 14 In-Cockpit Popup screens and interactive prototyping created successfully!");
  figma.closePlugin();
}

run();
`;

fs.writeFileSync(path.join(dir, 'plugin', 'code.js'), pluginCode, 'utf8');
console.log('Successfully generated plugin/code.js with 14 screens and in-cockpit popup prototype wiring!');
console.log('Code size:', pluginCode.length, 'bytes');
