# Benchmark Nginx+PHP-FPM vs FrankenPHP (v2)

Tiga varian diuji, **satu per sesi**, dengan anggaran resource yang sama:

| Target | Port | Keterangan |
|---|---|---|
| `nginx` | 9001 | Nginx + PHP-FPM (`pm=static`, jumlah child di `.env`) |
| `franken-classic` | 9002 | FrankenPHP tanpa worker (jumlah thread di `.env`) |
| `franken-worker` | 9003 | FrankenPHP worker mode (jumlah worker di `.env`) |

`.env` bawaan = preset **1 vCPU / 1 GB** (8 worker). Untuk server besar: `cp env.large.example .env`.

## Server kecil (1 vCPU / 1 GB) + k6 dari komputer lokal
**Di server (sekali):**
```bash
unzip nginx-vs-franken-v2.zip && cd nginx-vs-franken-v2
chmod +x run-benchmark.sh run-remote.sh server/*.sh
sudo ./server/server-setup.sh      # buat swap 2 GB (wajib di 1 GB RAM)
./server/server-ctl.sh build-all   # build image sekali (beberapa menit di 1 vCPU)
```
Pastikan port **9001-9003** bisa dijangkau dari komputer Anda (firewall panel VPS; port yang dipublish Docker
melewati `ufw`). Database tidak dipublish keluar. Setelah selesai, stack dimatikan otomatis.

**Di komputer lokal** (Linux/macOS/WSL/Git Bash; butuh `ssh`, `scp`, `curl`, dan k6 atau Docker):
```bash
./run-remote.sh -H root@IP_SERVER -s smoke -r 1                 # cek cepat
./run-remote.sh -H root@IP_SERVER -s ramp -a health -r 3        # baseline jaringan (tanpa kerja server)
./run-remote.sh -H root@IP_SERVER -s ramp -a mixed -r 3         # uji utama
```
Skrip ini mengatur server lewat SSH, menjalankan k6 di komputer Anda, lalu mengambil data `docker stats` dan membuat `results/summary.md`.

**Hal yang perlu dipahami pada setup ini:**
- Latensi yang diukur = jaringan (RTT + bandwidth Anda) + server. Bandingkan **antar varian pada kondisi jaringan yang sama**
  (itu sebabnya urutan target dibalik tiap ulangan), dan jalankan `-a health` sebagai pembanding "lantai jaringan".
- Hanya 1 core dipakai bersama oleh DB, PHP, web server, dan `docker stats`. Hasil adalah perbandingan **di bawah kondisi sempit**,
  bukan angka mutlak. Beban default sudah diturunkan (maks 200 VU / 400 req/s); naikkan dengan `-k "-e RAMP_LEVELS=..."`.
- Pantau `Restart`/`OOM` di ringkasan: di 1 GB, OOM kill adalah hasil uji ketangguhan yang valid, bukan kegagalan skrip.
- Jangan jalankan sambil ada proses lain di server (mis. `apt upgrade` yang menggantung, lihat percakapan sebelumnya).

## Menjalankan semuanya di satu mesin (opsional)
Prasyarat: Docker + Compose v2, `curl`, `python3`; k6 opsional (fallback image `grafana/k6`).
k6 di mesin yang sama ikut berebut CPU, jadi sebutkan itu di laporan; lebih baik pakai `run-remote.sh` di atas.
```bash
chmod +x run-benchmark.sh
./run-benchmark.sh                                  # ramp, mixed, 3x ulang, semua target
./run-benchmark.sh -s spike -a db -r 5              # uji lonjakan, endpoint DB
./run-benchmark.sh -s arrival -a mixed              # open model (req/s konstan)
./run-benchmark.sh -s soak -r 1 -k "-e SOAK_DURATION=60m"   # uji lama, cari memory leak
./run-benchmark.sh -s smoke -r 1                    # cek cepat semuanya jalan
```
Hasil: `results/summary.md` (ringkasan) dan `results/raw/` (summary k6, `docker stats` per detik, restart/OOM).

## Skenario k6 (`k6/bench.js`)
| SCENARIO | Tujuan |
|---|---|
| `smoke` | 5 VU, 20 dtk, sekadar memastikan semuanya hidup |
| `ramp` | 10→25→50→100→200 VU bertahap, cari titik patah |
| `spike` | 5 VU → lonjakan 200 VU → kembali 5; lihat pemulihan |
| `soak` | 30 VU selama 30 menit; pantau memori & stabilitas |
| `arrival` | laju request tetap (20→400 req/s), tidak bergantung kecepatan server; perhatikan `dropped_iterations` |

Endpoint (`ACTION`): `hello`, `cpu` (fib 25), `io`, `db` (SELECT 50 baris), `dbwrite` (INSERT),
`slow` (usleep 100 ms), `mixed` (40/25/10/10/10/5%). `?action=stats` menampilkan memori & jumlah request per proses.
Setiap respons divalidasi isinya, bukan hanya status 200. Warm-up 15 dtk tidak dihitung di hasil.

## Yang diperbaiki dibanding versi awal
- **Adil:** jumlah worker sama, opcache sama (`validate_timestamps=0`), batas CPU/memori sama, versi image di-pin di `.env`,
  kode di-`COPY` ke image (tanpa bind mount), keepalive Nginx→FPM aktif, DB di-reset tiap run, urutan target dibalik di ulangan genap.
- **Tiga varian:** FrankenPHP classic ditambahkan agar efek worker mode terpisah dari efek server.
- **Tangguh:** skenario ramp/spike/soak/arrival, threshold otomatis, `docker stats` + restart/OOM direkam.
- **Bug laten dibenahi:** reconnect DB otomatis (worker mode sebelumnya tidak pulih bila MySQL putus), exception tidak mematikan worker, `include` pakai `__DIR__`.
- **Tidak ada `connection refused` palsu:** healthcheck DB, `depends_on: service_healthy`, `setup()` k6 menunggu target siap.

## Catatan penting
- `innodb_flush_log_at_trx_commit=2` dipakai agar `dbwrite` tidak sepenuhnya ditentukan fsync disk (berlaku sama untuk semua varian).
- Stack Nginx memakai 2 container (0,5 + 1,5 CPU) vs FrankenPHP 1 container (2 CPU); atur di `.env` bila ingin anggaran lain.
- Cek tag image dengan `docker pull dunglas/frankenphp:1-php8.3` dan sesuaikan `.env` jika perlu; untuk reprodusibilitas penuh pin ke digest.
- Laporkan median + rentang dari beberapa ulangan; satu kali jalan tidak cukup.
