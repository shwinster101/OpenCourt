# OpenCourt LA — Roadmap

## Phase 1 — Personal MVP ✅ (shipped May 2026; v1.0.1 pushed to GitHub Sept 2026)

- [x] 20 curated court sites across LA County
- [x] Google Maps with auto-fit bounds
- [x] Three-tier access filtering (Free / Low-cost / Private)
- [x] Tennis + pickleball sport filtering
- [x] Heuristic availability scoring
- [x] Three-button live report UI (localStorage-backed)
- [x] Seasonal Grand Slam theming
- [x] Forward-compatible schema (`metro`, `live_reports`, `last_reported_availability`)
- [x] GitHub Pages deployment with Actions

## Phase 1.5 — Polish before going wider (next 2 weeks)

- [ ] Add Google Maps API key with referrer restrictions  ← **blocker, still open as of Sept 2026**
- [ ] Verify all 20 court coordinates against Google Maps ground truth
- [ ] Dogfood with roommate for a full week of weekday-evening play
- [ ] Capture screenshots of all four seasonal themes for the README

## Phase 2 — Public beta with crowdsourced data backend

Five high-leverage moves in order:

1. **Migrate `courts.json` to Supabase Postgres** — already designed as the v1 data layer; this is a schema-equivalent copy. Frontend change is one fetch URL.
2. **Add `live_reports` table with a write endpoint** — Supabase REST + RLS policies. The localStorage code in `app.js` becomes a `fetch()` call.
3. **Compute `last_reported_availability` server-side** — Postgres view with recency-weighted aggregation, decaying to null after 2 hours.
4. **Rate-limit writes** — Supabase RLS policy: one report per court per device fingerprint per 15 minutes.
5. **Expand court coverage to ~50 sites** — add Pasadena, South Bay, East LA, Long Beach.

Explicit non-goals for Phase 2:
- No user accounts (anonymous reports with device fingerprinting)
- No moderation queue (trust the rate limit + recency decay)
- No admin panel (edits via direct DB access for now)

## Phase 3 — Matchmaking

- [ ] Lightweight player profiles (nickname + skill self-rating)
- [ ] "I'm here at X, looking for a 4th" pickup signals
- [ ] Shareable to group chats (deep links)
- [ ] Public board view filtered by neighborhood + skill range
- [ ] Push notifications opt-in for matching signals nearby

## Phase 4 — Multi-city

- [ ] City picker on landing page (every record already has `metro`)
- [ ] OpenCourt SF / NYC / SD launches with local datasets
- [ ] Unified backend with metro-scoped queries

## Known issues / tech debt

- Coordinates are approximate from general LA knowledge — should verify against ground truth before claiming v1.0 final
- Theme calendar is hardcoded for 2026; needs annual update
- localStorage reports don't sync across devices (resolved in Phase 2)
- Map style is hardcoded in JS; could move to a theme-aware style for full slam coherence
