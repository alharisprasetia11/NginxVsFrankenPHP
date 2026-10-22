#!/usr/bin/env bash
# =============================================================
# Menjalankan benchmark Nginx+FPM vs FrankenPHP (classic & worker)
#
# Contoh:
#   ./run-benchmark.sh                         # ramp, mixed, 3x ulang, semua target
#   ./run-benchmark.sh -s spike -a db -r 5
#   ./run-benchmark.sh -s soak -a mixed -r 1 -t "nginx franken-worker"
#
# Opsi:
#   -s SCENARIO  smoke|ramp|spike|soak|arrival   (default: ramp)
#   -a ACTION    hello|cpu|io|db|dbwrite|slow|mixed (default: mixed)
#   -r REPEATS   jumlah pengulangan per target   (default: 3)
#   -t TARGETS   daftar target dipisah spasi     (default: semua)
#   -c COOLDOWN  jeda antar run, detik           (default: 30)
#   -k "ARGS"    argumen tambahan untuk k6 (mis. "-e P95_MS=500 -e THINK=0.1")
#
# Setiap run: DB di-reset, hanya SATU stack hidup, ada warm-up, dan
# docker stats direkam tiap detik ke results/raw/.
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"

SCENARIO=ramp
ACTION=mixed
REPEATS=3
TARGETS="nginx franken-classic franken-worker"
COOLDOWN=30
K6_EXTRA=""

while getopts "s:a:r:t:c:k:h" opt; do
  case $opt in
    s) SCENARIO=$OPTARG ;;
    a) ACTION=$OPTARG ;;
    r) REPEATS=$OPTARG ;;
    t) TARGETS=$OPTARG ;;
    c) COOLDOWN=$OPTARG ;;
    k) K6_EXTRA=$OPTARG ;;
    h|*) sed -n '2,22p' "$0"; exit 0 ;;
  esac
done

declare -A PORT=( [nginx]=9001 [franken-classic]=9002 [franken-worker]=9003 )
for t in $TARGETS; do
  [[ -n "${PORT[$t]:-}" ]] || { echo "[!] Target tidak dikenal: $t"; exit 1; }
done

command -v docker >/dev/null || { echo "[!] docker tidak ditemukan"; exit 1; }
command -v curl   >/dev/null || { echo "[!] curl tidak ditemukan";   exit 1; }

RAW=results/raw
mkdir -p "$RAW"
chmod 777 "$RAW" 2>/dev/null || true   # agar container k6 (user non-root) bisa menulis

ALL_PROFILES=(--profile nginx --profile franken-classic --profile franken-worker)
STATS_PID=""

down_all() { docker compose "${ALL_PROFILES[@]}" down -v --remove-orphans >/dev/null 2>&1 || true; }
stop_stats() {
  if [[ -n "$STATS_PID" ]]; then
    kill "$STATS_PID" 2>/dev/null || true
    wait "$STATS_PID" 2>/dev/null || true
    STATS_PID=""
  fi
}
cleanup() { stop_stats; down_all; }
trap cleanup EXIT

collect_stats() {   # $1=profile  $2=file csv
  local ids
  ids=$(docker compose --profile "$1" ps -q | tr '\n' ' ')
  echo "ts,name,cpu_pct,mem_usage" > "$2"
  while true; do
    # shellcheck disable=SC2086
    docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' $ids 2>/dev/null \
      | while IFS= read -r line; do echo "$(date +%s),$line"; done >> "$2"
    sleep 2   # docker stats sendiri memakan CPU; jangan terlalu rapat di server kecil
  done
}

run_k6() {   # $1=target $2=port $3=summary-basename
  local env_args=(-e "BASE_URL=http://127.0.0.1:$2" -e "TARGET=$1" -e "SCENARIO=$SCENARIO" -e "ACTION=$ACTION")
  if command -v k6 >/dev/null; then
    # shellcheck disable=SC2086
    k6 run "${env_args[@]}" $K6_EXTRA --summary-export "$RAW/$3_summary.json" k6/bench.js
  else
    echo "[*] k6 tidak terinstall, memakai image grafana/k6 (host network)"
    # shellcheck disable=SC2086
    docker run --rm -i --network host \
      -v "$PWD/k6:/scripts:ro" -v "$PWD/$RAW:/out" \
      grafana/k6:latest run "${env_args[@]}" $K6_EXTRA \
      --summary-export "/out/$3_summary.json" /scripts/bench.js
  fi
}

run_one() {  # $1=target $2=repeat
  local t=$1 rep=$2 port=${PORT[$1]} base="${1}_r${2}"
  echo
  echo "================ $t  (ulangan $rep/$REPEATS, $SCENARIO/$ACTION) ================"

  down_all
  docker compose --profile "$t" up -d --build --wait

  echo "[*] Menunggu http://127.0.0.1:$port siap..."
  local ok=0
  for _ in $(seq 1 60); do
    if curl -fsS "http://127.0.0.1:$port/?action=health" >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
  done
  [[ $ok -eq 1 ]] || { echo "[!] $t tidak merespons"; docker compose --profile "$t" logs --tail=40; return 1; }

  collect_stats "$t" "$RAW/${base}_stats.csv" &
  STATS_PID=$!

  run_k6 "$t" "$port" "$base" || echo "[!] k6 selesai dengan exit code != 0 (threshold gagal atau error)"

  stop_stats

  # Catat restart & OOM kill (indikator ketangguhan)
  {
    for id in $(docker compose --profile "$t" ps -aq); do
      docker inspect -f '{{.Name}} restarts={{.RestartCount}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}}' "$id"
    done
  } > "$RAW/${base}_health.txt"
  cat "$RAW/${base}_health.txt"

  echo "[*] Cooldown ${COOLDOWN}s"
  sleep "$COOLDOWN"
}

for rep in $(seq 1 "$REPEATS"); do
  # Balik urutan di ulangan genap untuk mengurangi bias urutan (cache, thermal)
  ORDER=($TARGETS)
  if (( rep % 2 == 0 )); then
    mapfile -t ORDER < <(printf '%s\n' "${ORDER[@]}" | tac)
  fi
  for t in "${ORDER[@]}"; do
    run_one "$t" "$rep" || true
  done
done

echo
echo "[*] Merangkum hasil..."
python3 scripts/summarize.py "$RAW" | tee results/summary.md
echo
echo "[OK] Ringkasan: results/summary.md  |  data mentah: $RAW/"
