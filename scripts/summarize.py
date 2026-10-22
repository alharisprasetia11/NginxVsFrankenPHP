#!/usr/bin/env python3
"""Rangkum hasil k6 (--summary-export) + docker stats menjadi tabel Markdown.

Pemakaian: python3 scripts/summarize.py results/raw
Nilai per target = MEDIAN dari semua ulangan; kolom min-max RPS menunjukkan variansi.
"""
import csv
import json
import re
import statistics as st
import sys
from collections import defaultdict
from pathlib import Path

PH = "{phase:main}"


def metric(metrics, name, key, *alts):
    """Ambil nilai metrik; kompatibel format summary-export lama & baru."""
    m = metrics.get(name)
    if not m:
        return None
    v = m.get("values", m)
    for k in (key, *alts):
        if k in v and v[k] is not None:
            return v[k]
    return None


def parse_mem(s):
    """'12.3MiB / 1GiB' -> MB (sisi kiri)."""
    used = s.split("/")[0].strip()
    m = re.match(r"([\d.]+)\s*([KMG]?i?B)", used)
    if not m:
        return 0.0
    n, unit = float(m.group(1)), m.group(2).lower()
    return n * {"b": 1 / 1e6, "kib": 1 / 1024, "kb": 1 / 1000, "mib": 1, "mb": 1,
                "gib": 1024, "gb": 1000}.get(unit, 1)


def parse_stats(path):
    """Kembalikan (peak CPU% total, peak memori MB total) container non-DB."""
    cpu_by_ts, mem_by_ts = defaultdict(float), defaultdict(float)
    try:
        with open(path, newline="") as f:
            for row in csv.DictReader(f):
                if re.search(r"[-_]db[-_]", row["name"]):
                    continue
                try:
                    cpu_by_ts[row["ts"]] += float(row["cpu_pct"].rstrip("%"))
                    mem_by_ts[row["ts"]] += parse_mem(row["mem_usage"])
                except (ValueError, KeyError):
                    pass
    except FileNotFoundError:
        return None, None
    if not cpu_by_ts:
        return None, None
    return max(cpu_by_ts.values()), max(mem_by_ts.values())


def parse_health(path):
    restarts, oom = 0, 0
    try:
        for line in Path(path).read_text().splitlines():
            m = re.search(r"restarts=(\d+) oom=(\w+)", line)
            if m:
                restarts += int(m.group(1))
                oom += m.group(2) == "true"
    except FileNotFoundError:
        pass
    return restarts, oom


def med(xs):
    xs = [x for x in xs if x is not None]
    return st.median(xs) if xs else None


def fmt(x, d=1):
    return "-" if x is None else f"{x:,.{d}f}"


def main(raw_dir):
    raw = Path(raw_dir)
    runs = defaultdict(list)
    for f in sorted(raw.glob("*_summary.json")):
        m = re.match(r"^(.+)_r(\d+)_summary\.json$", f.name)
        if not m:
            continue
        target, rep = m.group(1), m.group(2)
        metrics = json.loads(f.read_text()).get("metrics", {})
        cpu, mem = parse_stats(raw / f"{target}_r{rep}_stats.csv")
        restarts, oom = parse_health(raw / f"{target}_r{rep}_health.txt")
        failed = metric(metrics, f"http_req_failed{PH}", "value", "rate")
        app_err = metric(metrics, f"app_errors{PH}", "value", "rate")
        runs[target].append({
            "rps": metric(metrics, f"http_reqs{PH}", "rate"),
            "reqs": metric(metrics, f"http_reqs{PH}", "count"),
            "avg": metric(metrics, f"http_req_duration{PH}", "avg"),
            "p95": metric(metrics, f"http_req_duration{PH}", "p(95)"),
            "p99": metric(metrics, f"http_req_duration{PH}", "p(99)"),
            "max": metric(metrics, f"http_req_duration{PH}", "max"),
            "fail": None if failed is None else failed * 100,
            "apperr": None if app_err is None else app_err * 100,
            "dropped": metric(metrics, f"dropped_iterations{PH}", "count") or 0,
            "cpu": cpu, "mem": mem, "restarts": restarts, "oom": oom,
        })

    if not runs:
        print("Tidak ada file *_summary.json di", raw)
        return 1

    print("# Ringkasan benchmark\n")
    print("Nilai = median dari semua ulangan. Latensi dalam ms. Hanya fase *main* (warm-up dikecualikan).\n")
    head = ("| Target | Ulangan | RPS (median) | RPS min-max | avg | p95 | p99 | max | HTTP gagal % | "
            "Respons salah % | Dropped | Peak CPU % | Peak Mem MB | Restart | OOM |")
    print(head)
    print("|" + "---|" * 15)
    for target in sorted(runs):
        r = runs[target]
        rps = [x["rps"] for x in r if x["rps"] is not None]
        rng = f"{min(rps):,.0f}-{max(rps):,.0f}" if rps else "-"
        print("| {t} | {n} | {rps} | {rng} | {avg} | {p95} | {p99} | {mx} | {f} | {ae} | {d} | {cpu} | {mem} | {rs} | {oom} |".format(
            t=target, n=len(r), rps=fmt(med([x["rps"] for x in r]), 0), rng=rng,
            avg=fmt(med([x["avg"] for x in r])), p95=fmt(med([x["p95"] for x in r])),
            p99=fmt(med([x["p99"] for x in r])), mx=fmt(med([x["max"] for x in r]), 0),
            f=fmt(med([x["fail"] for x in r]), 2), ae=fmt(med([x["apperr"] for x in r]), 2),
            d=fmt(med([x["dropped"] for x in r]), 0), cpu=fmt(med([x["cpu"] for x in r]), 0),
            mem=fmt(med([x["mem"] for x in r]), 0),
            rs=sum(x["restarts"] for x in r), oom=sum(x["oom"] for x in r)))
    print("\n*Peak CPU/Mem = jumlah semua container aplikasi (DB tidak dihitung); "
          "CPU 100% = 1 core.*")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1] if len(sys.argv) > 1 else "results/raw"))
