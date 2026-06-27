# Weather & Timer

A tiny installable web app: live local weather (via [Open-Meteo](https://open-meteo.com),
no API key needed) plus a 30-minute timer with sound/vibration alert.

## Run locally

```bash
cd weather-timer-app
python3 -m http.server 8080
# open http://localhost:8080 on your phone (same Wi-Fi) or laptop
```

## Get a real URL + install on iPhone

The simplest free host is **GitHub Pages**:

1. In the repo on GitHub: **Settings → Pages**.
2. Under "Build and deployment", set **Source: Deploy from a branch**.
3. Pick this branch and `/weather-timer-app` as the folder (or merge this
   folder into `main` first, then point Pages at `main` + `/weather-timer-app`).
4. Save — GitHub gives you a URL like
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
- The 30-minute timer keeps running while the tab/app is in the foreground.
  iOS Safari (and installed PWAs) suspends JS timers in the background, so the
  countdown is accurate while you're looking at it but should not be relied on
  as a background alarm.
