/* ============================================================
   OPENCOURT — main application (PickUp's successor)
   v1.2.0
   ============================================================
   This file is responsible for:
   - Loading courts (shared backend when configured, bundled JSON otherwise)
   - Initializing Google Maps with auto-fit bounds
   - Rendering the court list + map markers + stats
   - Wiring filters, selection, and the detail panel
   - Crowd reports: shared through the backend, or kept on this device
   - Pickups on a court: list, start, join, leave, cancel, share (backend only)
   - The inbox (backend only)
   - Applying the seasonal Grand Slam theme

   Honesty rule: the page always says where its data comes from
   (#data-source) and never labels a device-local report as shared.
   ============================================================ */

// In-memory state
let COURTS = [];
let GRAND_SLAMS = [];

const REPORT_TTL_MINUTES = 90;
const STORAGE_KEY = 'opencourt-la-reports-v1';
const CFG = window.OPENCOURT_CONFIG || {};
const BE = (window.Backend && window.Backend.enabled) ? window.Backend : null;

const state = {
  filters: { sport: "all", tier: "all", status: "all" },
  selectedId: null,
  markers: {},
  map: null,
  mapReady: false,
  dataReady: false,
  dataSource: 'offline',      // 'live' | 'offline' | 'offline-fallback'
  pickups: {},                // courtId -> rows from open_pickups
  mine: {},                   // pickupId -> my_pickups row
  me: null,                   // my profile (backend only)
  highlightPickup: null,      // pickup id opened from a share link
  inbox: [],
  inboxOpen: false
};

const live = () => !!BE && state.dataSource === 'live';

/* ============================================================
   SMALL HELPERS
   ============================================================ */
function esc(v) {
  return String(v == null ? '' : v).replace(/[&<>"']/g, c => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
}

function fmtWhen(iso) {
  const d = new Date(iso);
  if (isNaN(d)) return '';
  const now = new Date();
  const sameDay = (a, b) => a.toDateString() === b.toDateString();
  const tomorrow = new Date(now); tomorrow.setDate(now.getDate() + 1);
  const time = d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
  if (sameDay(d, now)) return `Today ${time}`;
  if (sameDay(d, tomorrow)) return `Tomorrow ${time}`;
  return `${d.toLocaleDateString('en-US', { weekday: 'short', month: 'short', day: 'numeric' })} ${time}`;
}

function sportEmoji(s) {
  return { tennis: '🎾', pickleball: '🏓', basketball: '🏀' }[s] || '🏟️';
}

function toLocalInputValue(d) {
  const pad = n => String(n).padStart(2, '0');
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())}T${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function flash(id, text, isError) {
  const el = document.getElementById(id);
  if (!el) return;
  el.textContent = text;
  el.classList.toggle('error', !!isError);
  el.classList.add('shown');
}

/* ============================================================
   DATA LOADING
   ============================================================ */
function normaliseCourt(c) {
  return Object.assign({}, c, {
    live_reports: Array.isArray(c.live_reports) ? c.live_reports : [],
    last_reported_availability: c.last_reported_availability || null,
    open_pickup_count: c.open_pickup_count || 0
  });
}

async function fetchCourts() {
  if (BE) {
    try {
      const rows = await BE.fetchCourts();
      state.dataSource = 'live';
      return rows.map(normaliseCourt);
    } catch (e) {
      console.warn('Backend unreachable; using bundled courts.json', e);
      state.dataSource = 'offline-fallback';
    }
  }
  const res = await fetch('assets/data/courts.json');
  if (!res.ok) throw new Error(`Failed to load courts.json: ${res.status}`);
  const data = await res.json();
  return data.courts.map(normaliseCourt);
}

async function fetchSlams() {
  const res = await fetch('assets/data/grand-slams.json');
  if (!res.ok) throw new Error(`Failed to load grand-slams.json: ${res.status}`);
  const data = await res.json();
  return data.slams;
}

function renderDataSource() {
  const el = document.getElementById('data-source');
  if (!el) return;
  const text = {
    'live': 'Shared data',
    'offline': 'Offline data · reports stay on this device',
    'offline-fallback': 'Backend unreachable · bundled data · reports stay on this device'
  }[state.dataSource];
  el.textContent = text;
  el.dataset.source = state.dataSource;
}

/* ============================================================
   SEASONAL THEME ENGINE
   ============================================================ */
function getCurrentSlamTheme(now = new Date()) {
  const today = now.toISOString().slice(0, 10);
  for (let i = GRAND_SLAMS.length - 1; i >= 0; i--) {
    if (today >= GRAND_SLAMS[i].activate) {
      return GRAND_SLAMS[i];
    }
  }
  return GRAND_SLAMS[0];
}

function applyTheme() {
  if (GRAND_SLAMS.length === 0) return;
  const slam = getCurrentSlamTheme();
  document.documentElement.setAttribute('data-theme', slam.id);

  const now = new Date();
  const today = now.toISOString().slice(0, 10);
  const inProgress = today >= slam.start && today <= slam.end;

  document.getElementById('slam-name').textContent = inProgress
    ? `${slam.name} — Live`
    : `Next: ${slam.name}`;

  const startDate = new Date(slam.start);
  const daysUntil = Math.ceil((startDate - now) / (1000 * 60 * 60 * 24));

  const hint = document.getElementById('hint-body');
  const hintTitle = document.getElementById('hint-title');
  const surface = slam.surface.charAt(0).toUpperCase() + slam.surface.slice(1);

  if (inProgress) {
    hintTitle.textContent = `${slam.name} is live`;
    hint.textContent = `${surface} season. Theme matches the tournament — check back as we roll through the calendar.`;
  } else if (daysUntil <= 7 && daysUntil >= 0) {
    hintTitle.textContent = `${slam.name} in ${daysUntil}d`;
    hint.textContent = `Theme shifts to celebrate the upcoming slam. ${surface} court colors take over.`;
  } else if (daysUntil < 0) {
    hintTitle.textContent = `${slam.name} just finished`;
    hint.textContent = `Background still tuned to ${slam.surface} until the next slam's window opens.`;
  } else {
    hintTitle.textContent = `Next slam: ${slam.name}`;
    hint.textContent = `${daysUntil} days out. Background tuned to ${slam.surface}.`;
  }
}

/* ============================================================
   LIVE REPORTS
   Shared through the backend when it is configured and reachable;
   otherwise kept in this browser's localStorage (and labelled so).
   ============================================================ */
function loadReports() {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return raw ? JSON.parse(raw) : {};
  } catch (e) {
    console.warn('Could not load reports', e);
    return {};
  }
}

function saveReports(reports) {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(reports));
  } catch (e) {
    console.warn('Could not save reports', e);
  }
}

function applyReportToCourt(court, status, timestamp) {
  const rep = { status, timestamp };
  court.live_reports = [...(court.live_reports || []), rep].slice(-5);
  court.last_reported_availability = rep;
}

// Returns { shared: boolean }. Throws (with a readable message) when the backend refuses.
async function submitReport(courtId, status) {
  const court = COURTS.find(c => c.id === courtId);
  if (live()) {
    const row = await BE.submitReport(courtId, status);
    if (court) applyReportToCourt(court, row.status, row.created_at);
    return { shared: true };
  }
  const reports = loadReports();
  const now = new Date().toISOString();
  if (!reports[courtId]) reports[courtId] = [];
  reports[courtId].push({ status, timestamp: now });
  if (reports[courtId].length > 5) reports[courtId] = reports[courtId].slice(-5);
  saveReports(reports);
  if (court) applyReportToCourt(court, status, now);
  return { shared: false };
}

function hydrateReportsIntoCourts() {
  if (live()) return; // the view already carries everyone's reports
  const reports = loadReports();
  COURTS.forEach(court => {
    if (reports[court.id] && reports[court.id].length > 0) {
      court.live_reports = reports[court.id];
      court.last_reported_availability = reports[court.id][reports[court.id].length - 1];
    }
  });
}

/* ============================================================
   AVAILABILITY SCORING
   Live reports (if fresh, < REPORT_TTL_MINUTES) override the
   heuristic. Heuristic uses day, hour, court count, demand tier.
   ============================================================ */
function scoreAvailability(court, now = new Date()) {
  if (court.last_reported_availability) {
    const reportAge = (now - new Date(court.last_reported_availability.timestamp)) / 60000;
    if (reportAge < REPORT_TTL_MINUTES) {
      return { status: court.last_reported_availability.status, source: 'live', ageMin: Math.round(reportAge) };
    }
  }

  const hour = now.getHours();
  const day = now.getDay();
  const isWeekend = (day === 0 || day === 6);

  let pressure;
  if (hour < 7) pressure = 0;
  else if (hour < 10) pressure = 1;
  else if (hour < 15) pressure = 2;
  else if (hour < 17) pressure = 3;
  else if (hour < 21) pressure = 4;
  else pressure = 1;

  if (isWeekend && hour >= 9 && hour <= 18) pressure += 1;

  const demandBoost = { low: 0, medium: 1, high: 2 }[court.demand_tier] || 0;
  pressure += demandBoost;

  if (court.court_count >= 10) pressure -= 2;
  else if (court.court_count >= 6) pressure -= 1;
  else if (court.court_count <= 2) pressure += 1;

  if (court.tier === "private") return { status: "full", source: "heuristic", ageMin: null };

  let status;
  if (pressure <= 1) status = "open";
  else if (pressure <= 3) status = "toss";
  else status = "full";

  return { status, source: "heuristic", ageMin: null };
}

function availabilityLabel(status) {
  return { open: "Likely open", toss: "Toss-up", full: "Likely full" }[status];
}

function availabilityNote(score, court) {
  if (score.source === 'live') {
    return live()
      ? `Reported ${score.ageMin} min ago by a player on the ground.`
      : `Reported ${score.ageMin} min ago on this device.`;
  }
  const hour = new Date().getHours();
  const isEvening = hour >= 17 && hour <= 21;
  if (court.tier === "private") return "Private facility — public access not available.";
  if (score.status === "open") return court.court_count >= 6
    ? "Plenty of courts, low demand right now."
    : "Quiet window — good time to head over.";
  if (score.status === "toss") return isEvening
    ? "Evening pressure rising. Worth a call ahead if possible."
    : "Could go either way — moderate demand expected.";
  return court.demand_tier === "high"
    ? "High-demand spot at peak hours. Expect a wait."
    : "Limited courts during a busy window.";
}

/* ============================================================
   GOOGLE MAPS INITIALIZATION
   Called by the Google Maps script tag via &callback=initMap
   ============================================================ */
window.initMap = function() {
  state.mapReady = true;
  if (state.dataReady) buildMap();
};

// Advanced Markers need a Map ID (and a Map ID makes Google ignore the JSON style below).
// Without a configured Map ID the page draws its own pins through an OverlayView, which keeps
// the editorial style. Found in the 2026-10-17 review: the previous build used Advanced Markers
// on a map without a Map ID and rendered no pins at all.
const useAdvancedMarkers = () => !!CFG.GOOGLE_MAP_ID && !!(google.maps.marker && google.maps.marker.AdvancedMarkerElement);

function buildMap() {
  document.getElementById('map-loading').classList.add('hidden');

  // Subtle, editorial-atlas map style
  const mapStyle = [
    { elementType: "geometry", stylers: [{ color: "#ebe4d4" }] },
    { elementType: "labels.text.stroke", stylers: [{ color: "#f4efe6" }] },
    { elementType: "labels.text.fill", stylers: [{ color: "#5a3c2a" }] },
    { featureType: "poi", stylers: [{ visibility: "off" }] },
    { featureType: "poi.park", elementType: "geometry", stylers: [{ color: "#dce8d3" }] },
    { featureType: "road", elementType: "geometry", stylers: [{ color: "#faf2e3" }] },
    { featureType: "road", elementType: "geometry.stroke", stylers: [{ color: "#d4be99" }] },
    { featureType: "road.highway", elementType: "geometry", stylers: [{ color: "#f5e5c4" }] },
    { featureType: "road.highway", elementType: "geometry.stroke", stylers: [{ color: "#c89028" }] },
    { featureType: "water", elementType: "geometry", stylers: [{ color: "#bcd3df" }] },
    { featureType: "water", elementType: "labels.text.fill", stylers: [{ color: "#5a8095" }] },
    { featureType: "transit", stylers: [{ visibility: "off" }] }
  ];

  const options = {
    zoom: 10,
    center: { lat: 34.15, lng: -118.35 },
    disableDefaultUI: false,
    zoomControl: true,
    mapTypeControl: false,
    streetViewControl: false,
    fullscreenControl: true,
    gestureHandling: 'greedy'
  };
  if (CFG.GOOGLE_MAP_ID) options.mapId = CFG.GOOGLE_MAP_ID;
  else options.styles = mapStyle;

  state.map = new google.maps.Map(document.getElementById('map'), options);

  // Fit bounds to all courts (Antelope Valley → South Bay)
  const bounds = new google.maps.LatLngBounds();
  COURTS.forEach(c => bounds.extend({ lat: c.lat, lng: c.lng }));
  state.map.fitBounds(bounds, { top: 60, right: 60, bottom: 60, left: 60 });

  renderAll();
}

function createMarker(court) {
  const score = scoreAvailability(court);
  const hasLive = score.source === 'live';
  const hasGame = (court.open_pickup_count || 0) > 0;

  const pinEl = document.createElement('div');
  pinEl.className = `gm-pin ${score.status}${hasLive ? ' has-live' : ''}${hasGame ? ' has-game' : ''}`;
  pinEl.dataset.id = court.id;
  pinEl.textContent = court.court_count;
  pinEl.title = `${court.name} — ${availabilityLabel(score.status)}${hasGame ? ` — ${court.open_pickup_count} pickup${court.open_pickup_count > 1 ? 's' : ''} on` : ''}`;
  pinEl.setAttribute('role', 'button');
  pinEl.setAttribute('aria-label', pinEl.title);

  let marker;
  if (useAdvancedMarkers()) {
    marker = new google.maps.marker.AdvancedMarkerElement({
      position: { lat: court.lat, lng: court.lng },
      map: state.map,
      content: pinEl,
      title: court.name
    });
    pinEl.addEventListener('click', () => selectCourt(court.id, { fly: false }));
  } else {
    const overlay = new google.maps.OverlayView();
    overlay.onAdd = function() {
      this.getPanes().overlayMouseTarget.appendChild(pinEl);
      pinEl.style.position = 'absolute';
      pinEl.addEventListener('click', () => selectCourt(court.id, { fly: false }));
    };
    overlay.draw = function() {
      const projection = this.getProjection();
      if (!projection) return;
      const point = projection.fromLatLngToDivPixel(new google.maps.LatLng(court.lat, court.lng));
      pinEl.style.left = (point.x - 15) + 'px';
      pinEl.style.top = (point.y - 15) + 'px';
    };
    overlay.onRemove = function() { pinEl.remove(); };
    overlay.setMap(state.map);
    marker = overlay;
    marker._pinEl = pinEl;
  }
  return marker;
}

function removeMarker(marker) {
  if (marker.setMap) marker.setMap(null);
  else if (marker.map !== undefined) marker.map = null;
}

/* ============================================================
   RENDER
   ============================================================ */
function visibleCourts() {
  return COURTS.filter(c => {
    if (state.filters.sport !== "all" && !c.sports.includes(state.filters.sport)) return false;
    if (state.filters.tier !== "all" && c.tier !== state.filters.tier) return false;
    if (state.filters.status !== "all" && scoreAvailability(c).status !== state.filters.status) return false;
    return true;
  });
}

function renderList() {
  const list = document.getElementById('court-list');
  const visible = visibleCourts();

  if (visible.length === 0) {
    list.innerHTML = `<div style="padding:32px 24px;text-align:center;color:var(--ink-mute);font-size:13px;">
      No courts match these filters.<br><span style="font-size:11px;">Try widening your search.</span>
    </div>`;
    return;
  }

  list.innerHTML = visible.map(c => {
    const score = scoreAvailability(c);
    const tierClass = `tier-${c.tier.replace('-', '')}`;
    const tierLabel = { "free": "Free", "low-cost": "Low-cost", "private": "Private" }[c.tier];
    const liveBadge = score.source === 'live'
      ? `<span class="live-badge"><span class="live-dot"></span>Live</span>`
      : '';
    const gameBadge = c.open_pickup_count > 0
      ? `<span class="game-badge" title="${c.open_pickup_count} pickup${c.open_pickup_count > 1 ? 's' : ''} on">🎾 ${c.open_pickup_count}</span>`
      : '';
    return `
      <div class="court-item ${state.selectedId === c.id ? 'selected' : ''}" data-id="${esc(c.id)}" role="button" tabindex="0">
        <div class="court-row">
          <div style="flex:1; min-width: 0;">
            <div class="court-name">${esc(c.name)}</div>
            <div class="court-meta">
              <span>${esc(c.neighborhood)}</span>
              <span class="court-meta-dot"></span>
              <span class="tier-badge ${tierClass}">${tierLabel}</span>
              <span class="court-meta-dot"></span>
              <span>${esc(c.court_count)} courts</span>
              ${liveBadge}${gameBadge}
            </div>
          </div>
          <div class="availability-indicator">
            <span class="avail-dot ${score.status}"></span>
            <span class="avail-label ${score.status}">${availabilityLabel(score.status).replace('Likely ','')}</span>
          </div>
        </div>
      </div>
    `;
  }).join('');

  list.querySelectorAll('.court-item').forEach(el => {
    el.addEventListener('click', () => selectCourt(el.dataset.id, { fly: true }));
    el.addEventListener('keydown', (e) => { if (e.key === 'Enter' || e.key === ' ') { e.preventDefault(); selectCourt(el.dataset.id, { fly: true }); } });
  });
}

function renderStats() {
  const visible = visibleCourts();
  const counts = { open: 0, toss: 0, full: 0 };
  visible.forEach(c => counts[scoreAvailability(c).status]++);
  document.getElementById('stat-open').textContent = counts.open;
  document.getElementById('stat-toss').textContent = counts.toss;
  document.getElementById('stat-full').textContent = counts.full;
}

function renderMarkers() {
  if (!state.map) return;

  Object.values(state.markers).forEach(removeMarker);
  state.markers = {};

  visibleCourts().forEach(c => {
    state.markers[c.id] = createMarker(c);
  });

  if (state.selectedId && state.markers[state.selectedId]) {
    const m = state.markers[state.selectedId];
    const pinEl = m._pinEl || m.content;
    if (pinEl) pinEl.classList.add('selected');
  }
}

function renderAll() {
  renderList();
  renderStats();
  renderMarkers();
  if (state.selectedId) refreshDetailStatus();
}

// Re-score the open detail panel's status block without rebuilding the whole panel.
function refreshDetailStatus() {
  const court = COURTS.find(c => c.id === state.selectedId);
  const el = document.getElementById('detail-status');
  if (!court || !el) return;
  el.outerHTML = statusBlock(court);
}

/* ============================================================
   SELECTION + DETAIL PANEL
   ============================================================ */
function statusBlock(court) {
  const score = scoreAvailability(court);
  return `
    <div class="detail-status ${score.status}" id="detail-status">
      <span class="detail-status-dot ${score.status}"></span>
      <div class="detail-status-text">
        <div class="detail-status-label ${score.status}">${availabilityLabel(score.status)}</div>
        <div class="detail-status-note">${esc(availabilityNote(score, court))}</div>
        <div class="detail-status-source">${score.source === 'live' ? (live() ? '◉ Live signal' : '◉ Your report on this device') : '✦ Heuristic estimate'}</div>
      </div>
    </div>`;
}

function selectCourt(id, opts = {}) {
  state.selectedId = id;
  const court = COURTS.find(c => c.id === id);
  if (!court) return;

  document.querySelectorAll('.court-item').forEach(el => {
    el.classList.toggle('selected', el.dataset.id === id);
    if (el.dataset.id === id) el.scrollIntoView({ behavior: 'smooth', block: 'nearest' });
  });

  document.querySelectorAll('.gm-pin').forEach(el => el.classList.remove('selected'));
  const marker = state.markers[id];
  if (marker) {
    const pinEl = marker._pinEl || marker.content;
    if (pinEl) pinEl.classList.add('selected');
  }

  if (opts.fly && state.map) {
    state.map.panTo({ lat: court.lat, lng: court.lng });
    if (state.map.getZoom() < 12) state.map.setZoom(13);
  }

  const tierLabel = { "free": "Free public", "low-cost": "Low-cost public (< $20/hr)", "private": "Private / members" }[court.tier];

  document.getElementById('detail-eyebrow').textContent = `${court.neighborhood} • ${tierLabel}`;
  document.getElementById('detail-name').textContent = court.name;

  const reportCount = (court.live_reports || []).length;
  const demand = String(court.demand_tier || '');

  document.getElementById('detail-body').innerHTML = `
    ${statusBlock(court)}

    <div class="detail-rows">
      <div class="detail-row">
        <span class="detail-key">Courts</span>
        <span class="detail-val">${esc(court.court_count)}</span>
      </div>
      <div class="detail-row">
        <span class="detail-key">Access</span>
        <span class="detail-val">${tierLabel}</span>
      </div>
      <div class="detail-row">
        <span class="detail-key">Demand tier</span>
        <span class="detail-val">${esc(demand.charAt(0).toUpperCase() + demand.slice(1))}</span>
      </div>
      <div class="detail-row">
        <span class="detail-key">Recent reports</span>
        <span class="detail-val">${reportCount > 0 ? reportCount + ' in the last 90 min' : 'None yet'}</span>
      </div>
      <div class="detail-row">
        <span class="detail-key">Notes</span>
        <span class="detail-val">${esc(court.notes)}</span>
      </div>
    </div>

    <div class="detail-sports">
      ${court.sports.map(s => `<span class="sport-tag ${esc(s)}">${sportEmoji(s)} ${esc(s.charAt(0).toUpperCase() + s.slice(1))}</span>`).join('')}
    </div>

    ${court.tier !== 'private' ? `
    <div class="report-section">
      <div class="report-label">You're on the ground — what do you see?</div>
      <div class="report-buttons">
        <button class="report-btn" data-status="open" data-id="${esc(court.id)}">
          <span class="report-btn-dot"></span>
          <span class="report-btn-label">Open</span>
          <span class="report-btn-sub">Courts free</span>
        </button>
        <button class="report-btn" data-status="toss" data-id="${esc(court.id)}">
          <span class="report-btn-dot"></span>
          <span class="report-btn-label">Mixed</span>
          <span class="report-btn-sub">Some wait</span>
        </button>
        <button class="report-btn" data-status="full" data-id="${esc(court.id)}">
          <span class="report-btn-dot"></span>
          <span class="report-btn-label">Full</span>
          <span class="report-btn-sub">All taken</span>
        </button>
      </div>
      <div class="report-feedback" id="report-feedback"></div>
    </div>

    <div class="pickups-section" id="pickups-section">
      <div class="report-label">Pickups here</div>
      <div id="pickups-list" class="pickups-list"></div>
      <div id="pickups-actions"></div>
      <div class="report-feedback" id="pickup-feedback"></div>
    </div>
    ` : ''}

    <a class="directions-btn" href="https://www.google.com/maps/dir/?api=1&destination=${encodeURIComponent(court.lat + ',' + court.lng)}" target="_blank" rel="noopener">
      Open directions in Google Maps →
    </a>
  `;

  document.querySelectorAll('.report-btn').forEach(btn => {
    btn.addEventListener('click', async (e) => {
      const status = e.currentTarget.dataset.status;
      const courtId = e.currentTarget.dataset.id;
      const labels = { open: 'open', toss: 'mixed', full: 'full' };
      document.querySelectorAll('.report-btn').forEach(b => b.disabled = true);
      try {
        const r = await submitReport(courtId, status);
        flash('report-feedback', r.shared
          ? `Thanks. Marked as ${labels[status]} just now — shared with everyone for 90 min.`
          : `Thanks. Marked as ${labels[status]} just now — saved on this device for 90 min.`);
        setTimeout(() => { renderAll(); }, 600);
      } catch (err) {
        flash('report-feedback', err.message || 'Could not save the report.', true);
        document.querySelectorAll('.report-btn').forEach(b => b.disabled = false);
      }
    });
  });

  renderPickups(court);

  document.getElementById('detail-panel').classList.add('open');
}

/* ============================================================
   PICKUPS ON A COURT (backend only)
   ============================================================ */
async function renderPickups(court) {
  const list = document.getElementById('pickups-list');
  const actions = document.getElementById('pickups-actions');
  if (!list || !actions) return;

  if (!live()) {
    list.innerHTML = `<div class="pickups-empty">Pickups need the shared backend, which is not configured on this copy of the page.</div>`;
    actions.innerHTML = '';
    return;
  }

  list.innerHTML = `<div class="pickups-empty">Loading…</div>`;
  try {
    const [rows, mine] = await Promise.all([BE.listPickups(court.id), BE.myPickups()]);
    state.pickups[court.id] = rows;
    state.mine = {};
    mine.forEach(m => { state.mine[m.id] = m; });
    court.open_pickup_count = rows.length;

    if (rows.length === 0) {
      list.innerHTML = `<div class="pickups-empty">No pickup on this court yet.</div>`;
    } else {
      list.innerHTML = rows.map(p => pickupRow(p)).join('');
    }
    actions.innerHTML = `<button class="pickup-new-btn" id="pickup-new">+ Start a pickup here</button><div id="pickup-form-slot"></div>`;
    document.getElementById('pickup-new').addEventListener('click', () => showPickupForm(court));
    wirePickupButtons(court);
    if (state.highlightPickup) {
      const el = list.querySelector(`[data-pickup="${state.highlightPickup}"]`);
      if (el) { el.classList.add('highlight'); el.scrollIntoView({ behavior: 'smooth', block: 'center' }); }
      state.highlightPickup = null;
    }
  } catch (err) {
    list.innerHTML = `<div class="pickups-empty error">${esc(err.message || 'Could not load pickups.')}</div>`;
    actions.innerHTML = '';
  }
}

function pickupRow(p) {
  const me = state.mine[p.id];
  const myStatus = me ? me.my_status : null;
  const full = p.spots_left <= 0;
  const open = p.status === 'open';
  let btns = '';
  if (myStatus === 'owner') {
    btns = `<button class="pk-btn ghost" data-act="link" data-pickup="${esc(p.id)}">Copy link</button>` +
           (p.status !== 'closed' ? `<button class="pk-btn danger" data-act="cancel" data-pickup="${esc(p.id)}">Cancel</button>` : '');
  } else if (myStatus === 'joined') {
    btns = `<button class="pk-btn ghost" data-act="leave" data-pickup="${esc(p.id)}">Leave</button>`;
  } else if (myStatus === 'invited') {
    btns = `<button class="pk-btn" data-act="accept" data-pickup="${esc(p.id)}">Accept</button><button class="pk-btn ghost" data-act="decline" data-pickup="${esc(p.id)}">Decline</button>`;
  } else if (open && !full) {
    btns = `<button class="pk-btn" data-act="join" data-pickup="${esc(p.id)}">Join</button>`;
  } else {
    btns = `<span class="pk-state">${full ? 'Full' : 'In progress'}</span>`;
  }
  const you = myStatus === 'owner' ? ' · yours' : myStatus === 'joined' ? ' · you’re in' : myStatus === 'invited' ? ' · invited' : '';
  return `
    <div class="pickup-row ${p.status}" data-pickup="${esc(p.id)}">
      <div class="pickup-main">
        <div class="pickup-when">${sportEmoji(p.sport)} ${esc(fmtWhen(p.starts_at))}${p.status === 'in_progress' ? ' · playing now' : ''}</div>
        <div class="pickup-meta">${esc(p.joined_count)}/${esc(p.capacity)} players · by ${esc(p.organiser_name)}${you}${p.note ? ` · ${esc(p.note)}` : ''}</div>
      </div>
      <div class="pickup-btns">${btns}</div>
    </div>`;
}

function wirePickupButtons(court) {
  document.querySelectorAll('#pickups-list .pk-btn').forEach(btn => {
    btn.addEventListener('click', async (e) => {
      const act = e.currentTarget.dataset.act;
      const id = e.currentTarget.dataset.pickup;
      try {
        if (act === 'link') {
          const mine = state.mine[id];
          const url = `${location.origin}${location.pathname}#pickup=${mine ? mine.share_token : ''}`;
          await navigator.clipboard.writeText(url);
          flash('pickup-feedback', 'Link copied. Anyone with it can open this pickup and join.');
          return;
        }
        await withProfile(async () => {
          if (act === 'join') { await BE.joinPickup(id); flash('pickup-feedback', 'You’re in. The organiser has been told.'); }
          if (act === 'leave') { await BE.leavePickup(id); flash('pickup-feedback', 'You left this pickup.'); }
          if (act === 'cancel') {
            if (!confirm('Cancel this pickup? Everyone on the roster will be told.')) return;
            await BE.cancelPickup(id); flash('pickup-feedback', 'Pickup cancelled.');
          }
          if (act === 'accept') { await BE.respondToInvitation(id, true); flash('pickup-feedback', 'Accepted. You’re in.'); }
          if (act === 'decline') { await BE.respondToInvitation(id, false); flash('pickup-feedback', 'Declined.'); }
        }, court);
        await renderPickups(court);
        renderList(); renderMarkers();
      } catch (err) {
        flash('pickup-feedback', err.message || 'That did not work.', true);
      }
    });
  });
}

// Runs fn once the visitor has a profile; shows the name form first when they have none.
async function withProfile(fn, court) {
  await BE.ensureSession();
  const me = state.me || await BE.myProfile();
  if (me) { state.me = me; return fn(); }
  return new Promise((resolve, reject) => {
    showProfileForm(court, async () => {
      try { resolve(await fn()); } catch (e) { reject(e); }
    });
  });
}

function showProfileForm(court, onDone) {
  const slot = document.getElementById('pickup-form-slot');
  if (!slot) return;
  slot.innerHTML = `
    <form class="pickup-form" id="profile-form">
      <div class="pickup-form-title">Pick a name other players will see</div>
      <label>Name <input name="display_name" maxlength="40" required placeholder="Ashwin"></label>
      <label>Username <input name="username" maxlength="20" pattern="[A-Za-z0-9_]{3,20}" required placeholder="ash_56"></label>
      <label>Skill
        <select name="skill">
          <option value="">—</option><option value="1">1 · new</option><option value="2">2</option><option value="3">3 · steady</option><option value="4">4</option><option value="5">5 · competitive</option>
        </select>
      </label>
      <div class="pickup-form-btns"><button type="submit" class="pk-btn">Save</button><button type="button" class="pk-btn ghost" data-close>Not now</button></div>
      <div class="pickup-form-note">No password, no email needed. You can attach an email later to keep this identity across devices.</div>
    </form>`;
  const form = document.getElementById('profile-form');
  form.querySelector('[data-close]').addEventListener('click', () => { slot.innerHTML = ''; });
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const fd = new FormData(form);
    try {
      state.me = await BE.upsertProfile(String(fd.get('username')), String(fd.get('display_name')), fd.get('skill') || null);
      slot.innerHTML = '';
      refreshInbox();
      onDone && onDone();
    } catch (err) {
      flash('pickup-feedback', err.message || 'Could not save your name.', true);
    }
  });
}

function showPickupForm(court) {
  const slot = document.getElementById('pickup-form-slot');
  if (!slot) return;
  const start = new Date(Date.now() + 30 * 60000);
  start.setMinutes(start.getMinutes() - (start.getMinutes() % 30), 0, 0);
  slot.innerHTML = `
    <form class="pickup-form" id="pickup-form">
      <div class="pickup-form-title">Start a pickup at ${esc(court.name)}</div>
      <label>Sport
        <select name="sport">${court.sports.map(s => `<option value="${esc(s)}">${sportEmoji(s)} ${esc(s)}</option>`).join('')}</select>
      </label>
      <label>When <input type="datetime-local" name="starts_at" required value="${toLocalInputValue(start)}"></label>
      <label>Players <input type="number" name="capacity" min="2" max="30" value="4" required></label>
      <label>Note <input name="note" maxlength="280" placeholder="Doubles, bring balls"></label>
      <div class="pickup-form-btns"><button type="submit" class="pk-btn">Create</button><button type="button" class="pk-btn ghost" data-close>Cancel</button></div>
    </form>`;
  const form = document.getElementById('pickup-form');
  form.querySelector('[data-close]').addEventListener('click', () => { slot.innerHTML = ''; });
  form.addEventListener('submit', async (e) => {
    e.preventDefault();
    const fd = new FormData(form);
    const startsAt = new Date(String(fd.get('starts_at')));
    try {
      await withProfile(async () => {
        const p = await BE.createPickup({
          courtId: court.id, sport: String(fd.get('sport')), startsAt: startsAt.toISOString(),
          capacity: Number(fd.get('capacity')), note: String(fd.get('note') || '')
        });
        flash('pickup-feedback', `Pickup created for ${fmtWhen(p.starts_at)}. Use “Copy link” to invite people.`);
      }, court);
      await renderPickups(court);
      renderList(); renderMarkers();
    } catch (err) {
      flash('pickup-feedback', err.message || 'Could not create the pickup.', true);
    }
  });
}

/* ============================================================
   INBOX (backend only)
   ============================================================ */
function notificationText(n) {
  const who = n.actor_name || 'Someone';
  const where = n.court_name ? ` at ${n.court_name}` : '';
  const when = n.pickup_starts_at ? ` (${fmtWhen(n.pickup_starts_at)})` : '';
  return {
    joined: `${who} joined your pickup${where}${when}.`,
    left: `${who} left your pickup${where}${when}.`,
    invitation: `${who} invited you to a pickup${where}${when}.`,
    cancelled: `${who} cancelled the pickup${where}${when}.`,
    enter_result: `Your pickup${where}${when} has started. Enter the result when it ends.`,
    vote_mvp: `Vote for the MVP of your pickup${where}${when}.`,
    you_are_mvp: `You were voted MVP${where}${when}.`,
    friend_request: `${who} wants to be your teammate.`,
    friend_accepted: `${who} accepted your teammate request.`,
    friend_rejected: `${who} declined your teammate request.`
  }[n.kind] || n.kind;
}

async function refreshInbox() {
  const btn = document.getElementById('inbox-btn');
  if (!btn || !live()) return;
  try {
    const session = await BE.getSession();
    if (!session) { btn.classList.add('hidden'); return; }
    state.inbox = await BE.notifications(20);
    btn.classList.remove('hidden');
    const count = document.getElementById('inbox-count');
    count.textContent = state.inbox.length;
    count.classList.toggle('hidden', state.inbox.length === 0);
    if (state.inboxOpen) renderInbox();
  } catch (e) {
    console.warn('Inbox unavailable', e);
  }
}

function renderInbox() {
  const box = document.getElementById('inbox');
  if (!box) return;
  box.classList.toggle('open', state.inboxOpen);
  if (!state.inboxOpen) return;
  if (state.inbox.length === 0) {
    box.innerHTML = `<div class="inbox-empty">Nothing new.</div>`;
    return;
  }
  box.innerHTML = state.inbox.map(n => `
    <div class="inbox-item" data-id="${esc(n.id)}">
      <div class="inbox-text">${esc(notificationText(n))}</div>
      <div class="inbox-actions">
        ${n.kind === 'invitation' && n.pickup_id ? `<button class="pk-btn" data-act="accept" data-pickup="${esc(n.pickup_id)}" data-nid="${esc(n.id)}">Accept</button><button class="pk-btn ghost" data-act="decline" data-pickup="${esc(n.pickup_id)}" data-nid="${esc(n.id)}">Decline</button>` : ''}
        ${n.court_id ? `<button class="pk-btn ghost" data-act="show" data-court="${esc(n.court_id)}" data-nid="${esc(n.id)}">Show</button>` : ''}
        <button class="pk-btn ghost" data-act="read" data-nid="${esc(n.id)}">Dismiss</button>
      </div>
    </div>`).join('') + `<button class="pk-btn ghost inbox-all" data-act="read-all">Mark all read</button>`;
  box.querySelectorAll('[data-act]').forEach(b => b.addEventListener('click', async (e) => {
    const { act, pickup, nid, court } = e.currentTarget.dataset;
    try {
      if (act === 'accept') await BE.respondToInvitation(pickup, true);
      if (act === 'decline') await BE.respondToInvitation(pickup, false);
      if (act === 'show') { state.inboxOpen = false; renderInbox(); selectCourt(court, { fly: true }); }
      if (act === 'read-all') await BE.markRead(state.inbox.map(n => n.id));
      else if (nid) await BE.markRead([Number(nid)]);
      await refreshInbox();
      if (act !== 'show') renderInbox();
    } catch (err) {
      alert(err.message || 'That did not work.');
    }
  }));
}

/* ============================================================
   DEEP LINK  (#pickup=<token>)
   ============================================================ */
async function openSharedPickup() {
  const m = location.hash.match(/^#pickup=([A-Za-z0-9_-]{8,64})$/);
  if (!m) return;
  if (!live()) { console.warn('Shared pickup link ignored: no backend configured.'); return; }
  try {
    const p = await BE.pickupByToken(m[1]);
    if (!p) { flash('report-feedback', 'That pickup link is no longer valid.', true); return; }
    state.highlightPickup = p.id;
    selectCourt(p.court_id, { fly: true });
  } catch (e) {
    console.warn('Could not resolve the shared pickup', e);
  }
}

/* ============================================================
   EVENT WIRING
   ============================================================ */
function wireEvents() {
  document.getElementById('detail-close').addEventListener('click', () => {
    document.getElementById('detail-panel').classList.remove('open');
    state.selectedId = null;
    renderAll();
  });

  document.querySelectorAll('.chip').forEach(chip => {
    chip.addEventListener('click', () => {
      const group = chip.dataset.filter;
      const value = chip.dataset.value;
      state.filters[group] = value;

      document.querySelectorAll(`.chip[data-filter="${group}"]`).forEach(c => {
        c.classList.remove('active', 'active-accent', 'active-green');
        c.setAttribute('aria-pressed', 'false');
      });

      const activeClass = group === 'tier' ? 'active-accent'
                         : group === 'status' ? 'active-green'
                         : 'active';
      chip.classList.add('active', activeClass);
      chip.setAttribute('aria-pressed', 'true');

      renderAll();
    });
  });

  const inboxBtn = document.getElementById('inbox-btn');
  if (inboxBtn) {
    inboxBtn.addEventListener('click', () => { state.inboxOpen = !state.inboxOpen; renderInbox(); });
  }

  window.addEventListener('hashchange', openSharedPickup);
}

function updateTime() {
  const now = new Date();
  const opts = { weekday: 'short', hour: 'numeric', minute: '2-digit', hour12: true };
  document.getElementById('current-time').textContent = now.toLocaleString('en-US', opts).toUpperCase();
}

/* ============================================================
   BOOTSTRAP
   ============================================================ */
async function boot() {
  try {
    const [courts, slams] = await Promise.all([fetchCourts(), fetchSlams()]);
    COURTS = courts;
    GRAND_SLAMS = slams;
    hydrateReportsIntoCourts();
    applyTheme();
    renderDataSource();
    state.dataReady = true;

    wireEvents();
    updateTime();
    setInterval(updateTime, 30000);
    setInterval(applyTheme, 3600000);
    setInterval(renderAll, 600000);

    if (state.mapReady) buildMap();
    else { renderList(); renderStats(); } // partial render before map ready

    if (live()) {
      refreshInbox();
      setInterval(refreshInbox, 60000);
      // Re-read shared courts every 5 minutes so other people's reports and pickups show up.
      setInterval(async () => {
        try {
          const rows = await BE.fetchCourts();
          const byId = {};
          rows.forEach(r => { byId[r.id] = normaliseCourt(r); });
          COURTS = COURTS.map(c => byId[c.id] || c);
          renderAll();
        } catch (e) { console.warn('Refresh failed', e); }
      }, 300000);
      openSharedPickup();
    }
  } catch (err) {
    console.error('Boot failed:', err);
    document.getElementById('map-loading').textContent = 'Failed to load court data. Check console.';
  }
}

// Map-key warning: if maps script hasn't fired callback in 5s, show banner
setTimeout(() => {
  if (!state.mapReady) {
    document.getElementById('key-warning')?.classList.add('shown');
    document.getElementById('map-loading')?.classList.add('hidden');
  }
}, 5000);

document.addEventListener('DOMContentLoaded', boot);
