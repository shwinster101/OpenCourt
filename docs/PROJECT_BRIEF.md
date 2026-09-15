# OpenCourt LA — Project Brief

## Mission

> Turning "where can I play?" into "I'm on my way."

## Problem

Recreational tennis and pickleball players in Los Angeles County face a real discovery gap:
- Free public courts are hard to find — search results skew heavily toward paid and private facilities
- Availability is unpredictable, especially during weekday evenings
- No existing tool unifies free, low-cost, and members-only courts in one map view
- LA is ~92% below national averages for dedicated pickleball court density, indicating strong unmet demand

## Three-tier access model

OpenCourt categorizes every facility into one of three tiers:

| Tier | Definition |
|------|------------|
| **Free** | Free public courts open to all |
| **Low-cost public** | Public facilities under $20/hr — typically City of LA reservable courts |
| **Private-members** | Members-only or residents-only facilities, listed for completeness |

## Three-phase roadmap

### Phase 1 — Personal MVP *(current)*
- Curated dataset of ~20 LA County court sites
- Static HTML + JS deployment on GitHub Pages
- Google Maps with auto-fit bounds
- Heuristic availability scoring (no real-time data)
- Three-tier filtering
- Crowdsourced live reports persisted in localStorage
- Seasonal Grand Slam theming
- Goal: useful for me and my roommate this week

### Phase 2 — Public beta
- Expand to ~50 public court facilities
- Migrate `courts.json` to Supabase Postgres backend
- Persist live reports server-side with proper rate limiting
- Add `metro` field already present in schema (multi-city architecture seed)
- Anonymous reports with device-fingerprint rate limiting
- Goal: real users, real signal, real data

### Phase 3 — Matchmaking
- Pickup-game matchmaking layer
- Shareable to group chats or a public board
- Lightweight player identity (nickname + skill tag)
- Goal: not just "find courts" but "find people on courts"

## Forward-compatible schema

Every court record in `courts.json` already carries the Phase 2 fields:

```json
{
  "id": "...",
  "metro": "LA",
  "name": "...",
  "neighborhood": "...",
  "lat": 0, "lng": 0,
  "sports": ["tennis", "pickleball"],
  "tier": "free | low-cost | private",
  "court_count": 0,
  "notes": "...",
  "demand_tier": "low | medium | high",
  "live_reports": [],
  "last_reported_availability": null
}
```

This means the migration to a database in Phase 2 doesn't require schema changes — only a transport swap from `fetch('courts.json')` to `fetch(supabaseEndpoint)`.

## Key principles

- **Forward-compatible schema from day one** — avoid costly migrations later
- **Crowdsourcing requires < 5-second reporting friction** — three-button UI, no forms
- **Static where possible, backend where necessary** — defer infra costs until Phase 2
- **Honest about uncertainty** — when we don't have a live signal, say "heuristic estimate", not "currently available"
