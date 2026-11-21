const CACHE_NAME = "proq-small-assets-v1";
const APP_SHELL = [
    "./",
    "index.html",
    "styles.css?v=podium-score-fix-1",
    "script.js?v=podium-score-fix-1",
    "assets/audio/click.mp3",
    "assets/audio/correct.mp3",
    "assets/audio/incorrect.mp3",
    "assets/aset%20pendukung/selamat_datang_ProQ.png",
    "assets/aset%20pendukung/karakter_cewe.png",
    "assets/aset%20pendukung/karakter_cowo.png",
    "assets/aset%20pendukung/judul.png",
    "assets/aset%20pendukung/input_nama.png",
    "assets/ui/settings.png",
    "assets/ui/developers.png",
    "assets/ui/sound-on.png",
    "assets/ui/sound-off.png",
    "assets/ui/back.png",
    "assets/ui/next.png"
];

self.addEventListener("install", (event) => {
    event.waitUntil(caches.open(CACHE_NAME).then((cache) => cache.addAll(APP_SHELL)));
    self.skipWaiting();
});

self.addEventListener("activate", (event) => {
    event.waitUntil(caches.keys().then((names) => Promise.all(
        names.filter((name) => name !== CACHE_NAME).map((name) => caches.delete(name))
    )));
    self.clients.claim();
});

self.addEventListener("fetch", (event) => {
    const request = event.request;
    const url = new URL(request.url);
    if (request.method !== "GET" || url.origin !== self.location.origin || request.destination === "video") return;

    event.respondWith(caches.match(request).then((cached) => {
        const network = fetch(request).then((response) => {
            if (response.ok && ["image", "audio", "script", "style"].includes(request.destination)) {
                caches.open(CACHE_NAME).then((cache) => cache.put(request, response.clone()));
            }
            return response;
        });
        return cached || network;
    }));
});
