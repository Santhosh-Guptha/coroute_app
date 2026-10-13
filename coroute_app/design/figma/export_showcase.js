const fs = require('fs');
const path = require('path');

const figmaDir = path.join(__dirname);
const outDir = 'C:\\Users\\santhosh\\.gemini\\antigravity\\brain\\6a63fc9f-a4ad-4ee4-bb81-a612ccdc100b';

const screens = [
  {
    id: 'cockpit_idle',
    title: '1. Minimal Cockpit Map (Idle / In-Flight)',
    codeFile: 'coroute_app/lib/presentation/rider/live_cockpit_map_screen.dart',
    darkFile: 'figma_artboard_1_cockpit_idle.svg',
    lightFile: 'figma_artboard_1_cockpit_idle_light.svg',
    desc: '100% map hero with minimal frosted-glass top status pill (MinimalCockpitTopBar), 3 floating right-side controls (brightness, auto-follow, sheet expand), Hold-to-SOS (56dp) pinned bottom-left, draggable Orbit control, live speeds on all rider markers, and collapsed 2x2 metric strip.'
  },
  {
    id: 'cockpit_orbit',
    title: '2. Draggable Orbit Control (Quick Access Popup)',
    codeFile: 'coroute_app/lib/presentation/rider/widgets/coroute_orbit_control.dart',
    darkFile: 'figma_artboard_2_cockpit_orbit.svg',
    lightFile: 'figma_artboard_2_cockpit_orbit_light.svg',
    desc: 'Draggable 52dp thumb FAB with glowing amber orbit rings. Tap opens 6-tile floating HUD popup on map: Intercom VOX, Group, Fuel, Route, Guardian, and Glove Quick Settings.'
  },
  {
    id: 'popup_quick_settings',
    title: '3. Glove Quick Settings Modal',
    codeFile: 'coroute_app/lib/presentation/rider/widgets/glove_quick_settings_modal.dart',
    darkFile: 'figma_artboard_3_popup_quick_settings.svg',
    lightFile: 'figma_artboard_3_popup_quick_settings_light.svg',
    desc: 'In-cockpit popup with 2x3 grid of oversized cards: Voice Alert cycles, Ride Guardian Share, Usable Fuel Range, Auto-Follow, Keep Screen On, Intercom VOX.'
  },
  {
    id: 'popup_guardian',
    title: '4. Ride Guardian Link Share',
    codeFile: 'coroute_app/lib/presentation/rider/guardian_sheet.dart',
    darkFile: 'figma_artboard_4_popup_guardian.svg',
    lightFile: 'figma_artboard_4_popup_guardian_light.svg',
    desc: 'Live web tracking link popup with PIN security, active expiry timer, and one-tap share for family or emergency contacts.'
  },
  {
    id: 'popup_fuel',
    title: '5. Fuel Range & Refuel Radar',
    codeFile: 'coroute_app/lib/presentation/rider/fuel_sheet.dart',
    darkFile: 'figma_artboard_5_popup_fuel.svg',
    lightFile: 'figma_artboard_5_popup_fuel_light.svg',
    desc: 'In-cockpit fuel radar popup showing usable range (185 km remaining), fuel gauge meter, refuel confirmation button, and bike fuel specs.'
  },
  {
    id: 'popup_group',
    title: '6. Group Settings & Sweeper Assignment',
    codeFile: 'coroute_app/lib/presentation/ride/group_settings_sheet.dart',
    darkFile: 'figma_artboard_6_popup_group.svg',
    lightFile: 'figma_artboard_6_popup_group_light.svg',
    desc: 'Ride join code, convoy member ladder, lead and sweeper role assignments, convoy speed limits, and offline map prefetch.'
  },
  {
    id: 'popup_stop',
    title: '7. Quick Stop Reason Picker',
    codeFile: 'coroute_app/lib/presentation/rider/quick_stop_reason_modal.dart',
    darkFile: 'figma_artboard_7_popup_stop.svg',
    lightFile: 'figma_artboard_7_popup_stop_light.svg',
    desc: 'In-cockpit modal with 4 oversized glove buttons (Mechanical, Fuel, Rest/Food, Emergency) for 1-tap broadcast to convoy without typing.'
  }
];

let html = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>CoRoute v3.21.0 - Present Working Application Screens</title>
<style>
  :root {
    --bg: #070A0F;
    --surface: #0F172A;
    --border: #1E293B;
    --cyan: #00E5FF;
    --amber: #F59E0B;
    --text: #F8FAFC;
    --muted: #94A3B8;
  }
  body {
    margin: 0;
    padding: 24px;
    background: var(--bg);
    color: var(--text);
    font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif;
  }
  header {
    max-width: 1400px;
    margin: 0 auto 32px;
    padding-bottom: 20px;
    border-bottom: 1px solid var(--border);
  }
  h1 {
    color: var(--cyan);
    font-size: 28px;
    margin: 0 0 8px;
    display: flex;
    align-items: center;
    gap: 12px;
  }
  .badge {
    background: rgba(0,229,255,0.15);
    color: var(--cyan);
    font-size: 13px;
    padding: 4px 10px;
    border-radius: 12px;
    border: 1px solid var(--cyan);
  }
  p.subtitle {
    color: var(--muted);
    font-size: 15px;
    margin: 0;
  }
  .controls {
    display: flex;
    gap: 16px;
    margin: 20px 0 0;
  }
  button.toggle-btn {
    background: var(--surface);
    color: var(--text);
    border: 1px solid var(--border);
    padding: 10px 20px;
    border-radius: 8px;
    font-weight: 700;
    cursor: pointer;
    transition: all 0.2s;
  }
  button.toggle-btn.active {
    background: var(--cyan);
    color: #000;
    border-color: var(--cyan);
  }
  .grid {
    display: grid;
    grid-template-columns: repeat(auto-fit, minmax(400px, 1fr));
    gap: 32px;
    max-width: 1400px;
    margin: 0 auto;
  }
  .screen-card {
    background: var(--surface);
    border: 1px solid var(--border);
    border-radius: 20px;
    padding: 20px;
    display: flex;
    flex-direction: column;
  }
  .screen-title {
    font-size: 18px;
    font-weight: 800;
    margin: 0 0 4px;
    color: var(--text);
  }
  .screen-code {
    font-family: monospace;
    font-size: 11px;
    color: var(--cyan);
    margin-bottom: 8px;
  }
  .screen-desc {
    color: var(--muted);
    font-size: 13px;
    line-height: 1.5;
    margin: 0 0 16px;
  }
  .svg-container {
    background: #000;
    border-radius: 16px;
    overflow: hidden;
    display: flex;
    justify-content: center;
    border: 1px solid var(--border);
    box-shadow: 0 8px 24px rgba(0,0,0,0.5);
  }
  .svg-container svg {
    width: 100%;
    max-width: 412px;
    height: auto;
    aspect-ratio: 412/870;
  }
</style>
</head>
<body>
<header>
  <h1>CoRoute v3.21.0 Working Screens <span class="badge">LIVE IN PRODUCTION</span></h1>
  <p class="subtitle">Complete visual design and interaction specification for pairing with other agents or redesigning in Figma.</p>
  <div class="controls">
    <button class="toggle-btn active" id="btn-dark" onclick="setTheme('dark')">Dark Theme (Night Rider)</button>
    <button class="toggle-btn" id="btn-light" onclick="setTheme('light')">Light Theme (Day High-Glare)</button>
  </div>
</header>
<div class="grid">
`;

screens.forEach(s => {
  const darkSvg = fs.readFileSync(path.join(figmaDir, s.darkFile), 'utf8');
  const lightSvg = fs.readFileSync(path.join(figmaDir, s.lightFile), 'utf8');

  html += `  <div class="screen-card">
    <div class="screen-title">${s.title}</div>
    <div class="screen-code">${s.codeFile}</div>
    <div class="screen-desc">${s.desc}</div>
    <div class="svg-container svg-dark">${darkSvg}</div>
    <div class="svg-container svg-light" style="display:none;">${lightSvg}</div>
  </div>\n`;
});

html += `</div>
<script>
function setTheme(theme) {
  const isDark = theme === 'dark';
  document.getElementById('btn-dark').classList.toggle('active', isDark);
  document.getElementById('btn-light').classList.toggle('active', !isDark);
  document.querySelectorAll('.svg-dark').forEach(el => el.style.display = isDark ? 'flex' : 'none');
  document.querySelectorAll('.svg-light').forEach(el => el.style.display = !isDark ? 'flex' : 'none');
}
</script>
</body>
</html>`;

fs.writeFileSync(path.join(outDir, 'coroute_working_application_screens_showcase.html'), html, 'utf8');
console.log('Successfully generated coroute_working_application_screens_showcase.html (' + html.length + ' bytes)');
