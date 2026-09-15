# Setup & Deploy

End-to-end steps for getting OpenCourt LA running locally and live on GitHub Pages.

---

## 1. Prerequisites

- A GitHub account
- A Google account (for the Maps API)
- Git installed locally
- A modern browser
- VS Code recommended (avoid TextEdit on macOS — it silently converts files to RTF, which will break HTML/JSON)

---

## 2. Local development

```bash
# Clone the repo
git clone https://github.com/YOUR_USERNAME/opencourt-la.git
cd opencourt-la
```

The app uses `fetch()` to load `courts.json` and `grand-slams.json`. Most browsers block `fetch()` against `file://` URLs for security, so you'll need a tiny local web server:

```bash
# Python 3 (already installed on macOS)
python3 -m http.server 8000

# OR — Node, if you have it
npx serve .

# Visit
open http://localhost:8000
```

You'll see a yellow banner at the top of the map saying the Google Maps API key is missing. That's expected — see the next section.

---

## 3. Provisioning the Google Maps API key

This is the one piece of configuration that needs to be done manually.

### a. Create the key

1. Go to <https://console.cloud.google.com/google/maps-apis/credentials>
2. Create a new project (or use an existing one) — e.g., "opencourt-la"
3. Click **Create Credentials → API key**
4. Copy the key

### b. Restrict the key — DO THIS BEFORE PUSHING TO GITHUB

A client-side Maps key is safe **only if it's restricted**. Without restrictions, anyone can copy it from your live page and rack up charges on your account.

In the credentials page, click the key you just created. Set:

- **Application restrictions → HTTP referrers (websites)**
- Add referrers:
  - `http://localhost:8000/*` (local dev)
  - `https://YOUR_USERNAME.github.io/*` (GitHub Pages default domain)
  - `https://your-custom-domain.com/*` (only if you've set up a CNAME)
- **API restrictions → Restrict key → Maps JavaScript API** (only)

Save.

### c. Wire the key into the page

Open `index.html` and find this line near the bottom:

```html
<script async defer
  src="https://maps.googleapis.com/maps/api/js?key=YOUR_GOOGLE_MAPS_API_KEY&libraries=marker&callback=initMap&loading=async">
</script>
```

Replace `YOUR_GOOGLE_MAPS_API_KEY` with your actual key.

> ⚠️ Because this is a static site with no build step in v1, the key is embedded in HTML. That's fine as long as it's restricted by referrer. **Do not** commit an unrestricted key.

Reload the page. The map should appear with all 20 court markers and an auto-fit zoom level showing the full LA footprint.

---

## 4. Deploying to GitHub Pages

The repo includes a GitHub Actions workflow at `.github/workflows/pages.yml` that publishes the site automatically on every push to `main`.

### a. First-time setup

1. Push the repo to GitHub:
   ```bash
   git init
   git add .
   git commit -m "Initial OpenCourt LA v1.0"
   git branch -M main
   git remote add origin git@github.com:YOUR_USERNAME/opencourt-la.git
   git push -u origin main
   ```

2. In the GitHub repo UI:
   - Go to **Settings → Pages**
   - Under "Build and deployment", set **Source** to **GitHub Actions**

3. The workflow will run automatically on the next push. Subsequent pushes auto-deploy in ~30 seconds.

### b. Verify your secrets are not tracked

Before the first push:

```bash
git status
```

You should NOT see:
- `.env` or `.env.local`
- any file containing your raw Maps API key outside of `index.html`

Since v1 embeds the (restricted) key directly in `index.html`, that file IS tracked — and that's OK because the key is referrer-restricted. If you ever switch to a build-step setup (e.g., Next.js), move the key into `.env.local` and add a build step that injects it.

### c. Custom domain (optional)

If you want `opencourt.la` or similar instead of `username.github.io/opencourt-la`:

1. Buy the domain
2. Add a `CNAME` file at the repo root containing just the domain (e.g., `opencourt.la`)
3. Add the domain in **Settings → Pages → Custom domain**
4. Add the new domain to your Google Maps API key's referrer restrictions

---

## 5. Updating court data

In v1, court data lives in `assets/data/courts.json`. To add or edit a court:

1. Open the file in VS Code (NOT TextEdit on macOS — it will RTF-corrupt it)
2. Add or modify entries following the existing schema
3. Validate the JSON: `python3 -c "import json; json.load(open('assets/data/courts.json'))"`
4. Commit + push — the Actions workflow redeploys automatically

In Phase 2, this file moves to a Supabase Postgres table and updates happen through the database instead.

---

## 6. Updating the Grand Slam calendar

Once a year, `assets/data/grand-slams.json` needs an update for the new season's dates. The structure documents itself — each entry has `activate` (when the theme should switch), `start`, and `end` dates.

---

## 7. Troubleshooting

**Map shows "Failed to load court data"**
You're probably opening `index.html` directly via `file://`. Use the Python or Node local server above.

**Map shows the yellow API key warning**
You haven't replaced `YOUR_GOOGLE_MAPS_API_KEY` in `index.html`.

**Map loads but shows "For development purposes only" watermarks**
The Maps API key has a restriction mismatch, or billing isn't enabled on your Google Cloud project. Maps requires a billing account, but the free tier covers far more than a personal-MVP needs.

**Theme isn't changing colors**
Check that `assets/data/grand-slams.json` has valid `activate` dates and that today's date falls past the right `activate` date for the slam you expect.

**localStorage reports not persisting**
Open DevTools → Application → Local Storage → your domain. Look for `opencourt-la-reports-v1`. If it's empty, the report wasn't submitted — check the console for errors.
