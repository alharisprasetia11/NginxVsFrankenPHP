#!/usr/bin/env bash
# =============================================================
# Persiapan server kecil (1 vCPU / 1 GB) sebelum benchmark.
# Jalankan SEKALI di server:  sudo ./server/server-setup.sh
#  - Membuat swap 2 GB (mencegah OOM saat build image & saat beban tinggi)
#  - Menurunkan swappiness
#  - Memeriksa docker & cek proses apt yang menggantung
# =============================================================
set -euo pipefail

[[ $EUID -eq 0 ]] || { echo "[!] Jalankan dengan sudo"; exit 1; }

SWAP_GB=2

echo "[1/3] Swap"
if swapon --show | grep -q .; then
  echo "    Swap sudah aktif:"; swapon --show
else
  fallocate -l "${SWAP_GB}G" /swapfile || dd if=/dev/zero of=/swapfile bs=1M count=$((SWAP_GB * 1024))
  chmod 600 /swapfile
  mkswap /swapfile >/dev/null
  swapon /swapfile
  grep -q '^/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "    Swap ${SWAP_GB}G dibuat dan diaktifkan."
fi

echo "[2/3] Swappiness = 10"
sysctl -w vm.swappiness=10 >/dev/null
grep -q '^vm.swappiness' /etc/sysctl.conf || echo 'vm.swappiness=10' >> /etc/sysctl.conf

echo "[3/3] Pemeriksaan"
command -v docker >/dev/null && docker --version || echo "    [!] docker belum terinstall (jalankan setup-docker.sh)"
docker compose version 2>/dev/null || echo "    [!] docker compose plugin belum ada"
if pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null; then
  echo "    [!] Ada proses apt/dpkg yang masih berjalan; cek 'ps aux | grep apt'"
fi

echo
free -h
echo
echo "[OK] Server siap. Langkah berikut: ./server/server-ctl.sh build-all"
