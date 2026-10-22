# Benchmark Nginx+PHP-FPM vs FrankenPHP (v2)

Tiga varian diuji, **satu per sesi**, dengan anggaran resource yang sama:

| Target | Port | Keterangan |
|---|---|---|
| `nginx` | 9001 | Nginx + PHP-FPM (`pm=static`, 16 child) |
| `franken-classic` | 9002 | FrankenPHP tanpa worker (16 thread) |
| `franken-worker` | 9003 | FrankenPHP worker mode (16 worker) |

## Prasyarat
- Docker + Docker Compose v2, `curl`, `python3`.
- k6 (opsional). Kalau tidak ada, `run-benchmark.sh` memakai image `grafana/k6`.
- Idealnya k6 dijalankan di **mesin terpisah** dari server uji. Kalau satu mesin, sisakan core untuk k6
  (total CPU stack 2 + DB 2 + k6; mesin ≥ 8 core disarankan) dan sebutkan itu di laporan.

## Menjalankan
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
| `ramp` | 50→100→200→400→800 VU bertahap, cari titik patah |
| `spike` | 20 VU → lonjakan 800 VU → kembali 20; lihat pemulihan |
| `soak` | 100 VU selama 30 menit; pantau memori & stabilitas |
| `arrival` | laju request tetap (50→1000 req/s), tidak bergantung kecepatan server; perhatikan `dropped_iterations` |

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
