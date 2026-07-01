const CACHE_NAME = 'morning-dew-v40';
const ASSETS = ['./', './index.html', './manifest.json', './offline.html', './icons/icon-192.png', './icons/icon-512.png'];

self.addEventListener('install', (event) => {
  event.waitUntil(
    caches.open(CACHE_NAME)
      .then((cache) => cache.addAll(ASSETS))
      .then(() => self.skipWaiting())
  );
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((key) => key !== CACHE_NAME).map((key) => caches.delete(key))))
      .then(() => self.clients.claim())
  );
});

// Network-first for same-origin requests; /api/* is never cached (live data).
// Falls back to cache, then to offline.html for navigations when fully offline.
self.addEventListener('fetch', (event) => {
  const url = new URL(event.request.url);
  if (url.origin !== self.location.origin) return;
  if (url.pathname.startsWith('/api/')) return; // always go to network, never cache live data

  event.respondWith(
    fetch(event.request)
      .then((response) => {
        const copy = response.clone();
        caches.open(CACHE_NAME).then((cache) => cache.put(event.request, copy));
        return response;
      })
      .catch(() =>
        caches.match(event.request).then((cached) => {
          if (cached) return cached;
          if (event.request.mode === 'navigate') return caches.match('./offline.html');
          return Response.error();
        })
      )
  );
});

// ---- Web Push: the morning brief notification ----
self.addEventListener('push', (event) => {
  let data = { title: 'Morning Dew', body: '' };
  try { data = event.data ? event.data.json() : data; } catch { data.body = event.data ? event.data.text() : ''; }
  event.waitUntil(
    self.registration.showNotification(data.title || 'Morning Dew', {
      body: data.body || '',
      icon: './icons/icon-192.png',
      badge: './icons/icon-192.png',
      tag: 'morning-brief',
      data: { url: './' },
    })
  );
});

self.addEventListener('notificationclick', (event) => {
  event.notification.close();
  event.waitUntil((async () => {
    const all = await self.clients.matchAll({ type: 'window', includeUncontrolled: true });
    for (const c of all) { if ('focus' in c) return c.focus(); }
    if (self.clients.openWindow) return self.clients.openWindow('./');
  })());
});
