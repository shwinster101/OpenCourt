/* ============================================================
   OPENCOURT — runtime configuration (client-side values only)
   ============================================================
   The Supabase anon key is a public, publishable credential: row-level
   security in the database is the boundary (docs/MIGRATION.md §3).
   Service-role keys never belong here or anywhere in this repository.

   Empty SUPABASE values mean "no backend": the page serves
   assets/data/courts.json, keeps reports on this device, says so in the
   sidebar, and hides the pickups features.
   ============================================================ */
window.OPENCOURT_CONFIG = {
  SUPABASE_URL: '',        // e.g. 'https://abcd1234.supabase.co'
  SUPABASE_ANON_KEY: '',   // the project's anon / publishable key
  GOOGLE_MAP_ID: '',       // optional: a Map ID enables Advanced Markers (Google then ignores the JSON map style)
  METRO: 'LA'
};
