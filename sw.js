/* Dreidel service worker
 *
 * Same approach as CerviniaLive:
 *  - index.html is NETWORK FIRST. A new version is picked up on the next open;
 *    the cached copy is only a fallback when there is no connection.
 *  - Icons, fonts and the Supabase library are cached (stale-while-revalidate),
 *    so a LOCAL game opens and looks right even with no connection at all.
 *  - Live traffic (Supabase Realtime / API) is never cached.
 *
 * When changing this file, bump CACHE so old caches are cleaned up.
 */

const CACHE = 'dreidel-v54';
const FALLBACK = './index.html';
const STATIC = ['./index.html', './manifest.json', './icon-192.png', './icon-512.png', './apple-touch-icon.png', './dreidel.webp', './dreidel.png', './d3-face.webp', './d3-face.png', './d3-tip.webp', './d3-tip.png', './d3-handle.webp', './d3-handle.png', './bg-table.webp', './bg-table.jpg', './bg-table-portrait.webp', './bg-table-portrait.jpg', './coin.webp', './coin.png', './pile.webp', './pile.png', './trivia.json', './trivia-editor.html'];

// Third-party static assets that are safe to keep (fonts + the supabase-js library)
const CACHEABLE_HOSTS = ['fonts.googleapis.com', 'fonts.gstatic.com', 'cdn.jsdelivr.net'];

self.addEventListener('install', function (e) {
  self.skipWaiting();
  e.waitUntil(
    caches.open(CACHE).then(function (c) {
      // one by one — a single missing file must not cancel the rest
      return Promise.all(STATIC.map(function (u) { return c.add(u).catch(function () {}); }));
    })
  );
});

self.addEventListener('activate', function (e) {
  e.waitUntil(
    caches.keys()
      .then(function (ks) { return Promise.all(ks.filter(function (k) { return k !== CACHE; }).map(function (k) { return caches.delete(k); })); })
      .then(function () { return self.clients.claim(); })
  );
});

function staleWhileRevalidate(req) {
  return caches.open(CACHE).then(function (c) {
    return c.match(req).then(function (hit) {
      const net = fetch(req).then(function (res) {
        if (res && (res.ok || res.type === 'opaque')) c.put(req, res.clone()).catch(function () {});
        return res;
      }).catch(function () { return hit; });
      return hit || net;
    });
  });
}

self.addEventListener('fetch', function (e) {
  const req = e.request;
  if (req.method !== 'GET') return;

  let url = null;
  try { url = new URL(req.url); } catch (err) { return; }

  // Page navigations: network first, cached page as fallback
  if (req.mode === 'navigate') {
    e.respondWith(
      fetch(req)
        .then(function (res) {
          if (res && res.ok) {
            const copy = res.clone();
            caches.open(CACHE).then(function (c) { c.put(FALLBACK, copy); }).catch(function () {});
          }
          return res;
        })
        .catch(function () {
          return caches.match(FALLBACK).then(function (hit) {
            return hit || new Response('<h1 dir="rtl">אין חיבור</h1>', { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
          });
        })
    );
    return;
  }

  // The questions: always try the network first, so a newly uploaded trivia.json shows at once
  if (url.origin === self.location.origin && /trivia\.json$/.test(url.pathname)) {
    e.respondWith(
      fetch(req).then(function (res) {
        if (res && res.ok) { const copy = res.clone(); caches.open(CACHE).then(function (c) { c.put('./trivia.json', './trivia-editor.html', copy); }).catch(function () {}); }
        return res;
      }).catch(function () { return caches.match('./trivia.json', './trivia-editor.html'); })
    );
    return;
  }

  // Own static files (icons, manifest) and fonts / library
  const ownStatic = url.origin === self.location.origin && /\.(png|webp|jpg|mp3|ico|svg|json)$/.test(url.pathname);
  if (ownStatic || CACHEABLE_HOSTS.indexOf(url.hostname) !== -1) {
    e.respondWith(staleWhileRevalidate(req));
  }
  // everything else (Supabase etc.) goes straight to the network
});
