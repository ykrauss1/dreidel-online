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

const CACHE = 'dreidel-v127';
const FALLBACK = './index.html';
// Each picture is listed once, as .webp. The .png / .jpg twins exist only for a browser that cannot
// show webp; precaching both made every install download the pictures twice (about 1.2 MB extra).
// A browser that does need a twin still gets it from the network and it is kept from then on.
const STATIC = [
  './index.html', './manifest.json', './icon-192.png', './icon-512.png', './apple-touch-icon.png',
  './dreidel.webp', './d3-face.webp', './d3-tip.webp', './d3-handle.webp', './bg-table.webp',
  './bg-table-portrait.webp', './coin.webp', './pile.webp', './trivia.json',
  './dancer.webp', './dancer_big.webp', './hasid_pose1.webp', './hasid_pose2.webp', './hasid_pose3.webp', './hasid_side.webp', './hasid_back.webp', './dancer_boy.webp', './dancer_boy_a.webp', './dancer_boy_c.webp', './dancer_girl_a.webp', './dancer_girl_b.webp', './dancer_grandpa_a.webp', './dancer_grandpa_b.webp', './dancer_boy_side.webp', './dancer_boy_back.webp', './dancer_girl_side.webp', './dancer_girl_back.webp', './dancer_grandpa_side.webp', './dancer_grandpa_back.webp', './dancer_grandma_side.webp', './dancer_grandma_back.webp', './dancer_girl.webp', './dancer_grandpa.webp', './dancer_grandma.webp', './bg-table-nod.webp', './bg-table-portrait-nod.webp', './dancers_old.webp', './cstack1.webp', './cstack2.webp', './cstack3.webp', './cstack4.webp', './cstack5.webp', './cstack6.webp', './cstack7.webp', './cstack8.webp', './cstack9.webp', './cstack10.webp', './cstack11.webp', './cstack12.webp',
  './trivia-editor.html'
];

// The recorded sounds (about 1 MB). They used to be kept only after each one had been played once, so a
// local game opened with no connection was silent. When a sound is added to sounds/, add it here too;
// one left out still works online and is kept after its first play.
const SOUNDS = [
  './sounds/click0.mp3', './sounds/click1.mp3', './sounds/click2.mp3', './sounds/click3.mp3',
  './sounds/click4.mp3', './sounds/coins0.mp3', './sounds/coins1.mp3', './sounds/fall0.mp3',
  './sounds/fall1.mp3', './sounds/fall2.mp3', './sounds/fall3.mp3', './sounds/fall4.mp3',
  './sounds/gimel0.mp3', './sounds/gimel1.mp3', './sounds/gimel2.mp3', './sounds/gimel3.mp3',
  './sounds/gimel4.mp3', './sounds/he0.mp3', './sounds/he1.mp3', './sounds/he2.mp3',
  './sounds/he3.mp3', './sounds/he4.mp3', './sounds/he5.mp3', './sounds/he6.mp3',
  './sounds/he7.mp3', './sounds/he8.mp3', './sounds/nun0.mp3', './sounds/nun1.mp3',
  './sounds/nun2.mp3', './sounds/nun3.mp3', './sounds/nun4.mp3', './sounds/nun5.mp3',
  './sounds/nun6.mp3', './sounds/nun7.mp3', './sounds/out0.mp3', './sounds/out1.mp3',
  './sounds/out2.mp3', './sounds/pe0.mp3', './sounds/pe1.mp3', './sounds/pe2.mp3',
  './sounds/pe3.mp3', './sounds/pe4.mp3', './sounds/pe5.mp3', './sounds/pe6.mp3',
  './sounds/pe7.mp3', './sounds/pe8.mp3', './sounds/sweep0.mp3', './sounds/sweep1.mp3',
  './sounds/tick0.mp3', './sounds/tick1.mp3', './sounds/tick2.mp3', './sounds/win0.mp3',
  './sounds/yi_gimel1_bobe.mp3', './sounds/yi_gimel1_zeyde.mp3', './sounds/yi_gimel2_bobe.mp3',
  './sounds/yi_gimel2_zeyde.mp3', './sounds/yi_he1_bobe.mp3', './sounds/yi_he1_zeyde.mp3',
  './sounds/yi_he2_bobe.mp3', './sounds/yi_he2_zeyde.mp3', './sounds/yi_nun1_bobe.mp3',
  './sounds/yi_nun1_zeyde.mp3', './sounds/yi_nun2_bobe.mp3', './sounds/yi_nun2_zeyde.mp3',
  './sounds/yi_pay1_bobe.mp3', './sounds/yi_pay1_zeyde.mp3', './sounds/yi_pay2_bobe.mp3',
  './sounds/yi_pay2_zeyde.mp3'
];

// Third-party static assets that are safe to keep (fonts + the supabase-js library)
const CACHEABLE_HOSTS = ['fonts.googleapis.com', 'fonts.gstatic.com', 'cdn.jsdelivr.net'];

self.addEventListener('install', function (e) {
  self.skipWaiting();
  e.waitUntil(
    caches.open(CACHE).then(function (c) {
      // one by one — a single missing file must not cancel the rest
      return Promise.all(STATIC.concat(SOUNDS).map(function (u) { return c.add(u).catch(function () {}); }));
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
    // Only the game itself may be stored as the offline copy. Every page opened used to be stored
    // under index.html, so after a visit to the trivia editor, a game opened with no connection
    // showed the editor instead.
    const scopePath = new URL(self.registration.scope).pathname;
    const isGame = url.origin === self.location.origin &&
        (url.pathname === scopePath || url.pathname === scopePath + 'index.html');
    e.respondWith(
      fetch(req)
        .then(function (res) {
          if (isGame && res && res.ok) {
            const copy = res.clone();
            caches.open(CACHE).then(function (c) { c.put(FALLBACK, copy); }).catch(function () {});
          }
          return res;
        })
        .catch(function () {
          // the page that was asked for if we hold it (the trivia editor is precached), else the game
          return caches.match(req, { ignoreSearch: true }).then(function (own) {
            return own || caches.match(FALLBACK);
          }).then(function (hit) {
            return hit || new Response('<h1 dir="rtl">אין חיבור</h1>', { headers: { 'Content-Type': 'text/html; charset=utf-8' } });
          });
        })
    );
    return;
  }

  // The questions: always try the network first, so a newly uploaded trivia.json shows at once.
  // (put() and match() each carried a stray './trivia-editor.html' argument here; both threw, so the
  // kept copy was never refreshed and, with no connection, the questions did not load at all.)
  if (url.origin === self.location.origin && /trivia\.json$/.test(url.pathname)) {
    e.respondWith(
      fetch(req).then(function (res) {
        if (res && res.ok) { const copy = res.clone(); caches.open(CACHE).then(function (c) { c.put('./trivia.json', copy); }).catch(function () {}); }
        return res;
      }).catch(function () { return caches.match('./trivia.json'); })
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
