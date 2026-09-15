# Research Notes

Background research compiled while scoping OpenCourt LA.

## LA court density vs. national averages

- LA is significantly below the national average for dedicated pickleball court density
- Estimates suggest roughly 92% below average per capita
- Search results for "tennis courts near me" or "pickleball courts LA" heavily favor paid/private facilities
- This creates a real discovery gap for free public options — the core problem OpenCourt addresses

## Sources consulted

- MyTennisLessons — LA court directory
- PlayTennisLA — City of LA reservable courts
- Hollywood Reporter — coverage of LA's pickleball boom
- SFIA (Sports & Fitness Industry Association) — pickleball participation data
- Pickleheads — facility directory
- USA Pickleball — court count statistics

## Specific court corrections logged

- **Westchester Tennis** (not Westminster — that's a different city)
- **Pearl Apartments + Mariners Village MDR** combined into single private entry (geographically adjacent, both Marina del Rey)
- **El Segundo Parks & Rec** added as a South Bay anchor
- **Sgt. Steve Owen Memorial Park** added as the Antelope Valley representative
- **Mar Vista** noted as resurfaced Summer 2024 with new pickleball lines

## Design / UX research

- Crowdsourcing only works if reporting friction is under ~5 seconds — drives the three-button "Open / Mixed / Full" choice over any form-based approach
- Three-tier color coding (green/amber/red) maps to existing player intuition without explanation
- Map-first UX matches mobile reality: most usage will be "I'm en route, where should I go?" not "let me browse all the courts"

## Tooling decisions

- **Google Maps over Leaflet** — chosen for marker richness, future Places integration, and matching the user's stated stack
- **Plain HTML/CSS/JS over a framework** — Phase 1 doesn't need it, and avoiding a build step means GitHub Pages can serve the repo as-is
- **localStorage for v1 reports** — protocol-compatible with Phase 2 Supabase migration, zero infra cost
- **JSON data files over inline JS** — Phase 2-compatible immediately; `courts.json` swaps to a backend endpoint with no app changes
- **Fraunces + Inter Tight + JetBrains Mono** — editorial sport-atlas aesthetic; avoids generic SaaS-dashboard look

## Mac-specific note

VS Code, not TextEdit. TextEdit on macOS silently converts plain-text files to RTF when you save, which corrupts HTML and JSON files. This has bitten the project once already.
