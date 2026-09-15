/* ============================================================
   OPENCOURT LA — main application
   v1.0.1
   ============================================================
   This file is responsible for:
   - Loading court + grand slam data from JSON
   - Initializing Google Maps with auto-fit bounds
   - Rendering the court list + map markers + stats
   - Wiring filters, selection, and the detail panel
   - Persisting live reports to localStorage (Phase 1.5)
   - Applying the seasonal Grand Slam theme

   Phase 2 hook: replace fetchCourts() with a call to your
   Supabase REST endpoint. Schema is already compatible.
   ============================================================ */

// In-memory state
let COURTS = [];
let GRAND_SLAMS = [];

const REPORT_TTL_MINUTES = 90;
const STORAGE_KEY = 'opencourt-la-reports-v1';

const state = {
  filters: { sport: "all", tier: "all", status: "all" },
  selectedId: null,
  markers: {},
  map: null,
  mapReady: false,
  dataReady: false
};

/* ============================================================
   DATA LOADING
   ============================================================ */
async function fetchCourts() {
  const res = await fetch('assets/data/courts.json');
  if (!res.ok) throw new Error(`Failed to load courts.json: ${res.status}`);
  const data = await res.json();
  return data.courts;
}

async function fetchSlams() {
  const res = await fetch('assets/data/grand-slams.json');
  if (!res.ok) throw new Error(`Failed to load grand-slams.json: ${res.status}`);
  const data = await res.json();
  return data.slams;
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

  if (inProgress) {
    hintTitle.textContent = `${slam.name} is live`;
    hint.textContent = `${slam.surface.charAt(0).toUpperCase() + slam.surface.slice(1)} season. Theme matches the tournament — check back as we roll through the calendar.`;
  } else if (daysUntil <= 7 && daysUntil >= 0) {
    hintTitle.textContent = `${slam.name} in ${daysUntil}d`;
    hint.textContent = `Theme shifts to celebrate the upcoming slam. ${slam.surface.charAt(0).toUpperCase() + slam.surface.slice(1)} court colors take over.`;
  } else {
    hintTitle.textContent = `Next slam: ${slam.name}`;
    hint.textContent = `${Math.abs(daysUntil)} days out. Background tuned to ${slam.surface}.`;
  }
}

/* ============================================================
   LIVE REPORTS — localStorage persistence
   Phase 2 migration: swap loadReports/saveReports for fetch()
   calls against your Supabase /reports endpoint.
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

function submitReport(courtId, status) {
  const reports = loadReports();
  const now = new Date().toISOString();
  if (!reports[courtId]) reports[courtId] = [];
  reports[courtId].push({ status, timestamp: now });
  if (reports[courtId].length > 5) {
    reports[courtId] = reports[courtId].slice(-5);
  }
  saveReports(reports);

  const court = COURTS.find(c => c.id === courtId);
  if (court) {
    court.live_reports = reports[courtId];
    court.last_reported_availability = { status, timestamp: now };
  }
}

function hydrateReportsIntoCourts() {
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
    return `Reported ${score.ageMin} min ago by a player on the ground.`;
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

  state.map = new google.maps.Map(document.getElementById('map'), {
    zoom: 10,
    center: { lat: 34.15, lng: -118.35 },
    styles: mapStyle,
    disableDefaultUI: false,
    zoomControl: true,
    mapTypeControl: false,
    streetViewControl: false,
    fullscreenControl: true,
    gestureHandling: 'greedy'
  });

  // Fit bounds to all courts (Antelope Valley → South Bay)
  const bounds = new google.maps.LatLngBounds();
  COURTS.forEach(c => bounds.extend({ lat: c.lat, lng: c.lng }));
  state.map.fitBounds(bounds, { top: 60, right: 60, bottom: 60, left: 60 });

  renderAll();
}

function createMarker(court) {
  const score = scoreAvailability(court);
  const hasLive = score.source === 'live';

  const pinEl = document.createElement('div');
  pinEl.className = `gm-pin ${score.status}${hasLive ? ' has-live' : ''}`;
  pinEl.dataset.id = court.id;
  pinEl.textContent = court.court_count;
  pinEl.title = `${court.name} — ${availabilityLabel(score.status)}`;

  let marker;
  if (google.maps.marker && google.maps.marker.AdvancedMarkerElement) {
    marker = new google.maps.marker.AdvancedMarkerElement({
      position: { lat: court.lat, lng: court.lng },
      map: state.map,
      content: pinEl,
      title: court.name
    });
    pinEl.addEventListener('click', () => selectCourt(court.id, { fly: false }));
  } else {
    // Legacy fallback
    const overlay = new google.maps.OverlayView();
    overlay.onAdd = function() {
      this.getPanes().overlayMouseTarget.appendChild(pinEl);
      pinEl.style.position = 'absolute';
      pinEl.addEventListener('click', () => selectCourt(court.id, { fly: false }));
    };
    overlay.draw = function() {
      const projection = this.getProjection();
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
    return `
      <div class="court-item ${state.selectedId === c.id ? 'selected' : ''}" data-id="${c.id}">
        <div class="court-row">
          <div style="flex:1; min-width: 0;">
            <div class="court-name">${c.name}</div>
            <div class="court-meta">
              <span>${c.neighborhood}</span>
              <span class="court-meta-dot"></span>
              <span class="tier-badge ${tierClass}">${tierLabel}</span>
              <span class="court-meta-dot"></span>
              <span>${c.court_count} courts</span>
              ${liveBadge}
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
}

/* ============================================================
   SELECTION + DETAIL PANEL
   ============================================================ */
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

  const score = scoreAvailability(court);
  const tierLabel = { "free": "Free public", "low-cost": "Low-cost public (< $20/hr)", "private": "Private / members" }[court.tier];

  document.getElementById('detail-eyebrow').textContent = `${court.neighborhood} • ${tierLabel}`;
  document.getElementById('detail-name').textContent = court.name;

  const reportCount = court.live_reports.length;

  document.getElementById('detail-body').innerHTML = `
    <div class="detail-status ${score.status}">
      <span class="detail-status-dot ${score.status}"></span>
      <div class="detail-status-text">
        <div class="detail-status-label ${score.status}">${availabilityLabel(score.status)}</div>
        <div class="detail-status-note">${availabilityNote(score, court)}</div>
        <div class="detail-status-source">${score.source === 'live' ? '◉ Live signal' : '✦ Heuristic estimate'}</div>
      </div>
    </div>

    <div class="detail-rows">
      <div class="detail-row">
        <span class="detail-key">Courts</span>
        <span class="detail-val">${court.court_count}</span>
      </div>
      <div class="detail-row">
        <span class="detail-key">Access</span>
        <span class="detail-val">${tierLabel}</span>
      </div>
      <div class="detail-row">
        <span class="detail-key">Demand tier</span>
        <span class="detail-val">${court.demand_tier.charAt(0).toUpperCase() + court.demand_tier.slice(1)}</span>
      </div>
      <div class="detail-row">
        <span class="detail-key">Recent reports</span>
        <span class="detail-val">${reportCount > 0 ? reportCount + ' on file' : 'None yet'}</span>
      </div>
      <div class="detail-row">
        <span class="detail-key">Notes</span>
        <span class="detail-val">${court.notes}</span>
      </div>
    </div>

    <div class="detail-sports">
      ${court.sports.map(s => `<span class="sport-tag ${s}">${s === 'tennis' ? '🎾' : '🏓'} ${s.charAt(0).toUpperCase() + s.slice(1)}</span>`).join('')}
    </div>

    ${court.tier !== 'private' ? `
    <div class="report-section">
      <div class="report-label">You're on the ground — what do you see?</div>
      <div class="report-buttons">
        <button class="report-btn" data-status="open" data-id="${court.id}">
          <span class="report-btn-dot"></span>
          <span class="report-btn-label">Open</span>
          <span class="report-btn-sub">Courts free</span>
        </button>
        <button class="report-btn" data-status="toss" data-id="${court.id}">
          <span class="report-btn-dot"></span>
          <span class="report-btn-label">Mixed</span>
          <span class="report-btn-sub">Some wait</span>
        </button>
        <button class="report-btn" data-status="full" data-id="${court.id}">
          <span class="report-btn-dot"></span>
          <span class="report-btn-label">Full</span>
          <span class="report-btn-sub">All taken</span>
        </button>
      </div>
      <div class="report-feedback" id="report-feedback"></div>
    </div>
    ` : ''}

    <a class="directions-btn" href="https://www.google.com/maps/dir/?api=1&destination=${court.lat},${court.lng}" target="_blank" rel="noopener">
      Open directions in Google Maps →
    </a>
  `;

  document.querySelectorAll('.report-btn').forEach(btn => {
    btn.addEventListener('click', (e) => {
      const status = e.currentTarget.dataset.status;
      const courtId = e.currentTarget.dataset.id;
      submitReport(courtId, status);
      const fb = document.getElementById('report-feedback');
      const labels = { open: 'open', toss: 'mixed', full: 'full' };
      fb.textContent = `Thanks. Marked as ${labels[status]} just now. This signal is live for the next 90 min for anyone using OpenCourt.`;
      fb.classList.add('shown');
      setTimeout(() => {
        renderAll();
        selectCourt(courtId, { fly: false });
      }, 800);
    });
  });

  document.getElementById('detail-panel').classList.add('open');
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
      });

      const activeClass = group === 'tier' ? 'active-accent'
                         : group === 'status' ? 'active-green'
                         : 'active';
      chip.classList.add('active', activeClass);

      renderAll();
    });
  });
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
    state.dataReady = true;

    wireEvents();
    updateTime();
    setInterval(updateTime, 30000);
    setInterval(applyTheme, 3600000);
    setInterval(renderAll, 600000);

    if (state.mapReady) buildMap();
    else renderList(), renderStats(); // partial render before map ready
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
