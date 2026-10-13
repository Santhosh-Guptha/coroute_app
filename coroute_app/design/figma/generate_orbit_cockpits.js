const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname);

// Helper for SVG defs (filters, clips, gradients)
function defs(isDark) {
  if (isDark) {
    return `  <defs>
    <filter id="glow-cyan" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="6" result="blur" />
      <feComposite in="SourceGraphic" in2="blur" operator="over" />
    </filter>
    <filter id="glow-sos" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="8" result="blur" />
      <feComposite in="SourceGraphic" in2="blur" operator="over" />
    </filter>
    <filter id="glow-amber" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="6" result="blur" />
      <feComposite in="SourceGraphic" in2="blur" operator="over" />
    </filter>
    <filter id="glow-orbit" x="-30%" y="-30%" width="160%" height="160%">
      <feGaussianBlur stdDeviation="7" result="blur" />
      <feComposite in="SourceGraphic" in2="blur" operator="over" />
    </filter>
    <clipPath id="screen-clip">
      <rect width="412" height="870" rx="36" fill="#070A0F" />
    </clipPath>
  </defs>`;
  } else {
    return `  <defs>
    <filter id="shadow-card-light" x="-10%" y="-10%" width="120%" height="120%">
      <feDropShadow dx="0" dy="3" stdDeviation="4" flood-color="#64748B" flood-opacity="0.14" />
    </filter>
    <filter id="shadow-popup-light" x="-10%" y="-10%" width="120%" height="120%">
      <feDropShadow dx="0" dy="6" stdDeviation="12" flood-color="#0F172A" flood-opacity="0.18" />
    </filter>
    <clipPath id="screen-clip">
      <rect width="412" height="870" rx="36" fill="#F8FAFC" />
    </clipPath>
  </defs>`;
  }
}

// System Status Bar with Live Theme Toggle Pill
function statusBar(isDark) {
  const bg = isDark ? '#1E293B' : '#E2E8F0';
  const border = isDark ? '#334155' : '#CBD5E1';
  const textMuted = isDark ? '#94A3B8' : '#64748B';
  const brand = isDark ? '#00E5FF' : '#00838F';
  const themeLabel = isDark ? 'DARK' : 'LIGHT';

  return `    <!-- System Status Bar -->
    <g id="System_Status_Bar" transform="translate(24, 14)">
      <!-- Interactive Theme Toggle Button -->
      <g id="btn_theme_toggle">
        <rect x="0" y="0" width="76" height="22" rx="11" fill="${bg}" stroke="${border}" stroke-width="1" />
        <text x="38" y="15" text-anchor="middle" fill="${brand}" font-size="10" font-weight="800" font-family="JetBrains Mono, monospace">${themeLabel} &#x21C4;</text>
      </g>
      <text x="94" y="16" fill="${textMuted}" font-size="12" font-weight="700" font-family="JetBrains Mono, monospace">12:40</text>
      <text x="296" y="16" fill="${brand}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">5G</text>
      <text x="322" y="16" fill="${textMuted}" font-size="11" font-weight="700" font-family="JetBrains Mono, monospace">&#x25B2;&#x25B2;&#x25B2;</text>
      <text x="344" y="16" fill="${textMuted}" font-size="11" font-weight="700" font-family="JetBrains Mono, monospace">88%</text>
    </g>`;
}

// Base Cockpit Map Layer (Map, polyline, markers with SPEED, top HUD, dock, bottom sheet)
function renderCockpitBase(isDark, orbitSide = 'right') {
  const bg = isDark ? '#070A0F' : '#F8FAFC';
  const roadBg = isDark ? '#0A0E17' : '#EFF6FF';
  const roadStroke = isDark ? '#162235' : '#DBEAFE';
  const roadText = isDark ? '#475569' : '#94A3B8';
  const cyan = isDark ? '#00E5FF' : '#00838F';
  const cyanLight = isDark ? 'rgba(0,229,255,0.15)' : '#E0F2FE';
  const hudBg = isDark ? '#0F172A' : '#FFFFFF';
  const hudStroke = isDark ? '#1E293B' : '#E2E8F0';
  const textPrimary = isDark ? '#FFFFFF' : '#0F172A';
  const textMuted = isDark ? '#94A3B8' : '#64748B';
  const dockBg = isDark ? '#0F172A' : '#FFFFFF';
  const dockStroke = isDark ? '#1E293B' : '#E2E8F0';
  const dockBtnBg = isDark ? '#1E293B' : '#F1F5F9';
  const dockBtnBorder = isDark ? '#334155' : '#E2E8F0';
  const sheetBg = isDark ? '#0F172A' : '#FFFFFF';
  const sheetStroke = isDark ? '#1E293B' : '#E2E8F0';
  const shadowAttr = isDark ? '' : 'filter="url(#shadow-card-light)"';
  const glowCyan = isDark ? 'filter="url(#glow-cyan)"' : '';
  const glowSos = isDark ? 'filter="url(#glow-sos)"' : '';

  // Orbit FAB position (draggable): left or right edge
  const orbitX = orbitSide === 'left' ? 16 : 344;
  const orbitY = 360;

  return `    <!-- Background Canvas -->
    <rect width="412" height="870" fill="${bg}" />

    <!-- Vector Map Grid (Background) -->
    <g id="Map_Network" opacity="0.95">
      <rect width="412" height="870" fill="${roadBg}" />
      <path d="M-20 220 H432" stroke="${roadStroke}" stroke-width="8" />
      <path d="M-20 460 H432" stroke="${roadStroke}" stroke-width="10" />
      <path d="M140 -20 V890" stroke="${roadStroke}" stroke-width="8" />
      <path d="M300 -20 V890" stroke="${roadStroke}" stroke-width="8" />
      <path d="M-20 620 Q160 400 432 540" stroke="${roadStroke}" stroke-width="16" />

      <text x="32" y="200" fill="${roadText}" font-size="11" font-weight="700" font-family="JetBrains Mono, monospace">NH 48 EXPRESSWAY</text>
      <text x="32" y="440" fill="${roadText}" font-size="11" font-weight="700" font-family="JetBrains Mono, monospace">NICE ROAD INTERCHANGE</text>

      <!-- Active Navigation Guidance Polyline -->
      <path d="M70 660 Q140 540 190 460 T290 320 L330 180" stroke="${cyan}" stroke-width="6" stroke-linecap="round" stroke-linejoin="round" ${glowCyan} />
      <path d="M70 660 Q140 540 190 460 T290 320 L330 180" stroke="#FFFFFF" stroke-width="2" stroke-linecap="round" stroke-dasharray="5 7" opacity="0.9" />

      <!-- Convoy Marker 1: Sweeper RK with Live Speed Badge -->
      <g id="Marker_Sweeper_RK" transform="translate(68, 646)">
        <circle r="16" fill="${isDark ? '#0F172A' : '#FFFFFF'}" stroke="${isDark ? '#FF9100' : '#BD5B00'}" stroke-width="3" />
        <text y="4" text-anchor="middle" fill="${isDark ? '#FF9100' : '#BD5B00'}" font-size="11" font-weight="700" font-family="JetBrains Mono, monospace">RK</text>
        <rect x="-38" y="20" width="76" height="16" rx="5" fill="${isDark ? '#0F172A' : '#FFFFFF'}" stroke="${isDark ? '#FF9100' : '#BD5B00'}" stroke-width="1" />
        <text y="32" text-anchor="middle" fill="${isDark ? '#FF9100' : '#BD5B00'}" font-size="8" font-weight="800" font-family="JetBrains Mono, monospace">RK &#x2022; 64 KM/H</text>
      </g>

      <!-- Convoy Marker 2: Pack VP with Live Speed Badge -->
      <g id="Marker_Pack_VP" transform="translate(188, 446)">
        <circle r="16" fill="${isDark ? '#0F172A' : '#FFFFFF'}" stroke="${isDark ? '#00E676' : '#16A34A'}" stroke-width="2.5" />
        <text y="4" text-anchor="middle" fill="${isDark ? '#00E676' : '#16A34A'}" font-size="11" font-weight="700" font-family="JetBrains Mono, monospace">VP</text>
        <rect x="-38" y="20" width="76" height="16" rx="5" fill="${isDark ? '#0F172A' : '#FFFFFF'}" stroke="${isDark ? '#00E676' : '#16A34A'}" stroke-width="1" />
        <text y="32" text-anchor="middle" fill="${isDark ? '#00E676' : '#16A34A'}" font-size="8" font-weight="800" font-family="JetBrains Mono, monospace">VP &#x2022; 68 KM/H</text>
      </g>

      <!-- Convoy Marker 3: Lead SB with Live Speed Badge -->
      <g id="Marker_Lead_SB" transform="translate(328, 176)">
        <circle r="22" fill="${isDark ? 'rgba(0,229,255,0.25)' : 'rgba(0,131,143,0.2)'}" />
        <circle r="17" fill="${isDark ? '#0F172A' : '#FFFFFF'}" stroke="${cyan}" stroke-width="3" />
        <text y="4" text-anchor="middle" fill="${cyan}" font-size="12" font-weight="800" font-family="JetBrains Mono, monospace">SB</text>
        <rect x="-38" y="-34" width="76" height="16" rx="5" fill="${cyan}" />
        <text y="-22" text-anchor="middle" fill="${isDark ? '#070A0F' : '#FFFFFF'}" font-size="8.5" font-weight="900" font-family="JetBrains Mono, monospace">SB &#x2022; 72 KM/H</text>
      </g>
    </g>

${statusBar(isDark)}

    <!-- Minimal Frosted-Glass Top Status Pill (MinimalCockpitTopBar) -->
    <g id="Minimal_Cockpit_Top_Bar" transform="translate(16, 44)">
      <rect width="380" height="48" rx="24" fill="${isDark ? 'rgba(7,10,15,0.85)' : 'rgba(255,255,255,0.92)'}" stroke="${isDark ? 'rgba(0,229,255,0.35)' : 'rgba(0,131,143,0.3)'}" stroke-width="1.2" ${shadowAttr} />
      <!-- Left: Destination & Distance -->
      <text x="20" y="27" fill="${textPrimary}" font-size="14" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">To Hampi, 142 km</text>
      <text x="20" y="40" fill="${textMuted}" font-size="10" font-weight="600" font-family="Plus Jakarta Sans, sans-serif">NH 48 Expressway &#x2022; Next stop 42 km</text>
      <!-- Right: Live GPS Status Dot -->
      <circle cx="340" cy="24" r="4" fill="${cyan}" ${glowCyan} />
      <text x="352" y="27" fill="${cyan}" font-size="10" font-weight="800" font-family="JetBrains Mono, monospace">GPS</text>
    </g>

    <!-- Draggable CoRoute Orbit Control FAB -->
    <g id="btn_orbit_fab" transform="translate(${orbitX}, ${orbitY})">
      <circle cx="26" cy="26" r="26" fill="${isDark ? '#0A0E17' : '#FFFFFF'}" stroke="${isDark ? '#F59E0B' : '#D97706'}" stroke-width="2.5" ${shadowAttr} />
      <!-- Orbital atom rings icon -->
      <g transform="translate(26, 26)">
        <ellipse rx="16" ry="7" fill="none" stroke="${isDark ? '#F59E0B' : '#D97706'}" stroke-width="2" transform="rotate(-30)" />
        <ellipse rx="16" ry="7" fill="none" stroke="${isDark ? '#F59E0B' : '#D97706'}" stroke-width="2" transform="rotate(30)" />
        <circle r="4" fill="${isDark ? '#F59E0B' : '#D97706'}" />
      </g>
    </g>

    <!-- Floating Right-Side Controls (MapSideControls: Brightness, Re-center, Sheet) -->
    <g id="Map_Side_Controls" transform="translate(352, 530)">
      <!-- 1. Screen On / Brightness -->
      <g id="btn_side_brightness" transform="translate(0, 0)">
        <circle cx="22" cy="22" r="22" fill="${isDark ? '#0F172A' : '#FFFFFF'}" stroke="${isDark ? '#334155' : '#CBD5E1'}" stroke-width="1.2" ${shadowAttr} />
        <circle cx="22" cy="22" r="6" fill="none" stroke="${isDark ? '#F59E0B' : '#D97706'}" stroke-width="2" />
        <line x1="22" y1="10" x2="22" y2="13" stroke="${isDark ? '#F59E0B' : '#D97706'}" stroke-width="2" stroke-linecap="round" />
        <line x1="22" y1="31" x2="22" y2="34" stroke="${isDark ? '#F59E0B' : '#D97706'}" stroke-width="2" stroke-linecap="round" />
      </g>
      <!-- 2. Re-Center on Me Crosshair (Active Cyan Glow) -->
      <g id="btn_side_recenter" transform="translate(0, 52)">
        <circle cx="22" cy="22" r="22" fill="${isDark ? '#0F172A' : '#FFFFFF'}" stroke="${cyan}" stroke-width="1.8" ${glowCyan} ${shadowAttr} />
        <circle cx="22" cy="22" r="7" fill="none" stroke="${cyan}" stroke-width="2" />
        <circle cx="22" cy="22" r="2.5" fill="${cyan}" />
        <line x1="22" y1="9" x2="22" y2="12" stroke="${cyan}" stroke-width="2" />
        <line x1="22" y1="32" x2="22" y2="35" stroke="${cyan}" stroke-width="2" />
        <line x1="9" y1="22" x2="12" y2="22" stroke="${cyan}" stroke-width="2" />
        <line x1="32" y1="22" x2="35" y2="22" stroke="${cyan}" stroke-width="2" />
      </g>
      <!-- 3. Open Ride Sheet Chevron -->
      <g id="btn_side_sheet" transform="translate(0, 104)">
        <circle cx="22" cy="22" r="22" fill="${isDark ? '#0F172A' : '#FFFFFF'}" stroke="${isDark ? '#334155' : '#CBD5E1'}" stroke-width="1.2" ${shadowAttr} />
        <path d="M15 25 L22 18 L29 25" fill="none" stroke="${textPrimary}" stroke-width="2.2" stroke-linecap="round" stroke-linejoin="round" />
      </g>
    </g>

    <!-- Hold-to-SOS Button (Always pinned bottom-left above collapsed sheet) -->
    <g id="btn_cockpit_sos" transform="translate(16, 686)">
      <circle cx="28" cy="28" r="28" fill="#DC2626" stroke="#EF4444" stroke-width="2" ${glowSos} ${shadowAttr} />
      <path d="M28 17 L39 37 H17 Z" fill="none" stroke="#FFFFFF" stroke-width="2.2" stroke-linejoin="round" />
      <line x1="28" y1="24" x2="28" y2="30" stroke="#FFFFFF" stroke-width="2.2" stroke-linecap="round" />
      <circle cx="28" cy="34" r="1.2" fill="#FFFFFF" />
      <text x="28" y="46" text-anchor="middle" fill="#FFFFFF" font-size="8" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">SOS</text>
    </g>

    <!-- Collapsed Bottom Sheet: 2x2 Metric Strip Header -->
    <g id="Collapsed_Bottom_Sheet" transform="translate(0, 752)">
      <path d="M0 20 C0 8.954 8.954 0 20 0 H392 C403.046 0 412 8.954 412 20 V118 H0 Z" fill="${sheetBg}" stroke="${sheetStroke}" stroke-width="1.2" ${shadowAttr} />
      <!-- Drag handle -->
      <rect x="188" y="8" width="36" height="4" rx="2" fill="${isDark ? '#334155' : '#CBD5E1'}" />

      <!-- 4 Key Numbers (2x2 Grid) -->
      <g id="Metrics_2x2_Grid" transform="translate(24, 22)">
        <!-- 1. Remaining -->
        <g id="metric_remaining" transform="translate(0, 0)">
          <text x="0" y="24" fill="${textPrimary}" font-size="20" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">142 km</text>
          <text x="0" y="38" fill="${textMuted}" font-size="10" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">left</text>
        </g>
        <line x1="88" y1="8" x2="88" y2="44" stroke="${sheetStroke}" stroke-width="1" />

        <!-- 2. ETA -->
        <g id="metric_eta" transform="translate(100, 0)">
          <text x="0" y="24" fill="${textPrimary}" font-size="20" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">4:35 PM</text>
          <text x="0" y="38" fill="${textMuted}" font-size="10" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">ETA</text>
        </g>
        <line x1="190" y1="8" x2="190" y2="44" stroke="${sheetStroke}" stroke-width="1" />

        <!-- 3. Riding Count -->
        <g id="metric_riding" transform="translate(202, 0)">
          <text x="0" y="24" fill="${textPrimary}" font-size="20" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">5/8</text>
          <text x="0" y="38" fill="${textMuted}" font-size="10" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">riding</text>
        </g>
        <line x1="264" y1="8" x2="264" y2="44" stroke="${sheetStroke}" stroke-width="1" />

        <!-- 4. Spread -->
        <g id="metric_spread" transform="translate(276, 0)">
          <text x="0" y="24" fill="${textPrimary}" font-size="20" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">2.1 km</text>
          <text x="0" y="38" fill="${textMuted}" font-size="10" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">spread</text>
        </g>
      </g>
    </g>`;

}

// 1. SCREEN 1: COCKPIT IDLE
function buildCockpitIdle(isDark) {
  return `<svg width="412" height="870" viewBox="0 0 412 870" fill="none" xmlns="http://www.w3.org/2000/svg">
${defs(isDark)}
  <g id="CoRoute_Cockpit_Idle_${isDark ? 'Dark' : 'Light'}" clip-path="url(#screen-clip)">
${renderCockpitBase(isDark, isDark ? 'right' : 'left')}
  </g>
</svg>`;
}

// 2. SCREEN 2: COCKPIT WITH COROUTE ORBIT POPUP CARD OPEN
function buildCockpitOrbitOpen(isDark) {
  const cardBg = isDark ? '#0F1622' : '#FFFFFF';
  const cardStroke = isDark ? '#1E293B' : '#E2E8F0';
  const tileBg = isDark ? '#162030' : '#F1F5F9';
  const tileBorder = isDark ? '#1E293B' : '#E2E8F0';
  const textPrimary = isDark ? '#FFFFFF' : '#0F172A';
  const textMuted = isDark ? '#94A3B8' : '#64748B';
  const cyan = isDark ? '#00E5FF' : '#00838F';
  const cyanLight = isDark ? '#083344' : '#E0F2FE';
  const shadowPopup = isDark ? '' : 'filter="url(#shadow-popup-light)"';

  return `<svg width="412" height="870" viewBox="0 0 412 870" fill="none" xmlns="http://www.w3.org/2000/svg">
${defs(isDark)}
  <g id="CoRoute_Cockpit_Orbit_${isDark ? 'Dark' : 'Light'}" clip-path="url(#screen-clip)">
${renderCockpitBase(isDark, isDark ? 'right' : 'left')}

    <!-- Semi-transparent non-blocking backdrop -->
    <rect id="btn_orbit_backdrop" width="412" height="870" fill="#000000" fill-opacity="0.5" />

    <!-- CoRoute Orbit Floating Quick Access Popup Card -->
    <g id="Orbit_Quick_Access_Card" transform="translate(56, 260)">
      <rect width="300" height="240" rx="24" fill="${cardBg}" stroke="${cyan}" stroke-width="1.8" ${shadowPopup} />
      
      <!-- Card Header -->
      <text x="20" y="32" fill="${textPrimary}" font-size="12" font-weight="900" font-family="Plus Jakarta Sans, sans-serif" letter-spacing="1">COROUTE ORBIT</text>
      <rect x="180" y="16" width="102" height="22" rx="11" fill="${cyanLight}" stroke="${cyan}" stroke-width="0.8" />
      <text x="231" y="31" text-anchor="middle" fill="${cyan}" font-size="9.5" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">QUICK ACCESS</text>

      <!-- 6 Quick Access Glove Action Tiles (2 Rows x 3 Columns) -->
      <!-- Row 1: Intercom | Group | Fuel -->
      <!-- 1. Intercom Tile -->
      <g id="btn_orbit_intercom" transform="translate(18, 52)">
        <rect width="80" height="74" rx="16" fill="${tileBg}" stroke="${tileBorder}" stroke-width="1" />
        <path d="M40 24 V34 M36 28 C36 32 44 32 44 28" stroke="${cyan}" stroke-width="2.2" stroke-linecap="round" />
        <text x="40" y="54" text-anchor="middle" fill="${textPrimary}" font-size="11" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Intercom</text>
      </g>

      <!-- 2. Group Tile -> Opens Group Settings Popup -->
      <g id="btn_orbit_group" transform="translate(110, 52)">
        <rect width="80" height="74" rx="16" fill="${tileBg}" stroke="${tileBorder}" stroke-width="1" />
        <!-- 2 riders icon -->
        <circle cx="36" cy="24" r="5" stroke="${cyan}" stroke-width="1.8" />
        <circle cx="46" cy="22" r="4" stroke="${cyan}" stroke-width="1.5" />
        <path d="M28 38 C28 32 34 30 38 30 C42 30 46 32 46 38" stroke="${cyan}" stroke-width="1.8" stroke-linecap="round" />
        <text x="40" y="54" text-anchor="middle" fill="${textPrimary}" font-size="11" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Group</text>
      </g>

      <!-- 3. Fuel Tile -> Opens Fuel Range Radar Popup -->
      <g id="btn_orbit_fuel" transform="translate(202, 52)">
        <rect width="80" height="74" rx="16" fill="${tileBg}" stroke="${tileBorder}" stroke-width="1" />
        <path d="M36 38 V22 H44 V38 M46 26 H48 V32 H46" stroke="${cyan}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" />
        <text x="40" y="54" text-anchor="middle" fill="${textPrimary}" font-size="11" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Fuel</text>
      </g>

      <!-- Row 2: Route | Guardian | More -->
      <!-- 4. Route Tile -> Opens Route Essentials / Corridor -->
      <g id="btn_orbit_route" transform="translate(18, 140)">
        <rect width="80" height="74" rx="16" fill="${tileBg}" stroke="${tileBorder}" stroke-width="1" />
        <!-- Turn arrow icon -->
        <path d="M34 38 V28 C34 24 46 24 46 20 M42 22 L46 18 L50 22" stroke="${cyan}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
        <text x="40" y="54" text-anchor="middle" fill="${textPrimary}" font-size="11" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Route</text>
      </g>

      <!-- 5. Guardian Tile -> Opens Ride Guardian Link Popup -->
      <g id="btn_orbit_guardian" transform="translate(110, 140)">
        <rect width="80" height="74" rx="16" fill="${tileBg}" stroke="${tileBorder}" stroke-width="1" />
        <!-- Shield with check icon -->
        <path d="M40 18 L48 22 V28 C48 34 40 38 40 38 C40 38 32 34 32 28 V22 Z" fill="none" stroke="${cyan}" stroke-width="1.8" stroke-linejoin="round" />
        <path d="M37 28 L39 30 L43 26" stroke="${cyan}" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round" />
        <text x="40" y="54" text-anchor="middle" fill="${textPrimary}" font-size="11" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Guardian</text>
      </g>

      <!-- 6. More Tile -> Opens Glove Quick Settings Popup -->
      <g id="btn_orbit_more" transform="translate(202, 140)">
        <rect width="80" height="74" rx="16" fill="${tileBg}" stroke="${tileBorder}" stroke-width="1" />
        <!-- 4 squares grid icon -->
        <rect x="33" y="22" width="6" height="6" rx="1.5" fill="${cyan}" />
        <rect x="41" y="22" width="6" height="6" rx="1.5" fill="${cyan}" />
        <rect x="33" y="30" width="6" height="6" rx="1.5" fill="${cyan}" />
        <rect x="41" y="30" width="6" height="6" rx="1.5" fill="${cyan}" />
        <text x="40" y="54" text-anchor="middle" fill="${textPrimary}" font-size="11" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">More</text>
      </g>
    </g>
  </g>
</svg>`;
}

// 3. SCREEN 3: COCKPIT WITH GLOVE QUICK SETTINGS MODAL OVERLAY
function buildCockpitQuickSettings(isDark) {
  const modalBg = isDark ? '#0F172A' : '#FFFFFF';
  const cardStroke = isDark ? '#1E293B' : '#E2E8F0';
  const btnBg = isDark ? '#1E293B' : '#F1F5F9';
  const cyan = isDark ? '#00E5FF' : '#00838F';
  const textPrimary = isDark ? '#FFFFFF' : '#0F172A';
  const textMuted = isDark ? '#94A3B8' : '#64748B';
  const shadowPopup = isDark ? '' : 'filter="url(#shadow-popup-light)"';

  return `<svg width="412" height="870" viewBox="0 0 412 870" fill="none" xmlns="http://www.w3.org/2000/svg">
${defs(isDark)}
  <g id="CoRoute_Popup_QuickSettings_${isDark ? 'Dark' : 'Light'}" clip-path="url(#screen-clip)">
${renderCockpitBase(isDark, isDark ? 'right' : 'left')}

    <rect id="btn_modal_backdrop" width="412" height="870" fill="#000000" fill-opacity="0.6" />

    <!-- In-Cockpit Glove Quick Settings Modal Overlay (Slide-Up) -->
    <g id="InCockpit_Settings_Modal" transform="translate(0, 160)">
      <path d="M0 28 C0 12.536 12.536 0 28 0 H384 C399.464 0 412 12.536 412 28 V710 H0 Z" fill="${modalBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowPopup} />
      <rect x="186" y="10" width="40" height="5" rx="2.5" fill="${isDark ? '#334155' : '#CBD5E1'}" />

      <!-- Modal Header -->
      <g transform="translate(20, 24)">
        <text x="0" y="24" fill="${textPrimary}" font-size="18" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">Glove Quick Settings</text>
        <text x="0" y="42" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Cockpit HUD overlay for motorcycle gloves</text>
        <g id="btn_close_popup">
          <rect x="312" y="6" width="60" height="34" rx="12" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
          <text x="342" y="27" text-anchor="middle" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Done</text>
        </g>
        <line x1="0" y1="52" x2="372" y2="52" stroke="${cardStroke}" stroke-width="1" />
      </g>

      <!-- Hero Actions -->
      <g transform="translate(20, 92)">
        <g id="btn_hero_guardian">
          <rect width="180" height="74" rx="18" fill="${isDark ? '#083344' : '#E0F2FE'}" stroke="${cyan}" stroke-width="1.8" />
          <text x="16" y="34" fill="${textPrimary}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Guardian Link</text>
          <text x="16" y="52" fill="${cyan}" font-size="10" font-weight="600" font-family="Plus Jakarta Sans, sans-serif">Share live track &#x2192;</text>
        </g>

        <g id="btn_hero_fuel" transform="translate(192, 0)">
          <rect width="180" height="74" rx="18" fill="${isDark ? '#451A03' : '#FEF3C7'}" stroke="${isDark ? '#F59E0B' : '#D97706'}" stroke-width="1.8" />
          <text x="16" y="34" fill="${textPrimary}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Fuel / Range</text>
          <text x="16" y="52" fill="${isDark ? '#FCD34D' : '#B45309'}" font-size="10" font-weight="600" font-family="JetBrains Mono, monospace">185 km usable &#x2192;</text>
        </g>
      </g>

      <!-- 4 Quick Toggles -->
      <g transform="translate(20, 180)">
        <g transform="translate(0, 0)">
          <rect width="180" height="120" rx="18" fill="${isDark ? '#0A0E17' : '#F8FAFC'}" stroke="${cardStroke}" stroke-width="1" />
          <text x="14" y="28" fill="${textPrimary}" font-size="12" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Voice Alerts</text>
          <circle cx="164" cy="22" r="4.5" fill="${cyan}" />
          <rect x="14" y="70" width="152" height="36" rx="10" fill="${isDark ? '#083344' : '#E0F2FE'}" stroke="${cyan}" stroke-width="1" />
          <text x="90" y="93" text-anchor="middle" fill="${cyan}" font-size="10" font-weight="800" font-family="JetBrains Mono, monospace">ALL ALERTS</text>
        </g>

        <g transform="translate(192, 0)">
          <rect width="180" height="120" rx="18" fill="${isDark ? '#0A0E17' : '#F8FAFC'}" stroke="${cardStroke}" stroke-width="1" />
          <text x="14" y="28" fill="${textPrimary}" font-size="12" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Speed Limit Cap</text>
          <circle cx="164" cy="22" r="4.5" fill="${cyan}" />
          <rect x="14" y="70" width="152" height="36" rx="10" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
          <text x="90" y="93" text-anchor="middle" fill="${cyan}" font-size="10" font-weight="800" font-family="JetBrains Mono, monospace">80 KM/H</text>
        </g>

        <g transform="translate(0, 132)">
          <rect width="180" height="120" rx="18" fill="${isDark ? '#0A0E17' : '#F8FAFC'}" stroke="${cardStroke}" stroke-width="1" />
          <text x="14" y="28" fill="${textPrimary}" font-size="12" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Essentials POI</text>
          <circle cx="164" cy="22" r="4.5" fill="${isDark ? '#00E676' : '#16A34A'}" />
          <rect x="14" y="70" width="152" height="36" rx="10" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
          <text x="90" y="93" text-anchor="middle" fill="${isDark ? '#34D399' : '#15803D'}" font-size="10" font-weight="800" font-family="JetBrains Mono, monospace">ACTIVE</text>
        </g>

        <g transform="translate(192, 132)">
          <rect width="180" height="120" rx="18" fill="${isDark ? '#0A0E17' : '#F8FAFC'}" stroke="${cardStroke}" stroke-width="1" />
          <text x="14" y="28" fill="${textPrimary}" font-size="12" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Keep Screen On</text>
          <circle cx="164" cy="22" r="4.5" fill="${cyan}" />
          <rect x="14" y="70" width="152" height="36" rx="10" fill="${isDark ? '#083344' : '#E0F2FE'}" stroke="${cyan}" stroke-width="1" />
          <text x="90" y="93" text-anchor="middle" fill="${cyan}" font-size="10" font-weight="800" font-family="JetBrains Mono, monospace">LOCKED</text>
        </g>
      </g>

      <!-- Open Full Group Settings Sheet Button -->
      <g id="btn_open_group_settings" transform="translate(20, 620)">
        <rect width="372" height="52" rx="16" fill="${isDark ? '#0A0E17' : '#FFFFFF'}" stroke="${cyan}" stroke-width="1.5" />
        <text x="186" y="32" text-anchor="middle" fill="${cyan}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Open Group Settings Sheet &#x2192;</text>
      </g>
    </g>
  </g>
</svg>`;
}

// 4. SCREEN 4: COCKPIT WITH RIDE GUARDIAN POPUP MODAL OVERLAY
function buildCockpitGuardian(isDark) {
  const modalBg = isDark ? '#0F172A' : '#FFFFFF';
  const cardStroke = isDark ? '#1E293B' : '#E2E8F0';
  const btnBg = isDark ? '#1E293B' : '#F1F5F9';
  const cyan = isDark ? '#00E5FF' : '#00838F';
  const cyanLight = isDark ? '#083344' : '#E0F2FE';
  const textPrimary = isDark ? '#FFFFFF' : '#0F172A';
  const textMuted = isDark ? '#94A3B8' : '#64748B';
  const shadowPopup = isDark ? '' : 'filter="url(#shadow-popup-light)"';

  return `<svg width="412" height="870" viewBox="0 0 412 870" fill="none" xmlns="http://www.w3.org/2000/svg">
${defs(isDark)}
  <g id="CoRoute_Popup_Guardian_${isDark ? 'Dark' : 'Light'}" clip-path="url(#screen-clip)">
${renderCockpitBase(isDark, isDark ? 'right' : 'left')}

    <rect id="btn_modal_backdrop" width="412" height="870" fill="#000000" fill-opacity="0.6" />

    <!-- In-Cockpit Ride Guardian Modal Overlay -->
    <g id="InCockpit_Guardian_Modal" transform="translate(0, 220)">
      <path d="M0 28 C0 12.536 12.536 0 28 0 H384 C399.464 0 412 12.536 412 28 V650 H0 Z" fill="${modalBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowPopup} />
      <rect x="186" y="10" width="40" height="5" rx="2.5" fill="${isDark ? '#334155' : '#CBD5E1'}" />

      <!-- Modal Header -->
      <g transform="translate(20, 24)">
        <text x="0" y="24" fill="${textPrimary}" font-size="18" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">Ride Guardian Link</text>
        <text x="0" y="42" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Zero-install live tracking for family &amp; monitors</text>
        <g id="btn_close_popup">
          <rect x="312" y="6" width="60" height="34" rx="12" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
          <text x="342" y="27" text-anchor="middle" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Done</text>
        </g>
        <line x1="0" y1="52" x2="372" y2="52" stroke="${cardStroke}" stroke-width="1" />
      </g>

      <!-- Security Trust Banner -->
      <g transform="translate(20, 92)">
        <rect width="372" height="96" rx="20" fill="${cyanLight}" stroke="${cyan}" stroke-width="1.5" />
        <text x="18" y="28" fill="${cyan}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif" letter-spacing="1">ZERO APP INSTALL REQUIRED</text>
        <text x="18" y="52" fill="${textPrimary}" font-size="12" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Family can watch convoy live progress in any browser.</text>
        <text x="18" y="78" fill="${cyan}" font-size="10.5" font-weight="700" font-family="JetBrains Mono, monospace">&#x2714; 24h Expiry &#x2022; Read-Only Telemetry</text>
      </g>

      <!-- URL Link Box -->
      <g transform="translate(20, 204)">
        <rect width="372" height="140" rx="20" fill="${isDark ? '#0A0E17' : '#F8FAFC'}" stroke="${cardStroke}" stroke-width="1" />
        <text x="18" y="28" fill="${textMuted}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">LIVE WEB LINK</text>
        <rect x="18" y="40" width="336" height="40" rx="12" fill="${isDark ? '#070A0F' : '#FFFFFF'}" stroke="${cardStroke}" stroke-width="1" />
        <text x="30" y="65" fill="${cyan}" font-size="10.5" font-weight="600" font-family="JetBrains Mono, monospace">https://coroute.duckdns.org/watch/gd_9b3f7a18c2</text>
        
        <g id="btn_copy_link" transform="translate(18, 90)">
          <rect width="162" height="40" rx="12" fill="${cyan}" />
          <text x="81" y="25" text-anchor="middle" fill="${isDark ? '#070A0F' : '#FFFFFF'}" font-size="12" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Copy Link</text>
        </g>
        <g id="btn_share_family" transform="translate(192, 90)">
          <rect width="162" height="40" rx="12" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
          <text x="81" y="25" text-anchor="middle" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Share with Family</text>
        </g>
      </g>

      <!-- Observers Active -->
      <g transform="translate(20, 360)">
        <rect width="372" height="64" rx="16" fill="${isDark ? '#0A0E17' : '#F8FAFC'}" stroke="${cardStroke}" stroke-width="1" />
        <circle cx="28" cy="32" r="5" fill="${isDark ? '#00E676' : '#16A34A'}" />
        <text x="44" y="28" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Mom &amp; Family (Home)</text>
        <text x="44" y="44" fill="${textMuted}" font-size="10" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Viewing via Mobile Chrome</text>
        <text x="352" y="36" text-anchor="end" fill="${cyan}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">LIVE</text>
      </g>

      <!-- Return Button -->
      <g id="btn_return_cockpit" transform="translate(20, 560)">
        <rect width="372" height="52" rx="16" fill="${cyan}" />
        <text x="186" y="32" text-anchor="middle" fill="${isDark ? '#070A0F' : '#FFFFFF'}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">RETURN TO COCKPIT MAP</text>
      </g>
    </g>
  </g>
</svg>`;
}

// 5. SCREEN 5: COCKPIT WITH FUEL ESTIMATION & RADAR POPUP OVERLAY
function buildCockpitFuel(isDark) {
  const modalBg = isDark ? '#0F172A' : '#FFFFFF';
  const cardStroke = isDark ? '#1E293B' : '#E2E8F0';
  const btnBg = isDark ? '#1E293B' : '#F1F5F9';
  const amber = isDark ? '#F59E0B' : '#BD5B00';
  const amberBg = isDark ? '#451A03' : '#FEF3C7';
  const cyan = isDark ? '#00E5FF' : '#00838F';
  const textPrimary = isDark ? '#FFFFFF' : '#0F172A';
  const textMuted = isDark ? '#94A3B8' : '#64748B';
  const shadowPopup = isDark ? '' : 'filter="url(#shadow-popup-light)"';

  return `<svg width="412" height="870" viewBox="0 0 412 870" fill="none" xmlns="http://www.w3.org/2000/svg">
${defs(isDark)}
  <g id="CoRoute_Popup_Fuel_${isDark ? 'Dark' : 'Light'}" clip-path="url(#screen-clip)">
${renderCockpitBase(isDark, isDark ? 'right' : 'left')}

    <rect id="btn_modal_backdrop" width="412" height="870" fill="#000000" fill-opacity="0.6" />

    <!-- In-Cockpit Fuel Radar Modal Overlay -->
    <g id="InCockpit_Fuel_Modal" transform="translate(0, 180)">
      <path d="M0 28 C0 12.536 12.536 0 28 0 H384 C399.464 0 412 12.536 412 28 V690 H0 Z" fill="${modalBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowPopup} />
      <rect x="186" y="10" width="40" height="5" rx="2.5" fill="${isDark ? '#334155' : '#CBD5E1'}" />

      <!-- Modal Header -->
      <g transform="translate(20, 24)">
        <text x="0" y="24" fill="${textPrimary}" font-size="18" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">Fuel Estimation &amp; Radar</text>
        <text x="0" y="42" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Convoy tank ranges &amp; verified highway pumps</text>
        <g id="btn_close_popup">
          <rect x="312" y="6" width="60" height="34" rx="12" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
          <text x="342" y="27" text-anchor="middle" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Done</text>
        </g>
        <line x1="0" y1="52" x2="372" y2="52" stroke="${cardStroke}" stroke-width="1" />
      </g>

      <!-- Hero Range Card -->
      <g transform="translate(20, 92)">
        <rect width="372" height="114" rx="20" fill="${amberBg}" stroke="${amber}" stroke-width="1.8" />
        <text x="18" y="28" fill="${amber}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">YOUR USABLE TANK RANGE</text>
        <text x="18" y="68" fill="${textPrimary}" font-size="36" font-weight="900" font-family="JetBrains Mono, monospace">185</text>
        <text x="96" y="66" fill="${textMuted}" font-size="13" font-weight="700" font-family="JetBrains Mono, monospace">KM</text>
        <text x="18" y="94" fill="${isDark ? '#34D399' : '#15803D'}" font-size="11" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">&#x2714; Destination Reachable (82 km remaining)</text>
      </g>

      <!-- Convoy Fuel Radar List -->
      <g transform="translate(20, 222)">
        <text x="0" y="16" fill="${textMuted}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">CONVOY TANK STATUS</text>
        
        <rect y="26" width="372" height="52" rx="14" fill="${isDark ? '#0A0E17' : '#F8FAFC'}" stroke="${cardStroke}" stroke-width="1" />
        <text x="16" y="56" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Lead SB (KTM 390 Adv)</text>
        <text x="356" y="56" text-anchor="end" fill="${isDark ? '#34D399' : '#15803D'}" font-size="12" font-weight="800" font-family="JetBrains Mono, monospace">185 km</text>

        <rect y="86" width="372" height="52" rx="14" fill="${isDark ? '#0A0E17' : '#F8FAFC'}" stroke="${cardStroke}" stroke-width="1" />
        <text x="16" y="116" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Rider VP (Himalayan 450)</text>
        <text x="356" y="116" text-anchor="end" fill="${isDark ? '#34D399' : '#15803D'}" font-size="12" font-weight="800" font-family="JetBrains Mono, monospace">210 km</text>

        <rect y="146" width="372" height="56" rx="14" fill="${amberBg}" stroke="${amber}" stroke-width="1.2" />
        <text x="16" y="174" fill="${amber}" font-size="12" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Sweeper RK (Low Fuel Deficit)</text>
        <text x="16" y="190" fill="${textMuted}" font-size="10" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Needs station before km 64</text>
        <text x="356" y="180" text-anchor="end" fill="${amber}" font-size="13" font-weight="900" font-family="JetBrains Mono, monospace">64 km &#x26A0;</text>
      </g>

      <!-- Broadcast Button -->
      <g id="btn_broadcast_refuel" transform="translate(20, 600)">
        <rect width="372" height="52" rx="16" fill="${amber}" />
        <text x="186" y="32" text-anchor="middle" fill="${isDark ? '#070A0F' : '#FFFFFF'}" font-size="13" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">BROADCAST REFUEL STOP TO CONVOY</text>
      </g>
    </g>
  </g>
</svg>`;
}

// 6. SCREEN 6: COCKPIT WITH REDESIGNED GROUP SETTINGS OVERLAY
function buildCockpitGroupSettings(isDark) {
  const modalBg = isDark ? '#0F172A' : '#FFFFFF';
  const cardStroke = isDark ? '#1E293B' : '#E2E8F0';
  const btnBg = isDark ? '#1E293B' : '#F1F5F9';
  const cyan = isDark ? '#00E5FF' : '#00838F';
  const cyanLight = isDark ? '#083344' : '#E0F2FE';
  const textPrimary = isDark ? '#FFFFFF' : '#0F172A';
  const textMuted = isDark ? '#94A3B8' : '#64748B';
  const shadowPopup = isDark ? '' : 'filter="url(#shadow-popup-light)"';

  return `<svg width="412" height="870" viewBox="0 0 412 870" fill="none" xmlns="http://www.w3.org/2000/svg">
${defs(isDark)}
  <g id="CoRoute_Popup_Group_${isDark ? 'Dark' : 'Light'}" clip-path="url(#screen-clip)">
${renderCockpitBase(isDark, isDark ? 'right' : 'left')}

    <rect id="btn_modal_backdrop" width="412" height="870" fill="#000000" fill-opacity="0.6" />

    <!-- In-Cockpit Group Settings Modal Overlay -->
    <g id="InCockpit_Group_Modal" transform="translate(0, 180)">
      <path d="M0 28 C0 12.536 12.536 0 28 0 H384 C399.464 0 412 12.536 412 28 V690 H0 Z" fill="${modalBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowPopup} />
      <rect x="186" y="10" width="40" height="5" rx="2.5" fill="${isDark ? '#334155' : '#CBD5E1'}" />

      <!-- Modal Header -->
      <g transform="translate(20, 24)">
        <text x="0" y="24" fill="${textPrimary}" font-size="18" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">Group Settings</text>
        <text x="0" y="42" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Bangalore Highway Convoy &#x2022; Lead Controls</text>
        <g id="btn_close_popup">
          <rect x="312" y="6" width="60" height="34" rx="12" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
          <text x="342" y="27" text-anchor="middle" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Done</text>
        </g>
        <line x1="0" y1="52" x2="372" y2="52" stroke="${cardStroke}" stroke-width="1" />
      </g>

      <!-- Guardian Share Hero Card -->
      <g transform="translate(20, 92)">
        <rect width="372" height="96" rx="20" fill="${cyanLight}" stroke="${cyan}" stroke-width="1.5" />
        <text x="18" y="28" fill="${cyan}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">RIDE GUARDIAN MONITORING</text>
        <text x="18" y="52" fill="${textPrimary}" font-size="12" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Family web tracking active for 3 riders.</text>
        <g id="btn_group_guardian_share" transform="translate(18, 60)">
          <rect width="336" height="28" rx="9" fill="${cyan}" />
          <text x="168" y="19" text-anchor="middle" fill="${isDark ? '#070A0F' : '#FFFFFF'}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Share Guardian Link with Family</text>
        </g>
      </g>

      <!-- Feature Controls -->
      <g transform="translate(20, 206)">
        <text x="0" y="16" fill="${textMuted}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">RIDE FEATURES</text>
        <rect y="26" width="372" height="110" rx="16" fill="${isDark ? '#0A0E17' : '#F8FAFC'}" stroke="${cardStroke}" stroke-width="1" />
        
        <text x="16" y="56" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Route Essentials Radar</text>
        <text x="356" y="56" text-anchor="end" fill="${cyan}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">ON</text>

        <line x1="16" y1="72" x2="356" y2="72" stroke="${cardStroke}" stroke-width="1" />

        <text x="16" y="104" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Convoy Fuel Estimates</text>
        <text x="356" y="104" text-anchor="end" fill="${cyan}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">ON</text>
      </g>

      <!-- Save & Return Button -->
      <g id="btn_save_group" transform="translate(20, 600)">
        <rect width="372" height="52" rx="16" fill="${cyan}" />
        <text x="186" y="32" text-anchor="middle" fill="${isDark ? '#070A0F' : '#FFFFFF'}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">SAVE &amp; RETURN TO COCKPIT</text>
      </g>
    </g>
  </g>
</svg>`;
}

// 7. SCREEN 7: COCKPIT WITH QUICK STOP REASON PICKER OVERLAY
function buildCockpitStopPicker(isDark) {
  const modalBg = isDark ? '#0F172A' : '#FFFFFF';
  const cardStroke = isDark ? '#1E293B' : '#E2E8F0';
  const btnBg = isDark ? '#1E293B' : '#F1F5F9';
  const textPrimary = isDark ? '#FFFFFF' : '#0F172A';
  const textMuted = isDark ? '#94A3B8' : '#64748B';
  const shadowPopup = isDark ? '' : 'filter="url(#shadow-popup-light)"';

  // Tile styles
  const t1Bg = isDark ? '#451A03' : '#FEF3C7';
  const t1Border = isDark ? '#F59E0B' : '#D97706';
  const t1Text = isDark ? '#FEF08A' : '#78350F';

  const t2Bg = isDark ? '#450A0A' : '#FEE2E2';
  const t2Border = isDark ? '#EF4444' : '#DC2626';
  const t2Text = isDark ? '#FECACA' : '#991B1B';

  const t3Bg = isDark ? '#083344' : '#E0F2FE';
  const t3Border = isDark ? '#00E5FF' : '#00838F';
  const t3Text = isDark ? '#E0F2FE' : '#0F172A';

  const t4Bg = isDark ? '#3B0764' : '#F3E8FF';
  const t4Border = isDark ? '#A855F7' : '#7C3AED';
  const t4Text = isDark ? '#F3E8FF' : '#4C1D95';

  return `<svg width="412" height="870" viewBox="0 0 412 870" fill="none" xmlns="http://www.w3.org/2000/svg">
${defs(isDark)}
  <g id="CoRoute_Popup_StopPicker_${isDark ? 'Dark' : 'Light'}" clip-path="url(#screen-clip)">
${renderCockpitBase(isDark, isDark ? 'right' : 'left')}

    <rect id="btn_modal_backdrop" width="412" height="870" fill="#000000" fill-opacity="0.6" />

    <!-- In-Cockpit Stop Reason Modal Overlay -->
    <g id="InCockpit_Stop_Modal" transform="translate(0, 240)">
      <path d="M0 28 C0 12.536 12.536 0 28 0 H384 C399.464 0 412 12.536 412 28 V630 H0 Z" fill="${modalBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowPopup} />
      <rect x="186" y="10" width="40" height="5" rx="2.5" fill="${isDark ? '#334155' : '#CBD5E1'}" />

      <!-- Modal Header -->
      <g transform="translate(20, 24)">
        <text x="0" y="24" fill="${textPrimary}" font-size="18" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">Broadcast Stop Reason</text>
        <text x="0" y="42" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">1-Tap glove announcement to all convoy riders</text>
        <g id="btn_close_popup">
          <rect x="312" y="6" width="60" height="34" rx="12" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
          <text x="342" y="27" text-anchor="middle" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Done</text>
        </g>
        <line x1="0" y1="52" x2="372" y2="52" stroke="${cardStroke}" stroke-width="1" />
      </g>

      <!-- 4 Oversized Stop Reason Tiles -->
      <g transform="translate(20, 92)">
        <!-- 1. Fuel -->
        <g id="btn_stop_fuel">
          <rect width="180" height="130" rx="22" fill="${t1Bg}" stroke="${t1Border}" stroke-width="2" />
          <text x="90" y="64" text-anchor="middle" fill="${t1Text}" font-size="16" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">Fuel Stop</text>
          <text x="90" y="86" text-anchor="middle" fill="${t1Border}" font-size="9" font-weight="800" font-family="JetBrains Mono, monospace">PUMP ARRIVAL</text>
        </g>

        <!-- 2. Mechanical -->
        <g id="btn_stop_mechanical" transform="translate(192, 0)">
          <rect width="180" height="130" rx="22" fill="${t2Bg}" stroke="${t2Border}" stroke-width="2" />
          <text x="90" y="64" text-anchor="middle" fill="${t2Text}" font-size="16" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">Mechanical</text>
          <text x="90" y="86" text-anchor="middle" fill="${t2Border}" font-size="9" font-weight="800" font-family="JetBrains Mono, monospace">BIKE ISSUE</text>
        </g>

        <!-- 3. Rest & Chai -->
        <g id="btn_stop_rest" transform="translate(0, 144)">
          <rect width="180" height="130" rx="22" fill="${t3Bg}" stroke="${t3Border}" stroke-width="2" />
          <text x="90" y="64" text-anchor="middle" fill="${t3Text}" font-size="16" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">Rest &amp; Chai</text>
          <text x="90" y="86" text-anchor="middle" fill="${t3Border}" font-size="9" font-weight="800" font-family="JetBrains Mono, monospace">5-10 MIN BREAK</text>
        </g>

        <!-- 4. Wait / Regroup -->
        <g id="btn_stop_regroup" transform="translate(192, 144)">
          <rect width="180" height="130" rx="22" fill="${t4Bg}" stroke="${t4Border}" stroke-width="2" />
          <text x="90" y="64" text-anchor="middle" fill="${t4Text}" font-size="16" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">Wait / Regroup</text>
          <text x="90" y="86" text-anchor="middle" fill="${t4Border}" font-size="9" font-weight="800" font-family="JetBrains Mono, monospace">HOLD PACK</text>
        </g>
      </g>

      <!-- Clear Stop Button -->
      <g id="btn_clear_stop" transform="translate(20, 540)">
        <rect width="372" height="52" rx="16" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1.5" />
        <text x="186" y="32" text-anchor="middle" fill="${textPrimary}" font-size="12" font-weight="800" font-family="Plus Jakarta Sans, sans-serif" letter-spacing="0.5">CLEAR STOP REASON (RESUME RIDING)</text>
      </g>
    </g>
  </g>
</svg>`;
}

// GENERATE ALL 14 SCREENS (7 Dark + 7 Light)
const files = [
  { file: 'figma_artboard_1_cockpit_idle.svg', content: buildCockpitIdle(true) },
  { file: 'figma_artboard_1_cockpit_idle_light.svg', content: buildCockpitIdle(false) },
  { file: 'figma_artboard_2_cockpit_orbit.svg', content: buildCockpitOrbitOpen(true) },
  { file: 'figma_artboard_2_cockpit_orbit_light.svg', content: buildCockpitOrbitOpen(false) },
  { file: 'figma_artboard_3_popup_quick_settings.svg', content: buildCockpitQuickSettings(true) },
  { file: 'figma_artboard_3_popup_quick_settings_light.svg', content: buildCockpitQuickSettings(false) },
  { file: 'figma_artboard_4_popup_guardian.svg', content: buildCockpitGuardian(true) },
  { file: 'figma_artboard_4_popup_guardian_light.svg', content: buildCockpitGuardian(false) },
  { file: 'figma_artboard_5_popup_fuel.svg', content: buildCockpitFuel(true) },
  { file: 'figma_artboard_5_popup_fuel_light.svg', content: buildCockpitFuel(false) },
  { file: 'figma_artboard_6_popup_group.svg', content: buildCockpitGroupSettings(true) },
  { file: 'figma_artboard_6_popup_group_light.svg', content: buildCockpitGroupSettings(false) },
  { file: 'figma_artboard_7_popup_stop.svg', content: buildCockpitStopPicker(true) },
  { file: 'figma_artboard_7_popup_stop_light.svg', content: buildCockpitStopPicker(false) }
];

files.forEach(f => {
  fs.writeFileSync(path.join(dir, f.file), f.content, 'utf8');
  console.log(`Generated: ${f.file} (${f.content.length} bytes)`);
});

console.log('✅ All 14 In-Cockpit Popup screens generated successfully!');
