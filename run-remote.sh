#!/usr/bin/env bash
# =============================================================
# Dijalankan di KOMPUTER LOKAL (Linux / macOS / WSL / Git Bash).
# Server dikendalikan lewat SSH; k6 berjalan di komputer ini.
#
# Contoh:
#   ./run-remote.sh -H root@203.0.113.10 -s smoke -r 1
#   ./run-remote.sh -H root@203.0.113.10 -s ramp -a mixed -r 3
#   ./run-remote.sh -H root@203.0.113.10 -s ramp -a health -r 3   # baseline jaringan
#
# Opsi:
#   -H user@host   tujuan SSH server (wajib)
#   -d DIR         folder proyek di server (default: ~/nginx-vs-franken-v2)
#   -s SCENARIO    smoke|ramp|spike|soak|arrival  (default: ramp)
#   -a ACTION      hello|cpu|io|db|dbwrite|slow|mixed|health (default: mixed)
#   -r REPEATS     ulangan per target             (default: 3)
#   -t TARGETS     "nginx franken-classic franken-worker"
#   -c COOLDOWN    jeda antar run, detik          (default: 45)
#   -k "ARGS"      argumen tambahan k6, mis. "-e RAMP_LEVELS=10,30,60"
# =============================================================
set -euo pipefail
cd "$(dirname "$0")"

SERVER=""
REMOTE_DIR="nginx-vs-franken-v2"
SCENARIO=ramp
ACTION=mixed
REPEATS=3
TARGETS="nginx franken-classic franken-worker"
COOLDOWN=45
K6_EXTRA=""

while getopts "H:d:s:a:r:t:c:k:h" opt; do
  case $opt in
    H) SERVER=$OPTARG ;;
    d) REMOTE_DIR=$OPTARG ;;
    s) SCENARIO=$OPTARG ;;
    a) ACTION=$OPTARG ;;
    r) REPEATS=$OPTARG ;;
    t) TARGETS=$OPTARG ;;
    c) COOLDOWN=$OPTARG ;;
    k) K6_EXTRA=$OPTARG ;;
    h|*) sed -n '2,22p' "$0"; exit 0 ;;
  esac
done

[[ -n "$SERVER" ]] || { echo "[!] -H user@host wajib. Contoh: -H root@203.0.113.10"; exit 1; }
HOST="${SERVER#*@}"

declare -A PORT=( [nginx]=9001 [franken-classic]=9002 [franken-worker]=9003 )
for t in $TARGETS; do [[ -n "${PORT[$t]:-}" ]] || { echo "[!] target tidak dikenal: $t"; exit 1; }; done

command -v ssh  >/dev/null || { echo "[!] ssh tidak ditemukan";  exit 1; }
command -v scp  >/dev/null || { echo "[!] scp tidak ditemukan";  exit 1; }
command -v curl >/dev/null || { echo "[!] curl tidak ditemukan"; exit 1; }

SSH_OPTS=(-o ServerAliveInterval=30 -o ServerAliveCountMax=6)
rsh() { ssh "${SSH_OPTS[@]}" "$SERVER" "cd $REMOTE_DIR && $*"; }

RAW=results/raw
mkdir -p "$RAW"
chmod 777 "$RAW" 2>/dev/null || true

cleanup() { echo; echo "[*] Mematikan stack di server..."; rsh "./server/server-ctl.sh down" >/dev/null 2>&1 || true; }
trap cleanup EXIT

echo "[*] Baseline jaringan komputer ini -> $HOST"
if command -v ping >/dev/null; then ping -c 5 "$HOST" 2>/dev/null | tail -n 2 || true; fi

run_k6() {   # $1=target $2=port $3=base
  local env_args=(-e "BASE_URL=http://$HOST:$2" -e "TARGET=$1" -e "SCENARIO=$SCENARIO" -e "ACTION=$ACTION")
  if command -v k6 >/dev/null; then
    # shellcheck disable=SC2086
    k6 run "${env_args[@]}" $K6_EXTRA --summary-export "$RAW/$3_summary.json" k6/bench.js
  else
    echo "[*] k6 tidak terinstall, memakai image grafana/k6"
    # shellcheck disable=SC2086
    docker run --rm -i \
      -v "$PWD/k6:/scripts:ro" -v "$PWD/$RAW:/out" \
      grafana/k6:latest run "${env_args[@]}" $K6_EXTRA \
      --summary-export "/out/$3_summary.json" /scripts/bench.js
  fi
}

run_one() {  # $1=target $2=ulangan
  local t=$1 rep=$2 port=${PORT[$1]} base="${1}_r${2}"
  echo
  echo "================ $t  (ulangan $rep/$REPEATS, $SCENARIO/$ACTION) ================"

  rsh "./server/server-ctl.sh up $t"

  local ok=0
  for _ in $(seq 1 60); do
    if curl -fsS -m 3 "http://$HOST:$port/?action=health" >/dev/null 2>&1; then ok=1; break; fi
    sleep 1
  done
  [[ $ok -eq 1 ]] || { echo "[!] http://$HOST:$port tidak terjangkau dari komputer ini (firewall/port diblokir?)"; return 1; }

  rsh "./server/server-ctl.sh stats-start $t $base"
  run_k6 "$t" "$port" "$base" || echo "[!] k6 exit code != 0 (threshold gagal atau ada error)"
  rsh "./server/server-ctl.sh stats-stop $t $base"

  scp "${SSH_OPTS[@]}" -q "$SERVER:$REMOTE_DIR/$RAW/${base}_stats.csv" "$SERVER:$REMOTE_DIR/$RAW/${base}_health.txt" "$RAW/" \
    || echo "[!] gagal mengambil data stats dari server"

  echo "[*] Cooldown ${COOLDOWN}s"
  sleep "$COOLDOWN"
}

for rep in $(seq 1 "$REPEATS"); do
  ORDER=($TARGETS)
  if (( rep % 2 == 0 )); then
    mapfile -t ORDER < <(printf '%s\n' "${ORDER[@]}" | tac)
  fi
  for t in "${ORDER[@]}"; do run_one "$t" "$rep" || true; done
done

echo
if command -v python3 >/dev/null; then
  python3 scripts/summarize.py "$RAW" | tee results/summary.md
  echo; echo "[OK] Ringkasan: results/summary.md"
else
  echo "[!] python3 tidak ada di komputer ini; jalankan scripts/summarize.py di mesin lain dengan folder $RAW"
fi
