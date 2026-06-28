# Weather

A tiny installable web app showing live local weather via
[Open-Meteo](https://open-meteo.com) (no API key needed), using its
`best_match` model selection to pull from the highest-resolution national
weather model available for your location (e.g. ECMWF, ICON, GFS).

## Run locally

```bash
cd weather-timer-app
python3 -m http.server 8080
# open http://localhost:8080 on your phone (same Wi-Fi) or laptop
```

## Get a real URL + install on iPhone

The simplest free host is **GitHub Pages**:

1. Merge this folder into `main` if it isn't there already — GitHub Pages'
   "Deploy from a branch" source can only be the repo root (`/`) or `/docs`,
   never an arbitrary subfolder like `/weather-timer-app`.
2. In the repo on GitHub: **Settings → Pages**.
3. Under "Build and deployment", set **Source: Deploy from a branch**, pick
   `main`, and pick `/` (root) as the folder.
4. Save — because this app's `index.html` lives directly in
   `weather-timer-app/` at the repo root, GitHub serves it at
   `https://<your-username>.github.io/<repo>/weather-timer-app/`.

Then on the iPhone:

1. Open that URL in **Safari** (must be Safari, not Chrome, for "Add to Home
   Screen" to install it as a standalone app).
2. Tap the **Share** icon → **Add to Home Screen**.
3. It installs with its own icon and opens full-screen, no browser chrome.

Any other static host works too (Netlify, Vercel, Cloudflare Pages) — just
point it at this folder and it needs no build step or server-side code.

## Notes

- Weather and location both require the user to grant the browser's location
  permission; iOS will prompt on first load.
