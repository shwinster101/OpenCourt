# OpenCourt LA

> Turning "where can I play?" into "I'm on my way."

OpenCourt LA is a discovery tool for recreational tennis and pickleball players in Los Angeles County. It surfaces free and low-cost public courts on a map, scores their likely availability in real time, and lets players on the ground share live availability reports with everyone else.

**[Live site →](https://YOUR_USERNAME.github.io/opencourt-la/)** *(replace once Pages is enabled)*

---

## Why this exists

LA's free public courts are hard to discover. Search results skew toward paid and private facilities, and weekday-evening availability is unpredictable. OpenCourt closes that gap with curated data plus a crowdsourced live layer.

The long-term vision is a multi-city platform. **OpenCourt LA** is v1.

---

## Features (v1.0.0)

- **20 curated court sites** across LA County (Santa Monica, Westside, Hollywood, Mid-City, Valley, South Bay, Antelope Valley)
- **Google Maps with auto-fit bounds** — the first frame shows the full LA footprint, including the northernmost Antelope Valley site
- **Three-tier access model:** Free / Low-cost public (< $20/hr) / Private-members
- **Heuristic availability scoring** — 🟢 Likely Open / 🟡 Toss-Up / 🔴 Likely Full, computed from court count, demand tier, time of day, day of week
- **Crowdsourced live reports** — three-button interface (Open / Mixed / Full), persisted to `localStorage` in v1 (Phase 2 will move to Supabase)
- **Seasonal Grand Slam theming** — palette automatically retunes for the next major (Roland-Garros clay, Wimbledon purple, US Open blue, Australian Open teal)
- **Filters** — sport, access tier, likely status
- **No build step** — plain HTML/CSS/JS deployable to GitHub Pages

---

## Project structure

```
opencourt-la/
├── index.html                   # Entry point
├── assets/
│   ├── css/styles.css           # All styles + seasonal theme variables
│   ├── js/app.js                # Application logic
│   ├── data/
│   │   ├── courts.json          # Court database (Phase 2 will move to Supabase)
│   │   └── grand-slams.json     # Grand Slam calendar driving the theme engine
│   └── img/favicon.svg          # Favicon
├── docs/
│   ├── REQUIREMENTS.md          # Consolidated SRS — the north star
│   ├── PROJECT_BRIEF.md         # Vision and phases
│   ├── SETUP.md                 # Local dev + deploy steps
│   ├── RESEARCH_NOTES.md        # Background research
│   └── ROADMAP.md               # Phase 1/2/3 plan
├── .github/workflows/pages.yml  # Auto-deploy to GitHub Pages
├── push-to-github.sh            # One-shot init + push + enable Pages (needs gh CLI)
├── .gitignore
├── LICENSE
└── README.md
```

---

## Quick start

```bash
# Clone
git clone https://github.com/YOUR_USERNAME/opencourt-la.git
cd opencourt-la

# Open index.html in a browser — but most browsers block fetch() on file:// URLs,
# so run a local server instead:
python3 -m http.server 8000
# then visit http://localhost:8000
```

You'll see a yellow banner prompting you to add your Google Maps API key. See `docs/SETUP.md` for the full provisioning steps including referrer restrictions.

---

## Tech stack

- **Frontend:** Plain HTML / CSS / JavaScript (no framework, no build step)
- **Map:** Google Maps JavaScript API (with `AdvancedMarkerElement`)
- **Fonts:** Fraunces (display), Inter Tight (UI), JetBrains Mono (data)
- **Data:** JSON files (Phase 1) → Supabase Postgres (Phase 2 planned)
- **Hosting:** GitHub Pages
- **Deploy:** GitHub Actions (`.github/workflows/pages.yml`)

---

## Roadmap

- **Phase 1 (current):** Personal MVP with curated data and heuristic scoring
- **Phase 2:** Migrate `courts.json` to Supabase, persist crowdsourced reports backend-side, expand to ~50 courts
- **Phase 3:** Pickup-game matchmaking, shareable via group chat or public board

See `docs/ROADMAP.md` for the full plan.

---

## Contributing

OpenCourt is in early personal-MVP territory. If you're a player who's noticed a missing court or incorrect info, open an issue with the location's name, address, and a brief note about access.

---

## License

MIT — see `LICENSE`.
