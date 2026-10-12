const fs = require('fs');
const path = require('path');

const dir = path.join(__dirname);

// COMMON SVG HELPERS
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
    <filter id="glow-red" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="6" result="blur" />
      <feComposite in="SourceGraphic" in2="blur" operator="over" />
    </filter>
    <filter id="glow-purple" x="-20%" y="-20%" width="140%" height="140%">
      <feGaussianBlur stdDeviation="6" result="blur" />
      <feComposite in="SourceGraphic" in2="blur" operator="over" />
    </filter>
    <clipPath id="screen-clip">
      <rect width="412" height="870" rx="36" fill="#070A0F" />
    </clipPath>
  </defs>`;
  } else {
    return `  <defs>
    <filter id="shadow-card-light" x="-10%" y="-10%" width="120%" height="120%">
      <feDropShadow dx="0" dy="2" stdDeviation="3" flood-color="#64748B" flood-opacity="0.12" />
    </filter>
    <clipPath id="screen-clip">
      <rect width="412" height="870" rx="36" fill="#F8FAFC" />
    </clipPath>
  </defs>`;
  }
}

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

// 1. SCREEN 1: LIVE COCKPIT
function generateCockpit(isDark) {
  const bg = isDark ? '#070A0F' : '#F8FAFC';
  const roadBg = isDark ? '#0A0E17' : '#EFF6FF';
  const roadStroke = isDark ? '#162235' : '#DBEAFE';
  const roadText = isDark ? '#475569' : '#94A3B8';
  const areaText = isDark ? '#334155' : '#CBD5E1';
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
  const subCardBg = isDark ? '#070A0F' : '#F8FAFC';
  const shadowAttr = isDark ? '' : 'filter="url(#shadow-card-light)"';
  const glowCyan = isDark ? 'filter="url(#glow-cyan)"' : '';
  const glowSos = isDark ? 'filter="url(#glow-sos)"' : '';

  return `<svg width="412" height="870" viewBox="0 0 412 870" fill="none" xmlns="http://www.w3.org/2000/svg">
${defs(isDark)}
  <g id="CoRoute_Live_Cockpit_Screen" clip-path="url(#screen-clip)">
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
      <text x="150" y="320" fill="${areaText}" font-size="10" font-weight="600" font-family="Plus Jakarta Sans, sans-serif">ELECTRONICS CITY</text>

      <!-- Active Navigation Guidance Polyline -->
      <path d="M70 660 Q140 540 190 460 T290 320 L330 180" stroke="${cyan}" stroke-width="6" stroke-linecap="round" stroke-linejoin="round" ${glowCyan} />
      <path d="M70 660 Q140 540 190 460 T290 320 L330 180" stroke="#FFFFFF" stroke-width="2" stroke-linecap="round" stroke-dasharray="5 7" opacity="0.9" />

      <!-- Convoy Marker: Sweeper RK -->
      <g id="Marker_Sweeper_RK" transform="translate(68, 656)">
        <circle r="16" fill="${isDark ? '#0F172A' : '#FFFFFF'}" stroke="${isDark ? '#FF9100' : '#BD5B00'}" stroke-width="3" />
        <text y="4" text-anchor="middle" fill="${isDark ? '#FF9100' : '#BD5B00'}" font-size="11" font-weight="700" font-family="JetBrains Mono, monospace">RK</text>
        <rect x="-24" y="20" width="48" height="14" rx="4" fill="${isDark ? '#0F172A' : '#FFFFFF'}" stroke="${isDark ? '#FF9100' : '#BD5B00'}" stroke-width="1" />
        <text y="30" text-anchor="middle" fill="${isDark ? '#FF9100' : '#BD5B00'}" font-size="8" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">SWEEPER</text>
      </g>

      <!-- Convoy Marker: Pack VP -->
      <g id="Marker_Pack_VP" transform="translate(188, 456)">
        <circle r="15" fill="${isDark ? '#0F172A' : '#FFFFFF'}" stroke="${isDark ? '#00E676' : '#16A34A'}" stroke-width="2.5" />
        <text y="4" text-anchor="middle" fill="${isDark ? '#00E676' : '#16A34A'}" font-size="11" font-weight="700" font-family="JetBrains Mono, monospace">VP</text>
        <rect x="-18" y="19" width="36" height="14" rx="4" fill="${isDark ? '#0F172A' : '#FFFFFF'}" stroke="${isDark ? '#00E676' : '#16A34A'}" stroke-width="1" />
        <text y="29" text-anchor="middle" fill="${isDark ? '#00E676' : '#16A34A'}" font-size="8" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">PACK</text>
      </g>

      <!-- Convoy Marker: Lead SB -->
      <g id="Marker_Lead_SB" transform="translate(328, 176)">
        <circle r="22" fill="${isDark ? 'rgba(0,229,255,0.25)' : 'rgba(0,131,143,0.2)'}" />
        <circle r="17" fill="${isDark ? '#0F172A' : '#FFFFFF'}" stroke="${cyan}" stroke-width="3" />
        <text y="4" text-anchor="middle" fill="${cyan}" font-size="12" font-weight="800" font-family="JetBrains Mono, monospace">SB</text>
        <rect x="-20" y="-34" width="40" height="15" rx="4" fill="${cyan}" />
        <text y="-23" text-anchor="middle" fill="${isDark ? '#070A0F' : '#FFFFFF'}" font-size="9" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">LEAD</text>
      </g>
    </g>

${statusBar(isDark)}

    <!-- Top Turn-by-Turn HUD Card -->
    <g id="Top_Guidance_HUD" transform="translate(16, 48)">
      <rect width="380" height="74" rx="24" fill="${hudBg}" stroke="${hudStroke}" stroke-width="1.5" ${shadowAttr} />
      <rect x="14" y="13" width="48" height="48" rx="16" fill="${cyanLight}" stroke="${cyan}" stroke-width="1.2" />
      <path d="M38 24 L38 48 M38 24 L30 32 M38 24 L46 32" stroke="${cyan}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" />
      <text x="74" y="34" fill="${textPrimary}" font-size="14" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">In 800 m <tspan fill="${textMuted}">&#x2022;</tspan> Keep Right</text>
      <text x="74" y="52" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">NH 48 Expressway &#x2022; Toward Hosur</text>
      <line x1="290" y1="12" x2="290" y2="62" stroke="${hudStroke}" stroke-width="1" />
      <text x="332" y="38" text-anchor="middle" fill="${textPrimary}" font-size="28" font-weight="800" font-family="JetBrains Mono, monospace">68</text>
      <text x="364" y="30" fill="${textMuted}" font-size="10" font-weight="700" font-family="JetBrains Mono, monospace">KM/H</text>
      <rect x="298" y="44" width="70" height="18" rx="6" fill="${isDark ? '#064E3B' : '#DCFCE7'}" stroke="${isDark ? '#059669' : '#86EFAC'}" stroke-width="0.8" />
      <text x="333" y="56" text-anchor="middle" fill="${isDark ? '#34D399' : '#15803D'}" font-size="9" font-weight="800" font-family="JetBrains Mono, monospace">LIMIT 80</text>
    </g>

    <!-- Bottom Controls Layer -->
    <g id="Bottom_Cockpit_Controls" transform="translate(0, 680)">
      <!-- Glance Row: SOS + Shortcuts Dock + Recenter -->
      <g id="Dock_Row" transform="translate(16, 0)">
        <!-- 56dp Large Glove SOS Button -->
        <g id="btn_dock_sos">
          <rect width="56" height="56" rx="18" fill="#DC2626" stroke="#EF4444" stroke-width="1.5" ${glowSos} ${shadowAttr} />
          <text x="28" y="28" text-anchor="middle" fill="#FFFFFF" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">SOS</text>
          <text x="28" y="42" text-anchor="middle" fill="#FFFFFF" opacity="0.9" font-size="8" font-weight="700" font-family="JetBrains Mono, monospace">HOLD 3s</text>
        </g>

        <!-- Streamlined Shortcuts Dock Frame (5 Direct Shortcut Targets) -->
        <g id="Shortcuts_Dock" transform="translate(68, 0)">
          <rect width="256" height="56" rx="18" fill="${dockBg}" stroke="${dockStroke}" stroke-width="1.5" ${shadowAttr} />

          <!-- 1. Stop Reason Button -> Links to Screen 6 -->
          <g id="btn_dock_stop" transform="translate(6, 6)">
            <rect width="46" height="44" rx="12" fill="${dockBtnBg}" stroke="${dockBtnBorder}" stroke-width="1" />
            <text x="23" y="26" text-anchor="middle" fill="${isDark ? '#FBBF24' : '#BD5B00'}" font-size="10" font-weight="800" font-family="JetBrains Mono, monospace">STOP</text>
          </g>

          <!-- 2. Ride Guardian Link -> Links to Screen 3 -->
          <g id="btn_dock_guardian" transform="translate(56, 6)">
            <rect width="46" height="44" rx="12" fill="${cyanLight}" stroke="${cyan}" stroke-width="1.4" />
            <text x="23" y="26" text-anchor="middle" fill="${cyan}" font-size="10" font-weight="900" font-family="JetBrains Mono, monospace">LINK</text>
          </g>

          <!-- 3. Fuel Range Radar -> Links to Screen 4 -->
          <g id="btn_dock_fuel" transform="translate(106, 6)">
            <rect width="46" height="44" rx="12" fill="${isDark ? '#451A03' : '#FEF3C7'}" stroke="${isDark ? '#F59E0B' : '#D97706'}" stroke-width="1.2" />
            <text x="23" y="26" text-anchor="middle" fill="${isDark ? '#FCD34D' : '#B45309'}" font-size="10" font-weight="800" font-family="JetBrains Mono, monospace">185k</text>
          </g>

          <!-- 4. Voice Mic Mode Toggle -->
          <g id="btn_dock_mic" transform="translate(156, 6)">
            <rect width="44" height="44" rx="12" fill="${dockBtnBg}" stroke="${dockBtnBorder}" stroke-width="1" />
            <text x="22" y="26" text-anchor="middle" fill="${cyan}" font-size="10" font-weight="800" font-family="JetBrains Mono, monospace">MIC</text>
          </g>

          <!-- 5. Glove Quick Settings Button -> Links to Screen 2 -->
          <g id="btn_dock_settings" transform="translate(204, 6)">
            <rect width="44" height="44" rx="12" fill="${dockBtnBg}" stroke="${cyan}" stroke-width="1.2" />
            <text x="22" y="26" text-anchor="middle" fill="${cyan}" font-size="10" font-weight="900" font-family="JetBrains Mono, monospace">CFG</text>
          </g>
        </g>

        <!-- Recenter Map Button -->
        <g id="btn_dock_recenter" transform="translate(332, 0)">
          <rect width="48" height="56" rx="18" fill="${dockBg}" stroke="${dockStroke}" stroke-width="1.5" ${shadowAttr} />
          <circle cx="24" cy="28" r="8" stroke="${textMuted}" stroke-width="2" />
          <circle cx="24" cy="28" r="3" fill="${cyan}" />
        </g>
      </g>

      <!-- Collapsed Bottom Sheet -->
      <g id="Collapsed_Bottom_Sheet" transform="translate(0, 68)">
        <path d="M0 24 C0 10.745 10.745 0 24 0 H388 C401.255 0 412 10.745 412 24 V130 H0 Z" fill="${sheetBg}" stroke="${sheetStroke}" stroke-width="1.5" ${shadowAttr} />
        <rect x="186" y="8" width="40" height="5" rx="2.5" fill="${isDark ? '#334155' : '#CBD5E1'}" />

        <!-- Convoy Header Row -> Links to Screen 5: Group Settings -->
        <g id="btn_convoy_header">
          <text x="20" y="38" fill="${textPrimary}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Bangalore Highway Convoy</text>
          <rect x="180" y="24" width="60" height="18" rx="9" fill="${cyanLight}" stroke="${cyan}" stroke-width="0.8" />
          <text x="210" y="36" text-anchor="middle" fill="${cyan}" font-size="9" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">3 Riders</text>
          <text x="392" y="38" text-anchor="end" fill="${textMuted}" font-size="11" font-weight="700" font-family="JetBrains Mono, monospace">ETA 14:15 &#x2022; 82 km</text>
        </g>

        <!-- Live Fuel & Guardian Status Strip -> Links to Screen 4: Fuel Radar -->
        <g id="btn_fuel_strip" transform="translate(16, 50)">
          <rect width="380" height="42" rx="14" fill="${subCardBg}" stroke="${sheetStroke}" stroke-width="1" />
          <circle cx="16" cy="21" r="5" fill="${isDark ? '#F59E0B' : '#D97706'}" />
          <text x="28" y="25" fill="${isDark ? '#CBD5E1' : '#334155'}" font-size="11" font-weight="600" font-family="Plus Jakarta Sans, sans-serif">Usable Range: <tspan fill="${textPrimary}" font-weight="800" font-family="JetBrains Mono, monospace">185 km</tspan></text>
          <path d="M260 21 L270 21 M263 17 L267 25" stroke="${cyan}" stroke-width="1.8" stroke-linecap="round" />
          <text x="364" y="25" text-anchor="end" fill="${cyan}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Guardian Active</text>
        </g>
      </g>
    </g>
  </g>
</svg>`;
}

// 2. SCREEN 2: GLOVE QUICK SETTINGS
function generateQuickSettings(isDark) {
  const bg = isDark ? '#0A0E17' : '#F8FAFC';
  const cyan = isDark ? '#00E5FF' : '#00838F';
  const textPrimary = isDark ? '#FFFFFF' : '#0F172A';
  const textMuted = isDark ? '#94A3B8' : '#64748B';
  const cardBg = isDark ? '#0F172A' : '#FFFFFF';
  const cardStroke = isDark ? '#1E293B' : '#E2E8F0';
  const btnBg = isDark ? '#1E293B' : '#F1F5F9';
  const shadowAttr = isDark ? '' : 'filter="url(#shadow-card-light)"';
  const glowCyan = isDark ? 'filter="url(#glow-cyan)"' : '';

  return `<svg width="412" height="870" viewBox="0 0 412 870" fill="none" xmlns="http://www.w3.org/2000/svg">
${defs(isDark)}
  <g id="CoRoute_Glove_Quick_Settings" clip-path="url(#screen-clip)">
    <rect width="412" height="870" fill="${bg}" />
${statusBar(isDark)}

    <!-- Header Frame -->
    <g id="Modal_Header" transform="translate(20, 48)">
      <text x="0" y="24" fill="${textPrimary}" font-size="20" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Glove Quick Settings</text>
      <text x="0" y="44" fill="${textMuted}" font-size="12" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">High-contrast, large touch targets for riding gloves</text>
      <!-- Done Button -> Links to Screen 1 -->
      <g id="btn_close_settings">
        <rect x="312" y="4" width="60" height="36" rx="14" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
        <text x="342" y="26" text-anchor="middle" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Done</text>
      </g>
      <line x1="0" y1="58" x2="372" y2="58" stroke="${cardStroke}" stroke-width="1" />
    </g>

    <!-- Primary In-Flight Hero Actions (Prominent 74dp) -->
    <g id="Primary_InFlight_Actions" transform="translate(20, 126)">
      <!-- Action 1: Ride Guardian Link -> Links to Screen 3 -->
      <g id="btn_hero_guardian" transform="translate(0, 0)">
        <rect width="180" height="80" rx="20" fill="${isDark ? '#083344' : '#E0F2FE'}" stroke="${cyan}" stroke-width="2" ${glowCyan} ${shadowAttr} />
        <rect x="12" y="18" width="44" height="44" rx="14" fill="${isDark ? 'rgba(0,229,255,0.2)' : 'rgba(0,131,143,0.15)'}" />
        <path d="M28 40 L34 34 M30 32 L36 26" stroke="${cyan}" stroke-width="2.5" stroke-linecap="round" />
        <text x="64" y="38" fill="${textPrimary}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Guardian Link</text>
        <text x="64" y="54" fill="${cyan}" font-size="10" font-weight="600" font-family="Plus Jakarta Sans, sans-serif">Share live track</text>
      </g>

      <!-- Action 2: Fuel / Range Sheet -> Links to Screen 4 -->
      <g id="btn_hero_fuel" transform="translate(192, 0)">
        <rect width="180" height="80" rx="20" fill="${isDark ? '#451A03' : '#FEF3C7'}" stroke="${isDark ? '#F59E0B' : '#D97706'}" stroke-width="2" ${shadowAttr} />
        <rect x="12" y="18" width="44" height="44" rx="14" fill="${isDark ? 'rgba(245,158,11,0.2)' : 'rgba(217,119,6,0.15)'}" />
        <path d="M30 46 V30 H38 V46 M42 34 H44 V40 H42" stroke="${isDark ? '#F59E0B' : '#D97706'}" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" />
        <text x="64" y="38" fill="${textPrimary}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Fuel / Range</text>
        <text x="64" y="54" fill="${isDark ? '#FCD34D' : '#B45309'}" font-size="10" font-weight="600" font-family="JetBrains Mono, monospace">185 km usable</text>
      </g>
    </g>

    <!-- 2x3 Glove Settings Grid -->
    <g id="Glove_Settings_Grid" transform="translate(20, 226)">
      <!-- Row 1: Voice Alerts & Speed Warning -->
      <g id="Tile_Voice_Alerts" transform="translate(0, 0)">
        <rect width="180" height="150" rx="20" fill="${cardBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowAttr} />
        <text x="14" y="30" fill="${textPrimary}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Voice Alerts</text>
        <circle cx="164" cy="24" r="5" fill="${cyan}" ${glowCyan} />
        <text x="14" y="60" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">All turn cues and</text>
        <text x="14" y="76" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">convoy distance cues</text>
        <rect x="14" y="96" width="152" height="40" rx="12" fill="${isDark ? '#083344' : '#E0F2FE'}" stroke="${cyan}" stroke-width="1" />
        <text x="90" y="121" text-anchor="middle" fill="${cyan}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">ALL ALERTS</text>
      </g>

      <g id="Tile_Speed_Warning" transform="translate(192, 0)">
        <rect width="180" height="150" rx="20" fill="${cardBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowAttr} />
        <text x="14" y="30" fill="${textPrimary}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Speed Warning</text>
        <circle cx="164" cy="24" r="5" fill="${cyan}" ${glowCyan} />
        <text x="14" y="60" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Audible alert at</text>
        <text x="14" y="76" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">speed limit + 5 km/h</text>
        <rect x="14" y="96" width="152" height="40" rx="12" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
        <text x="90" y="121" text-anchor="middle" fill="${cyan}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">80 KM/H</text>
      </g>

      <!-- Row 2: Essentials & Intercom VOX -->
      <g id="Tile_Essentials" transform="translate(0, 164)">
        <rect width="180" height="150" rx="20" fill="${cardBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowAttr} />
        <text x="14" y="30" fill="${textPrimary}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Route Essentials</text>
        <circle cx="164" cy="24" r="5" fill="${isDark ? '#00E676' : '#16A34A'}" />
        <text x="14" y="60" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Highway pumps &amp;</text>
        <text x="14" y="76" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">emergency clinic POIs</text>
        <rect x="14" y="96" width="152" height="40" rx="12" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
        <text x="90" y="121" text-anchor="middle" fill="${isDark ? '#34D399' : '#15803D'}" font-size="10" font-weight="800" font-family="JetBrains Mono, monospace">ACTIVE ON MAP</text>
      </g>

      <g id="Tile_Intercom_VOX" transform="translate(192, 164)">
        <rect width="180" height="150" rx="20" fill="${cardBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowAttr} />
        <text x="14" y="30" fill="${textPrimary}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Intercom VOX</text>
        <circle cx="164" cy="24" r="5" fill="${textMuted}" />
        <text x="14" y="60" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Voice-activated</text>
        <text x="14" y="76" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">helmet microphone</text>
        <rect x="14" y="96" width="152" height="40" rx="12" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
        <text x="90" y="121" text-anchor="middle" fill="${textMuted}" font-size="10" font-weight="800" font-family="JetBrains Mono, monospace">STANDBY (MUTE)</text>
      </g>

      <!-- Row 3: Regroup Cues & Screen Awake -->
      <g id="Tile_Regroup" transform="translate(0, 328)">
        <rect width="180" height="150" rx="20" fill="${cardBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowAttr} />
        <text x="14" y="30" fill="${textPrimary}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Convoy Regroup</text>
        <circle cx="164" cy="24" r="5" fill="${cyan}" ${glowCyan} />
        <text x="14" y="60" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Audible cue when</text>
        <text x="14" y="76" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">pack gap &gt; 1.5 km</text>
        <rect x="14" y="96" width="152" height="40" rx="12" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
        <text x="90" y="121" text-anchor="middle" fill="${cyan}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">1,500 METERS</text>
      </g>

      <g id="Tile_Screen_Awake" transform="translate(192, 328)">
        <rect width="180" height="150" rx="20" fill="${cardBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowAttr} />
        <text x="14" y="30" fill="${textPrimary}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Keep Screen On</text>
        <circle cx="164" cy="24" r="5" fill="${cyan}" ${glowCyan} />
        <text x="14" y="60" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Locks display awake</text>
        <text x="14" y="76" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">for handlebar mounts</text>
        <rect x="14" y="96" width="152" height="40" rx="12" fill="${isDark ? '#083344' : '#E0F2FE'}" stroke="${cyan}" stroke-width="1" />
        <text x="90" y="121" text-anchor="middle" fill="${cyan}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">LOCKED AWAKE</text>
      </g>
    </g>

    <!-- Bottom Full Settings Link -> Links to Screen 5: Group Settings -->
    <g id="btn_open_group_settings" transform="translate(20, 780)">
      <rect width="372" height="52" rx="16" fill="${cardBg}" stroke="${cyan}" stroke-width="1.5" ${shadowAttr} />
      <text x="186" y="32" text-anchor="middle" fill="${cyan}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Open Full Group Settings Sheet &#x2192;</text>
    </g>
  </g>
</svg>`;
}

// 3. SCREEN 3: RIDE GUARDIAN LINK
function generateGuardian(isDark) {
  const bg = isDark ? '#0A0E17' : '#F8FAFC';
  const cyan = isDark ? '#00E5FF' : '#00838F';
  const cyanLight = isDark ? '#083344' : '#E0F2FE';
  const textPrimary = isDark ? '#FFFFFF' : '#0F172A';
  const textMuted = isDark ? '#94A3B8' : '#64748B';
  const cardBg = isDark ? '#0F172A' : '#FFFFFF';
  const cardStroke = isDark ? '#1E293B' : '#E2E8F0';
  const subBg = isDark ? '#070A0F' : '#F1F5F9';
  const btnBg = isDark ? '#1E293B' : '#F1F5F9';
  const shadowAttr = isDark ? '' : 'filter="url(#shadow-card-light)"';
  const glowCyan = isDark ? 'filter="url(#glow-cyan)"' : '';

  return `<svg width="412" height="870" viewBox="0 0 412 870" fill="none" xmlns="http://www.w3.org/2000/svg">
${defs(isDark)}
  <g id="CoRoute_Ride_Guardian_Link" clip-path="url(#screen-clip)">
    <rect width="412" height="870" fill="${bg}" />
${statusBar(isDark)}

    <!-- Header Frame -->
    <g id="Modal_Header" transform="translate(20, 48)">
      <circle cx="10" cy="18" r="5" fill="${cyan}" ${glowCyan} />
      <text x="24" y="24" fill="${textPrimary}" font-size="20" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Ride Guardian Link</text>
      <text x="24" y="44" fill="${textMuted}" font-size="12" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Live convoy tracking for family &amp; monitors</text>
      <!-- Done Button -> Links to Screen 1 -->
      <g id="btn_close_guardian">
        <rect x="312" y="4" width="60" height="36" rx="14" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
        <text x="342" y="26" text-anchor="middle" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Done</text>
      </g>
      <line x1="0" y1="58" x2="372" y2="58" stroke="${cardStroke}" stroke-width="1" />
    </g>

    <!-- Zero-App-Install Security Card -->
    <g id="Security_Info_Card" transform="translate(20, 126)">
      <rect width="372" height="136" rx="24" fill="${cyanLight}" fill-opacity="${isDark ? '0.5' : '1'}" stroke="${cyan}" stroke-width="1.5" ${glowCyan} ${shadowAttr} />
      <text x="18" y="32" fill="${cyan}" font-size="12" font-weight="800" font-family="Plus Jakarta Sans, sans-serif" letter-spacing="1">ZERO APP INSTALL REQUIRED</text>
      <rect x="290" y="16" width="66" height="20" rx="10" fill="${isDark ? '#0E7490' : '#0284C7'}" />
      <text x="323" y="30" text-anchor="middle" fill="#FFFFFF" font-size="9" font-weight="800" font-family="JetBrains Mono, monospace">WEB LIVE</text>
      
      <text x="18" y="60" fill="${textPrimary}" font-size="12" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Family members and club marshals can watch your</text>
      <text x="18" y="78" fill="${textPrimary}" font-size="12" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">convoy progress in real time in any browser.</text>

      <line x1="18" y1="94" x2="354" y2="94" stroke="${cardStroke}" stroke-width="1" />
      <text x="18" y="116" fill="${cyan}" font-size="11" font-weight="700" font-family="JetBrains Mono, monospace">&#x2714; Read-Only</text>
      <text x="144" y="116" fill="${cyan}" font-size="11" font-weight="700" font-family="JetBrains Mono, monospace">&#x2714; 24h Expiry</text>
      <text x="260" y="116" fill="${cyan}" font-size="11" font-weight="700" font-family="JetBrains Mono, monospace">&#x2714; End-to-End</text>
    </g>

    <!-- Shareable Link Card -->
    <g id="Shareable_Link_Box" transform="translate(20, 282)">
      <rect width="372" height="154" rx="24" fill="${cardBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowAttr} />
      <text x="18" y="30" fill="${textMuted}" font-size="12" font-weight="800" font-family="Plus Jakarta Sans, sans-serif" letter-spacing="0.5">SHAREABLE WEB LINK</text>
      
      <rect x="18" y="44" width="336" height="42" rx="14" fill="${subBg}" stroke="${cardStroke}" stroke-width="1" />
      <text x="30" y="70" fill="${cyan}" font-size="11" font-weight="600" font-family="JetBrains Mono, monospace">https://coroute.duckdns.org/watch/gd_9b3f7a18c2</text>

      <!-- Action Buttons -->
      <g id="btn_copy_link" transform="translate(18, 98)">
        <rect width="162" height="42" rx="14" fill="${cyan}" />
        <text x="81" y="26" text-anchor="middle" fill="${isDark ? '#070A0F' : '#FFFFFF'}" font-size="12" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Copy Link</text>
      </g>
      <g id="btn_share_family" transform="translate(192, 98)">
        <rect width="162" height="42" rx="14" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
        <text x="81" y="26" text-anchor="middle" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Share with Family</text>
      </g>
    </g>

    <!-- Connected Observers Card -->
    <g id="Connected_Observers_Card" transform="translate(20, 456)">
      <rect width="372" height="136" rx="24" fill="${cardBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowAttr} />
      <text x="18" y="30" fill="${textMuted}" font-size="12" font-weight="800" font-family="Plus Jakarta Sans, sans-serif" letter-spacing="0.5">CONNECTED OBSERVERS</text>
      <text x="354" y="30" text-anchor="end" fill="${isDark ? '#00E676' : '#16A34A'}" font-size="11" font-weight="700" font-family="JetBrains Mono, monospace">1 Active Now</text>

      <rect x="18" y="44" width="336" height="48" rx="16" fill="${subBg}" stroke="${cardStroke}" stroke-width="1" />
      <circle cx="36" cy="68" r="5" fill="${isDark ? '#00E676' : '#16A34A'}" />
      <text x="50" y="62" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Mom &amp; Family (Home)</text>
      <text x="50" y="78" fill="${textMuted}" font-size="10" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Viewing via Mobile Chrome</text>
      <text x="338" y="72" text-anchor="end" fill="${cyan}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">LIVE</text>

      <text x="18" y="118" fill="${textMuted}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Created by Convoy Lead SB</text>
      <text x="354" y="118" text-anchor="end" fill="${isDark ? '#F59E0B' : '#D97706'}" font-size="11" font-weight="700" font-family="JetBrains Mono, monospace">Expires in 22h 15m</text>
    </g>

    <!-- Revoke All Button -->
    <g id="btn_revoke_links" transform="translate(20, 780)">
      <rect width="372" height="52" rx="16" fill="${isDark ? '#450A0A' : '#FEE2E2'}" stroke="#DC2626" stroke-width="1.2" ${shadowAttr} />
      <text x="186" y="32" text-anchor="middle" fill="#DC2626" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Revoke All Active Guardian Links</text>
    </g>
  </g>
</svg>`;
}

// 4. SCREEN 4: FUEL ESTIMATION & RANGE RADAR
function generateFuel(isDark) {
  const bg = isDark ? '#0A0E17' : '#F8FAFC';
  const cyan = isDark ? '#00E5FF' : '#00838F';
  const amber = isDark ? '#F59E0B' : '#BD5B00';
  const amberBg = isDark ? '#451A03' : '#FEF3C7';
  const textPrimary = isDark ? '#FFFFFF' : '#0F172A';
  const textMuted = isDark ? '#94A3B8' : '#64748B';
  const cardBg = isDark ? '#0F172A' : '#FFFFFF';
  const cardStroke = isDark ? '#1E293B' : '#E2E8F0';
  const subBg = isDark ? '#070A0F' : '#F1F5F9';
  const btnBg = isDark ? '#1E293B' : '#F1F5F9';
  const shadowAttr = isDark ? '' : 'filter="url(#shadow-card-light)"';
  const glowAmber = isDark ? 'filter="url(#glow-amber)"' : '';

  return `<svg width="412" height="870" viewBox="0 0 412 870" fill="none" xmlns="http://www.w3.org/2000/svg">
${defs(isDark)}
  <g id="CoRoute_Fuel_Range_Radar" clip-path="url(#screen-clip)">
    <rect width="412" height="870" fill="${bg}" />
${statusBar(isDark)}

    <!-- Header Frame -->
    <g id="Modal_Header" transform="translate(20, 48)">
      <text x="0" y="24" fill="${textPrimary}" font-size="20" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Fuel Estimation &amp; Radar</text>
      <text x="0" y="44" fill="${textMuted}" font-size="12" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Convoy tank ranges &amp; highway station radar</text>
      <!-- Done Button -> Links to Screen 1 -->
      <g id="btn_close_fuel">
        <rect x="312" y="4" width="60" height="36" rx="14" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
        <text x="342" y="26" text-anchor="middle" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Done</text>
      </g>
      <line x1="0" y1="58" x2="372" y2="58" stroke="${cardStroke}" stroke-width="1" />
    </g>

    <!-- Usable Range Hero Card -->
    <g id="Hero_Range_Card" transform="translate(20, 126)">
      <rect width="372" height="136" rx="24" fill="${amberBg}" fill-opacity="${isDark ? '0.4' : '1'}" stroke="${amber}" stroke-width="1.5" ${glowAmber} ${shadowAttr} />
      
      <text x="20" y="32" fill="${amber}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif" letter-spacing="1">YOUR USABLE RANGE</text>
      <text x="20" y="78" fill="${textPrimary}" font-size="42" font-weight="900" font-family="JetBrains Mono, monospace">185</text>
      <text x="110" y="74" fill="${textMuted}" font-size="14" font-weight="700" font-family="JetBrains Mono, monospace">KM</text>
      
      <text x="20" y="106" fill="${isDark ? '#34D399' : '#15803D'}" font-size="11" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">&#x2714; Destination Reachable (82 km remaining)</text>

      <g id="Tank_Gauge" transform="translate(276, 24)">
        <circle cx="44" cy="44" r="36" fill="none" stroke="${cardStroke}" stroke-width="8" />
        <circle cx="44" cy="44" r="36" fill="none" stroke="${amber}" stroke-width="8" stroke-dasharray="146 80" stroke-linecap="round" transform="rotate(-90 44 44)" />
        <text x="44" y="44" text-anchor="middle" fill="${textPrimary}" font-size="15" font-weight="800" font-family="JetBrains Mono, monospace">65%</text>
        <text x="44" y="58" text-anchor="middle" fill="${amber}" font-size="8" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">TANK</text>
      </g>
    </g>

    <!-- Convoy Member Fuel Ranges Card -->
    <g id="Convoy_Ranges_Card" transform="translate(20, 282)">
      <rect width="372" height="236" rx="24" fill="${cardBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowAttr} />
      <text x="20" y="30" fill="${textMuted}" font-size="12" font-weight="800" font-family="Plus Jakarta Sans, sans-serif" letter-spacing="0.5">CONVOY FUEL RANGES</text>
      <text x="352" y="30" text-anchor="end" fill="${textMuted}" font-size="10" font-weight="700" font-family="JetBrains Mono, monospace">UPDATED LIVE</text>

      <!-- Member 1: Lead SB -->
      <g transform="translate(16, 44)">
        <rect width="340" height="52" rx="16" fill="${subBg}" stroke="${cardStroke}" stroke-width="1" />
        <rect x="12" y="12" width="28" height="28" rx="8" fill="${isDark ? 'rgba(0,229,255,0.15)' : '#E0F2FE'}" />
        <text x="26" y="30" text-anchor="middle" fill="${cyan}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">SB</text>
        <text x="50" y="26" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Lead SB (KTM 390 Adv)</text>
        <text x="50" y="42" fill="${textMuted}" font-size="10" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">14.5L Tank &#x2022; 32 km/L avg</text>
        <text x="326" y="32" text-anchor="end" fill="${isDark ? '#34D399' : '#15803D'}" font-size="13" font-weight="800" font-family="JetBrains Mono, monospace">185 km</text>
      </g>

      <!-- Member 2: Pack VP -->
      <g transform="translate(16, 104)">
        <rect width="340" height="52" rx="16" fill="${subBg}" stroke="${cardStroke}" stroke-width="1" />
        <rect x="12" y="12" width="28" height="28" rx="8" fill="${btnBg}" />
        <text x="26" y="30" text-anchor="middle" fill="${textMuted}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">VP</text>
        <text x="50" y="26" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Rider VP (Himalayan 450)</text>
        <text x="50" y="42" fill="${textMuted}" font-size="10" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">17L Tank &#x2022; 30 km/L avg</text>
        <text x="326" y="32" text-anchor="end" fill="${isDark ? '#34D399' : '#15803D'}" font-size="13" font-weight="800" font-family="JetBrains Mono, monospace">210 km</text>
      </g>

      <!-- Member 3: Sweeper RK (WARNING DEFICIT) -->
      <g transform="translate(16, 164)">
        <rect width="340" height="56" rx="16" fill="${amberBg}" fill-opacity="${isDark ? '0.3' : '0.8'}" stroke="${amber}" stroke-width="1.2" />
        <rect x="12" y="14" width="28" height="28" rx="8" fill="${amberBg}" />
        <text x="26" y="32" text-anchor="middle" fill="${amber}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">RK</text>
        <text x="50" y="26" fill="${isDark ? '#FEF08A' : '#78350F'}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Sweeper RK (Interceptor 650)</text>
        <text x="50" y="44" fill="${amber}" font-size="10" font-weight="600" font-family="Plus Jakarta Sans, sans-serif">Low Fuel: Needs pump before km 64</text>
        <text x="326" y="34" text-anchor="end" fill="${amber}" font-size="13" font-weight="900" font-family="JetBrains Mono, monospace">64 km &#x26A0;</text>
      </g>
    </g>

    <!-- Nearest Verified Pump Card -->
    <g id="Nearest_Pump_Card" transform="translate(20, 538)">
      <rect width="372" height="98" rx="24" fill="${cardBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowAttr} />
      <text x="20" y="26" fill="${textMuted}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif" letter-spacing="0.5">NEAREST VERIFIED PUMP ON ROUTE</text>
      <rect x="290" y="12" width="66" height="20" rx="10" fill="${isDark ? '#083344' : '#E0F2FE'}" />
      <text x="323" y="26" text-anchor="middle" fill="${cyan}" font-size="9" font-weight="800" font-family="JetBrains Mono, monospace">24/7 OPEN</text>

      <g transform="translate(16, 38)">
        <rect width="340" height="48" rx="14" fill="${subBg}" stroke="${cardStroke}" stroke-width="1" />
        <text x="14" y="22" fill="${textPrimary}" font-size="12" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Indian Oil Swagat COCO NH48</text>
        <text x="14" y="38" fill="${textMuted}" font-size="10" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">4.2 km ahead &#x2022; Left service lane &#x2022; Restrooms &amp; Air</text>
        <g id="btn_stop_here">
          <rect x="256" y="8" width="72" height="32" rx="10" fill="${cyan}" />
          <text x="292" y="28" text-anchor="middle" fill="${isDark ? '#070A0F' : '#FFFFFF'}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Stop Here</text>
        </g>
      </g>
    </g>

    <!-- Broadcast Refuel Stop Button -> Links to Screen 1 -->
    <g id="btn_broadcast_refuel" transform="translate(20, 780)">
      <rect width="372" height="52" rx="16" fill="${amber}" ${glowAmber} ${shadowAttr} />
      <text x="186" y="32" text-anchor="middle" fill="${isDark ? '#070A0F' : '#FFFFFF'}" font-size="13" font-weight="900" font-family="Plus Jakarta Sans, sans-serif" letter-spacing="0.5">BROADCAST REFUEL STOP TO CONVOY</text>
    </g>
  </g>
</svg>`;
}

// 5. SCREEN 5: REDESIGNED GROUP SETTINGS
function generateGroupSettings(isDark) {
  const bg = isDark ? '#0A0E17' : '#F8FAFC';
  const cyan = isDark ? '#00E5FF' : '#00838F';
  const cyanLight = isDark ? '#083344' : '#E0F2FE';
  const amber = isDark ? '#F59E0B' : '#BD5B00';
  const textPrimary = isDark ? '#FFFFFF' : '#0F172A';
  const textMuted = isDark ? '#94A3B8' : '#64748B';
  const cardBg = isDark ? '#0F172A' : '#FFFFFF';
  const cardStroke = isDark ? '#1E293B' : '#E2E8F0';
  const subBg = isDark ? '#070A0F' : '#F1F5F9';
  const btnBg = isDark ? '#1E293B' : '#F1F5F9';
  const shadowAttr = isDark ? '' : 'filter="url(#shadow-card-light)"';
  const glowCyan = isDark ? 'filter="url(#glow-cyan)"' : '';

  return `<svg width="412" height="870" viewBox="0 0 412 870" fill="none" xmlns="http://www.w3.org/2000/svg">
${defs(isDark)}
  <g id="CoRoute_Group_Settings" clip-path="url(#screen-clip)">
    <rect width="412" height="870" fill="${bg}" />
${statusBar(isDark)}

    <!-- Header Frame -->
    <g id="Modal_Header" transform="translate(20, 48)">
      <text x="0" y="24" fill="${textPrimary}" font-size="20" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Group Settings</text>
      <text x="0" y="44" fill="${textMuted}" font-size="12" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Bangalore Highway Convoy &#x2022; Lead Controls</text>
      <!-- Done Button -> Links to Screen 1 -->
      <g id="btn_close_group">
        <rect x="312" y="4" width="60" height="36" rx="14" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
        <text x="342" y="26" text-anchor="middle" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Done</text>
      </g>
      <line x1="0" y1="58" x2="372" y2="58" stroke="${cardStroke}" stroke-width="1" />
    </g>

    <!-- 1. Top Ride Guardian Hero Card -->
    <g id="Hero_Guardian_Monitoring_Card" transform="translate(20, 126)">
      <rect width="372" height="132" rx="24" fill="${cyanLight}" fill-opacity="${isDark ? '0.6' : '1'}" stroke="${cyan}" stroke-width="1.5" ${glowCyan} ${shadowAttr} />
      
      <circle cx="24" cy="28" r="5" fill="${cyan}" />
      <text x="38" y="32" fill="${textPrimary}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Ride Guardian Monitoring</text>
      <rect x="290" y="18" width="66" height="20" rx="10" fill="${isDark ? '#0E7490' : '#0284C7'}" />
      <text x="323" y="32" text-anchor="middle" fill="#FFFFFF" font-size="9" font-weight="800" font-family="JetBrains Mono, monospace">ACTIVE</text>

      <text x="24" y="60" fill="${textPrimary}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Allow family members or ride marshals to track live convoy</text>
      <text x="24" y="76" fill="${textPrimary}" font-size="11" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">progress without downloading the app.</text>

      <!-- Share Button -> Links to Screen 3: Guardian Link -->
      <g id="btn_group_guardian_share">
        <rect x="24" y="88" width="324" height="34" rx="12" fill="${isDark ? 'rgba(0,229,255,0.2)' : '#FFFFFF'}" stroke="${cyan}" stroke-width="1" />
        <!-- Pure SVG Link Chain Icon (ZERO RAW EMOJIS) -->
        <path d="M72 105 L78 99 M75 97 L81 91" stroke="${cyan}" stroke-width="2" stroke-linecap="round" />
        <text x="186" y="110" text-anchor="middle" fill="${cyan}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Share Guardian Link with Family</text>
      </g>
    </g>

    <!-- 2. Ride Feature Controls -->
    <g id="Section_Feature_Controls" transform="translate(20, 276)">
      <text x="4" y="16" fill="${textMuted}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif" letter-spacing="1">RIDE FEATURE CONTROLS</text>
      <rect y="26" width="372" height="152" rx="20" fill="${cardBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowAttr} />
      
      <!-- Row 1: Route Essentials -->
      <text x="18" y="58" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Route Essentials</text>
      <text x="18" y="74" fill="${textMuted}" font-size="10" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Verified fuel pumps &amp; emergency POIs</text>
      <text x="354" y="66" text-anchor="end" fill="${cyan}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">ON</text>
      <line x1="18" y1="84" x2="354" y2="84" stroke="${cardStroke}" stroke-width="1" />

      <!-- Row 2: Group Fuel Estimates -->
      <text x="18" y="106" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Group Fuel Estimates</text>
      <text x="18" y="122" fill="${textMuted}" font-size="10" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">Share remaining range &amp; low-fuel radar</text>
      <text x="354" y="114" text-anchor="end" fill="${cyan}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">ON</text>
      <line x1="18" y1="132" x2="354" y2="132" stroke="${cardStroke}" stroke-width="1" />

      <!-- Row 3: Allow Guardian Links -->
      <text x="18" y="154" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Allow Ride Guardian Links</text>
      <text x="354" y="156" text-anchor="end" fill="${cyan}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">ON</text>
    </g>

    <!-- 3. Convoy Safety Limits -->
    <g id="Section_Safety_Limits" transform="translate(20, 472)">
      <text x="4" y="16" fill="${textMuted}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif" letter-spacing="1">CONVOY SAFETY LIMITS</text>
      <rect y="26" width="372" height="142" rx="20" fill="${cardBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowAttr} />

      <!-- Separation Alert Slider -->
      <text x="18" y="58" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Separation distance alert</text>
      <text x="354" y="58" text-anchor="end" fill="${cyan}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">1,500 m</text>
      <rect x="18" y="70" width="336" height="8" rx="4" fill="${subBg}" />
      <rect x="18" y="70" width="224" height="8" rx="4" fill="${cyan}" />
      <circle cx="242" cy="74" r="8" fill="${cyan}" stroke="${cardBg}" stroke-width="2" />

      <!-- Speed Cap Slider -->
      <text x="18" y="114" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Speed warning cap</text>
      <text x="354" y="114" text-anchor="end" fill="${amber}" font-size="11" font-weight="800" font-family="JetBrains Mono, monospace">85 km/h</text>
      <rect x="18" y="126" width="336" height="8" rx="4" fill="${subBg}" />
      <rect x="18" y="126" width="250" height="8" rx="4" fill="${amber}" />
      <circle cx="268" cy="130" r="8" fill="${amber}" stroke="${cardBg}" stroke-width="2" />
    </g>

    <!-- 4. Group Visibility -->
    <g id="Section_Visibility" transform="translate(20, 656)">
      <text x="4" y="16" fill="${textMuted}" font-size="11" font-weight="800" font-family="Plus Jakarta Sans, sans-serif" letter-spacing="1">GROUP VISIBILITY</text>
      <rect y="26" width="372" height="64" rx="20" fill="${cardBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowAttr} />
      <text x="18" y="62" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Convoy Visibility</text>
      
      <rect x="228" y="42" width="128" height="32" rx="12" fill="${subBg}" stroke="${cardStroke}" stroke-width="1" />
      <rect x="230" y="44" width="62" height="28" rx="10" fill="${cyan}" />
      <text x="261" y="62" text-anchor="middle" fill="${isDark ? '#070A0F' : '#FFFFFF'}" font-size="10" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">PUBLIC</text>
      <text x="323" y="62" text-anchor="middle" fill="${textMuted}" font-size="10" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">PRIVATE</text>
    </g>

    <!-- Save & Return Action Button -> Links to Screen 1 -->
    <g id="btn_save_group" transform="translate(20, 780)">
      <rect width="372" height="52" rx="16" fill="${cyan}" ${glowCyan} ${shadowAttr} />
      <text x="186" y="32" text-anchor="middle" fill="${isDark ? '#070A0F' : '#FFFFFF'}" font-size="13" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">SAVE &amp; RETURN TO COCKPIT</text>
    </g>
  </g>
</svg>`;
}

// 6. SCREEN 6: QUICK STOP REASON PICKER
function generateStopPicker(isDark) {
  const bg = isDark ? '#0A0E17' : '#F8FAFC';
  const cyan = isDark ? '#00E5FF' : '#00838F';
  const textPrimary = isDark ? '#FFFFFF' : '#0F172A';
  const textMuted = isDark ? '#94A3B8' : '#64748B';
  const btnBg = isDark ? '#1E293B' : '#F1F5F9';
  const cardStroke = isDark ? '#1E293B' : '#E2E8F0';
  const shadowAttr = isDark ? '' : 'filter="url(#shadow-card-light)"';

  // Tile 1: Fuel (Amber)
  const t1Bg = isDark ? '#451A03' : '#FEF3C7';
  const t1Border = isDark ? '#F59E0B' : '#D97706';
  const t1Text = isDark ? '#FEF08A' : '#78350F';
  const t1Badge = isDark ? '#FBBF24' : '#B45309';

  // Tile 2: Mechanical (Red)
  const t2Bg = isDark ? '#450A0A' : '#FEE2E2';
  const t2Border = isDark ? '#EF4444' : '#DC2626';
  const t2Text = isDark ? '#FECACA' : '#991B1B';
  const t2Badge = isDark ? '#F87171' : '#B91C1C';

  // Tile 3: Rest & Chai (Cyan)
  const t3Bg = isDark ? '#083344' : '#E0F2FE';
  const t3Border = isDark ? '#00E5FF' : '#00838F';
  const t3Text = isDark ? '#E0F2FE' : '#0F172A';
  const t3Badge = isDark ? '#38BDF8' : '#0369A1';

  // Tile 4: Wait & Regroup (Purple)
  const t4Bg = isDark ? '#3B0764' : '#F3E8FF';
  const t4Border = isDark ? '#A855F7' : '#7C3AED';
  const t4Text = isDark ? '#F3E8FF' : '#4C1D95';
  const t4Badge = isDark ? '#C084FC' : '#6D28D9';

  return `<svg width="412" height="870" viewBox="0 0 412 870" fill="none" xmlns="http://www.w3.org/2000/svg">
${defs(isDark)}
  <g id="CoRoute_Quick_Stop_Picker" clip-path="url(#screen-clip)">
    <rect width="412" height="870" fill="${bg}" />
${statusBar(isDark)}

    <!-- Header Frame -->
    <g id="Modal_Header" transform="translate(20, 48)">
      <text x="0" y="24" fill="${textPrimary}" font-size="20" font-weight="800" font-family="Plus Jakarta Sans, sans-serif">Broadcast Stop Reason</text>
      <text x="0" y="44" fill="${textMuted}" font-size="12" font-weight="500" font-family="Plus Jakarta Sans, sans-serif">1-Tap glove announcement to all convoy riders</text>
      <!-- Done Button -> Links to Screen 1 -->
      <g id="btn_close_stop">
        <rect x="312" y="4" width="60" height="36" rx="14" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1" />
        <text x="342" y="26" text-anchor="middle" fill="${textPrimary}" font-size="12" font-weight="700" font-family="Plus Jakarta Sans, sans-serif">Done</text>
      </g>
      <line x1="0" y1="58" x2="372" y2="58" stroke="${cardStroke}" stroke-width="1" />
    </g>

    <!-- 4 Oversized Glove Action Tiles (180x200dp) -->
    <g id="Oversized_Stop_Grid" transform="translate(20, 160)">
      <!-- 1. Fuel Stop -> Links to Screen 1 -->
      <g id="btn_stop_fuel" transform="translate(0, 0)">
        <rect width="180" height="200" rx="32" fill="${t1Bg}" fill-opacity="${isDark ? '0.5' : '1'}" stroke="${t1Border}" stroke-width="2" ${shadowAttr} />
        <g transform="translate(70, 40)">
          <path d="M4 36 V6 H24 V36 M30 14 H34 V26 H30" stroke="${t1Border}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" />
          <line x1="8" y1="12" x2="20" y2="12" stroke="${t1Border}" stroke-width="2" />
        </g>
        <text x="90" y="126" text-anchor="middle" fill="${t1Text}" font-size="16" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">Fuel Stop</text>
        <rect x="32" y="144" width="116" height="24" rx="12" fill="${t1Bg}" stroke="${t1Border}" stroke-width="1" />
        <text x="90" y="160" text-anchor="middle" fill="${t1Badge}" font-size="9" font-weight="800" font-family="JetBrains Mono, monospace">PUMP ARRIVAL</text>
      </g>

      <!-- 2. Mechanical Issue -> Links to Screen 1 -->
      <g id="btn_stop_mechanical" transform="translate(192, 0)">
        <rect width="180" height="200" rx="32" fill="${t2Bg}" fill-opacity="${isDark ? '0.5' : '1'}" stroke="${t2Border}" stroke-width="2" ${shadowAttr} />
        <g transform="translate(70, 40)">
          <path d="M26 10 L30 14 L14 30 L10 26 Z M26 10 C24 8 20 8 18 10 L22 14 Z" stroke="${t2Border}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" />
        </g>
        <text x="90" y="126" text-anchor="middle" fill="${t2Text}" font-size="16" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">Mechanical</text>
        <rect x="32" y="144" width="116" height="24" rx="12" fill="${t2Bg}" stroke="${t2Border}" stroke-width="1" />
        <text x="90" y="160" text-anchor="middle" fill="${t2Badge}" font-size="9" font-weight="800" font-family="JetBrains Mono, monospace">BIKE ISSUE</text>
      </g>

      <!-- 3. Rest & Chai -> Links to Screen 1 -->
      <g id="btn_stop_rest" transform="translate(0, 220)">
        <rect width="180" height="200" rx="32" fill="${t3Bg}" fill-opacity="${isDark ? '0.5' : '1'}" stroke="${t3Border}" stroke-width="2" ${shadowAttr} />
        <g transform="translate(68, 40)">
          <path d="M4 14 H32 V26 C32 32 26 36 18 36 C10 36 4 32 4 26 Z M32 18 H38 C40 18 42 20 42 22 C42 24 40 26 38 26 H32" stroke="${t3Border}" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" />
          <path d="M12 6 V10 M20 4 V10 M28 6 V10" stroke="${t3Border}" stroke-width="2" stroke-linecap="round" />
        </g>
        <text x="90" y="126" text-anchor="middle" fill="${t3Text}" font-size="16" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">Rest &amp; Chai</text>
        <rect x="32" y="144" width="116" height="24" rx="12" fill="${t3Bg}" stroke="${t3Border}" stroke-width="1" />
        <text x="90" y="160" text-anchor="middle" fill="${t3Badge}" font-size="9" font-weight="800" font-family="JetBrains Mono, monospace">5-10 MIN BREAK</text>
      </g>

      <!-- 4. Wait / Regroup -> Links to Screen 1 -->
      <g id="btn_stop_regroup" transform="translate(192, 220)">
        <rect width="180" height="200" rx="32" fill="${t4Bg}" fill-opacity="${isDark ? '0.5' : '1'}" stroke="${t4Border}" stroke-width="2" ${shadowAttr} />
        <g transform="translate(70, 40)">
          <circle cx="20" cy="12" r="6" stroke="${t4Border}" stroke-width="3" />
          <path d="M8 34 C8 26 14 22 20 22 C26 22 32 26 32 34" stroke="${t4Border}" stroke-width="3" stroke-linecap="round" />
        </g>
        <text x="90" y="126" text-anchor="middle" fill="${t4Text}" font-size="16" font-weight="900" font-family="Plus Jakarta Sans, sans-serif">Wait / Regroup</text>
        <rect x="32" y="144" width="116" height="24" rx="12" fill="${t4Bg}" stroke="${t4Border}" stroke-width="1" />
        <text x="90" y="160" text-anchor="middle" fill="${t4Badge}" font-size="9" font-weight="800" font-family="JetBrains Mono, monospace">HOLD PACK</text>
      </g>
    </g>

    <!-- Clear Stop Reason Button -> Links to Screen 1 -->
    <g id="btn_clear_stop" transform="translate(20, 780)">
      <rect width="372" height="52" rx="16" fill="${btnBg}" stroke="${cardStroke}" stroke-width="1.5" ${shadowAttr} />
      <text x="186" y="32" text-anchor="middle" fill="${textPrimary}" font-size="12" font-weight="800" font-family="Plus Jakarta Sans, sans-serif" letter-spacing="0.5">CLEAR STOP REASON (RESUME RIDING)</text>
    </g>
  </g>
</svg>`;
}

// WRITE ALL 12 SVGS
const svgs = [
  { file: 'figma_artboard_1_cockpit.svg', content: generateCockpit(true) },
  { file: 'figma_artboard_1_cockpit_light.svg', content: generateCockpit(false) },
  { file: 'figma_artboard_2_quick_settings.svg', content: generateQuickSettings(true) },
  { file: 'figma_artboard_2_quick_settings_light.svg', content: generateQuickSettings(false) },
  { file: 'figma_artboard_3_guardian.svg', content: generateGuardian(true) },
  { file: 'figma_artboard_3_guardian_light.svg', content: generateGuardian(false) },
  { file: 'figma_artboard_4_fuel.svg', content: generateFuel(true) },
  { file: 'figma_artboard_4_fuel_light.svg', content: generateFuel(false) },
  { file: 'figma_artboard_5_group_settings.svg', content: generateGroupSettings(true) },
  { file: 'figma_artboard_5_group_settings_light.svg', content: generateGroupSettings(false) },
  { file: 'figma_artboard_6_stop_picker.svg', content: generateStopPicker(true) },
  { file: 'figma_artboard_6_stop_picker_light.svg', content: generateStopPicker(false) }
];

svgs.forEach(s => {
  fs.writeFileSync(path.join(dir, s.file), s.content, 'utf8');
  console.log(`Generated: ${s.file} (${s.content.length} bytes)`);
});

console.log('✅ All 12 artboards generated successfully!');
