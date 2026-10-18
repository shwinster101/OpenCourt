# 2026-10-18 — The repository and the link are PickUp (v1.3.2)

Owner: "Can we change the repo and link to be PickUp?" — then renamed it: `shwinster101/PickUp`,
site https://shwinster101.github.io/PickUp/ (old `/OpenCourt/` → 404; checked).

Changed here: every `github.io/OpenCourt` and `shwinster101/OpenCourt` reference outside `working/`
(provisioner `PAGES_URL`, `test/provision/run.sh`, `test/e2e/README.md`, README incl. the placeholder
quick-start, FOUNDATION, MIGRATION, CLAUDE.md, the staged legacy-repo pointers). Dated notes keep the old
URL as history. Not changed: the Supabase redirect allow list (owner, dashboard: Authentication → URL
Configuration → add the new URL) — the provisioner's auth step would also patch it on a future run; the
Cloudflare Pages project name; the Maps key (root wildcard already covers the new path).

Verification: gate, provisioner mock suite (asserts the new Pages URL in the mock's allow list), live 200.
