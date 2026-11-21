# PMI — Petualangan Sejarah Indonesia

Aplikasi kuis sejarah Indonesia berbasis HTML, CSS, dan JavaScript tanpa dependensi npm.

## Jalankan lokal

Jangan membuka `index.html` dengan `file://`. Gunakan server lokal agar video, Service Worker, dan leaderboard bekerja.

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File start-server.ps1
```

Buka:

```text
http://127.0.0.1:8766/
```

Server menampilkan alamat IP LAN untuk perangkat lain pada Wi-Fi yang sama.

## Struktur utama

```text
index.html       Struktur layar aplikasi
styles.css       Tampilan responsif
script.js        Alur permainan, video, audio, preload bertahap
sw.js            Cache browser untuk aset kecil
server.ps1       Server lokal dan penyimpanan leaderboard
start-server.ps1 Pembuka server lokal
leaderboard.json Data leaderboard lokal
leaderboard.csv  Ekspor leaderboard lokal
assets/          Audio, gambar, UI, dan video
```

## Video produksi

Video besar memakai Git LFS. Jangan memakai URL video dari deployment Vercel karena Vercel dapat menyajikan pointer LFS, bukan MP4 asli.

Aplikasi memutar video H.264/AAC dari GitHub media endpoint:

```text
https://media.githubusercontent.com/media/Messiah606/PMI/main/assets/videos/
```

Video tetap memakai `preload="metadata"`. Aplikasi tidak mengunduh seluruh video sebelum materi dibuka.

Jika checkout lokal hanya berisi file video `133` byte, tarik object LFS:

```powershell
 git lfs pull
```

## Audio iOS dan Android

Efek suara memakai MP3 agar Safari iOS mendukungnya:

```text
assets/audio/click.mp3
assets/audio/correct.mp3
assets/audio/incorrect.mp3
```

Setiap efek mempunyai tiga pool audio. Klik cepat tidak menimpa suara yang sedang berjalan.

Setiap tombol memutar click sound. Jawaban juga memutar correct atau incorrect setelah dipilih.

Tap `START` pertama membuka izin audio Safari dan memanaskan seluruh pool audio.

## Preload bertahap

Aplikasi tidak mengunduh semua aset saat splash pertama.

1. Halaman awal memuat UI splash dan audio MP3.
2. Tap `START` membuka audio Safari.
3. Setelah nama dikirim, aplikasi memuat aset menu dan metadata Materi 1.
4. Saat Materi 1 terbuka, aplikasi memuat aset soal dan metadata Materi 2.
5. Saat Materi 2 terbuka, aplikasi memuat aset soal dan metadata Materi 3.
6. Video tidak dicache penuh.

## Cache browser

`sw.js` memakai Cache Storage untuk kunjungan berikutnya.

Dicache:

- HTML, CSS, JavaScript
- Efek audio MP3
- Splash, karakter, ikon UI, dan tombol kecil
- Gambar kecil yang telah dipakai aplikasi

Tidak dicache:

- Video
- `leaderboard.json`
- `leaderboard.csv`
- Request selain `GET`
- Resource dari domain lain

Saat mengubah daftar aset awal atau perilaku cache, naikkan `CACHE_NAME` di `sw.js`. Contoh:

```js
const CACHE_NAME = "proq-small-assets-v2";
```

Browser akan menghapus cache versi lama saat Service Worker baru aktif.

## Deployment Vercel

1. Pastikan file berikut ikut commit:

```text
index.html
styles.css
script.js
sw.js
assets/audio/click.mp3
assets/audio/correct.mp3
assets/audio/incorrect.mp3
```

2. Push branch `main` ke GitHub.
3. Tunggu Vercel deploy selesai.
4. Buka production sekali, lalu refresh sekali agar Service Worker aktif.
5. Uji tombol dan jawaban di iPhone Safari fisik.

Service Worker aktif hanya pada `https://` atau `localhost`. Tidak aktif pada `file://`.

## Pemeriksaan sebelum push

```powershell
node --check script.js
node --check sw.js
git diff --check
git status --short
```

Jangan commit file `.env`, credential, atau output build.
