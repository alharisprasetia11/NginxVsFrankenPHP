#!/usr/bin/env bash
# =============================================================
# Kontrol sisi SERVER untuk benchmark (dipanggil manual atau oleh run-remote.sh)
#
#   ./server/server-ctl.sh build-all              build semua image sekali di awal
#   ./server/server-ctl.sh up <target>            reset DB, jalankan 1 stack, tunggu siap
#   ./server/server-ctl.sh stats-start <target> <label>   rekam docker stats di background
#   ./server/server-ctl.sh stats-stop  <target> <label>   stop rekaman + catat restart/OOM
#   ./server/server-ctl.sh down                   matikan semua & hapus volume DB
#   ./server/server-ctl.sh status                 ringkas penggunaan resource saat ini
#
# target : nginx | franken-classic | franken-worker
# label  : mis. nginx_r1  (nama file: results/raw/<label>_stats.csv)
# =============================================================
set -euo pipefail
SELF="$(readlink -f "$0")"
cd "$(dirname "$SELF")/.."

declare -A PORT=( [nginx]=9001 [franken-classic]=9002 [franken-worker]=9003 )
ALL=(--profile nginx --profile franken-classic --profile franken-worker)
RAW=results/raw
PIDFILE=results/.stats.pid
STATS_INTERVAL="${STATS_INTERVAL:-2}"   # detik; docker stats sendiri memakan CPU

mkdir -p "$RAW"

need_target() {
  [[ -n "${1:-}" && -n "${PORT[$1]:-}" ]] || { echo "[!] target tidak valid: '${1:-}'. Pilih: ${!PORT[*]}"; exit 1; }
}

stop_stats_proc() {
  if [[ -f "$PIDFILE" ]]; then
    local pid; pid=$(cat "$PIDFILE")
    # matikan seluruh process group collector
    kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
    rm -f "$PIDFILE"
  fi
}

collect() {   # dijalankan di background: collect <target> <outfile>
  local ids
  ids=$(docker compose --profile "$1" ps -q | tr '\n' ' ')
  echo "ts,name,cpu_pct,mem_usage" > "$2"
  while true; do
    # shellcheck disable=SC2086
    docker stats --no-stream --format '{{.Name}},{{.CPUPerc}},{{.MemUsage}}' $ids 2>/dev/null \
      | while IFS= read -r line; do echo "$(date +%s),$line"; done >> "$2"
    sleep "$STATS_INTERVAL"
  done
}

cmd="${1:-}"; shift || true

case "$cmd" in
  build-all)
    echo "[*] Build semua image (sekali; di 1 vCPU bisa beberapa menit)..."
    docker compose "${ALL[@]}" build
    docker compose pull db
    ;;

  up)
    t="${1:-}"; need_target "$t"
    stop_stats_proc
    docker compose "${ALL[@]}" down -v --remove-orphans >/dev/null 2>&1 || true
    docker compose --profile "$t" up -d --build --wait
    for _ in $(seq 1 60); do
      if curl -fsS "http://127.0.0.1:${PORT[$t]}/?action=health" >/dev/null 2>&1; then
        echo "[OK] $t siap di port ${PORT[$t]}"
        exit 0
      fi
      sleep 1
    done
    echo "[!] $t tidak merespons"; docker compose --profile "$t" logs --tail=40; exit 1
    ;;

  stats-start)
    t="${1:-}"; label="${2:-}"; need_target "$t"; [[ -n "$label" ]] || { echo "[!] label wajib"; exit 1; }
    stop_stats_proc
    # setsid -> process group sendiri, tetap hidup walau sesi SSH ditutup
    nohup setsid "$SELF" _collect "$t" "$RAW/${label}_stats.csv" >/dev/null 2>&1 &
    echo $! > "$PIDFILE"
    echo "[OK] merekam stats -> $RAW/${label}_stats.csv"
    ;;

  _collect)
    collect "$1" "$2"
    ;;

  stats-stop)
    t="${1:-}"; label="${2:-}"; need_target "$t"; [[ -n "$label" ]] || { echo "[!] label wajib"; exit 1; }
    stop_stats_proc
    {
      for id in $(docker compose --profile "$t" ps -aq); do
        docker inspect -f '{{.Name}} restarts={{.RestartCount}} oom={{.State.OOMKilled}} exit={{.State.ExitCode}}' "$id"
      done
    } > "$RAW/${label}_health.txt"
    cat "$RAW/${label}_health.txt"
    ;;

  down)
    stop_stats_proc
    docker compose "${ALL[@]}" down -v --remove-orphans
    ;;

  status)
    free -h
    echo
    docker stats --no-stream --format 'table {{.Name}}\t{{.CPUPerc}}\t{{.MemUsage}}' 2>/dev/null || true
    ;;

  *)
    sed -n '2,15p' "$0"; exit 1
    ;;
esac
