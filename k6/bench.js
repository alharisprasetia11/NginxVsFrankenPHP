// k6 benchmark tunggal untuk Nginx+FPM / FrankenPHP classic / FrankenPHP worker.
//
// Env yang didukung (semua opsional kecuali BASE_URL):
//   BASE_URL      http://127.0.0.1:9001
//   SCENARIO      smoke | ramp | spike | soak | arrival      (default: smoke)
//   ACTION        hello|cpu|io|db|dbwrite|slow|mixed          (default: mixed)
//   THINK         think time antar request, detik             (default: 0)
//   WARMUP_S      lama warm-up, detik                         (default: 15)
//   P95_MS        ambang p95 (ms) untuk threshold             (default: 1000)
//   (default di bawah ini untuk server kecil 1 vCPU; naikkan untuk server besar)
//   RAMP_LEVELS   "10,25,50,100,200"   (VU, scenario ramp)
//   HOLD_S        tahan tiap level, detik                     (default: 30)
//   SPIKE_BASE / SPIKE_PEAK   VU normal & puncak              (5 / 200)
//   SOAK_VUS / SOAK_DURATION                                  (30 / 30m)
//   RATE_LEVELS   "20,50,100,200,400"  (req/s, scenario arrival)
//   MAX_VUS       batas VU untuk scenario arrival             (600)

import http from 'k6/http';
import { check, sleep, fail } from 'k6';
import { Rate } from 'k6/metrics';

const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:9001';
const SCENARIO = __ENV.SCENARIO || 'smoke';
const ACTION = __ENV.ACTION || 'mixed';
const THINK = parseFloat(__ENV.THINK || '0');
const WARMUP_S = parseInt(__ENV.WARMUP_S || '15');
const P95_MS = __ENV.P95_MS || '1000';
const HOLD_S = parseInt(__ENV.HOLD_S || '30');

const appErrors = new Rate('app_errors');

// Komposisi trafik untuk ACTION=mixed (bobot dalam persen)
const MIX = [
  ['hello', 40],
  ['db', 25],
  ['dbwrite', 10],
  ['cpu', 10],
  ['io', 10],
  ['slow', 5],
];

function pickAction() {
  if (ACTION !== 'mixed') return ACTION;
  let r = Math.random() * 100;
  for (const [name, weight] of MIX) {
    if ((r -= weight) < 0) return name;
  }
  return 'hello';
}

function pathFor(action) {
  if (action === 'slow') return '/?action=slow&ms=100';
  return `/?action=${action}`;
}

function json(res) {
  try {
    return res.json();
  } catch (e) {
    return null;
  }
}

// Validasi ISI respons, bukan hanya status 200
const validators = {
  hello: (r) => r.status === 200 && r.body && r.body.indexOf('WEB SEDERHANA') !== -1,
  health: (r) => r.status === 200 && (json(r) || {}).status === 'ok',
  cpu: (r) => r.status === 200 && (json(r) || {}).result === 75025, // fib(25)
  io: (r) => r.status === 200 && (json(r) || {}).status === 'ok',
  db: (r) => r.status === 200 && (json(r) || {}).count === 50,
  dbwrite: (r) => r.status === 200 && ((json(r) || {}).id || 0) > 0,
  slow: (r) => r.status === 200 && (json(r) || {}).status === 'ok',
};

function levels(envName, fallback) {
  return (__ENV[envName] || fallback).split(',').map((s) => parseInt(s.trim()));
}

function mainScenario() {
  const base = {
    exec: 'run',
    tags: { phase: 'main' },
    startTime: `${WARMUP_S + 5}s`, // beri jeda setelah warm-up
    gracefulStop: '30s',
  };

  switch (SCENARIO) {
    case 'smoke':
      return { ...base, executor: 'constant-vus', vus: 5, duration: '20s' };

    case 'ramp': {
      const stages = [];
      for (const target of levels('RAMP_LEVELS', '10,25,50,100,200')) {
        stages.push({ duration: '10s', target });
        stages.push({ duration: `${HOLD_S}s`, target });
      }
      stages.push({ duration: '10s', target: 0 });
      return { ...base, executor: 'ramping-vus', startVUs: 0, stages, gracefulRampDown: '10s' };
    }

    case 'spike': {
      const lo = parseInt(__ENV.SPIKE_BASE || '5');
      const hi = parseInt(__ENV.SPIKE_PEAK || '200');
      return {
        ...base,
        executor: 'ramping-vus',
        startVUs: lo,
        gracefulRampDown: '10s',
        stages: [
          { duration: '30s', target: lo },
          { duration: '10s', target: hi }, // lonjakan mendadak
          { duration: '60s', target: hi },
          { duration: '10s', target: lo }, // turun
          { duration: '60s', target: lo }, // fase pemulihan: latensi harus kembali normal
          { duration: '10s', target: 0 },
        ],
      };
    }

    case 'soak':
      return {
        ...base,
        executor: 'constant-vus',
        vus: parseInt(__ENV.SOAK_VUS || '30'),
        duration: __ENV.SOAK_DURATION || '30m',
      };

    case 'arrival': {
      // Model terbuka: laju request konstan, tidak bergantung kecepatan server
      const stages = [];
      for (const target of levels('RATE_LEVELS', '20,50,100,200,400')) {
        stages.push({ duration: '10s', target });
        stages.push({ duration: `${HOLD_S}s`, target });
      }
      return {
        ...base,
        executor: 'ramping-arrival-rate',
        startRate: 10,
        timeUnit: '1s',
        preAllocatedVUs: 100,
        maxVUs: parseInt(__ENV.MAX_VUS || '600'),
        stages,
      };
    }

    default:
      fail(`SCENARIO tidak dikenal: ${SCENARIO}`);
  }
}

export const options = {
  scenarios: {
    warmup: {
      executor: 'constant-vus',
      vus: 5,
      duration: `${WARMUP_S}s`,
      exec: 'warm',
      tags: { phase: 'warmup' },
    },
    main: mainScenario(),
  },
  // Threshold hanya untuk fase "main" (warm-up tidak dihitung).
  // Entri [] hanya untuk membuat sub-metrik agar muncul di summary export.
  thresholds: {
    'http_req_failed{phase:main}': ['rate<0.01'],
    'http_req_duration{phase:main}': [`p(95)<${P95_MS}`],
    'app_errors{phase:main}': ['rate<0.01'],
    'http_reqs{phase:main}': [],
    'dropped_iterations{phase:main}': [],
  },
  summaryTrendStats: ['avg', 'min', 'med', 'p(90)', 'p(95)', 'p(99)', 'max'],
};

export function setup() {
  // Tunggu target siap, supaya tidak ada "connection refused" di awal
  for (let i = 0; i < 60; i++) {
    const r = http.get(`${BASE_URL}/?action=health`, { timeout: '3s' });
    if (r.status === 200) return;
    sleep(1);
  }
  fail(`Target ${BASE_URL} tidak sehat setelah 60 detik`);
}

function hit(action) {
  const res = http.get(`${BASE_URL}${pathFor(action)}`, {
    tags: { name: `action:${action}` }, // kelompokkan per action, hindari cardinality URL
    timeout: '30s',
  });
  const ok = check(res, { 'respons valid': (r) => validators[action](r) }, { action });
  appErrors.add(!ok);
  return ok;
}

// Fase warm-up: panaskan opcache, koneksi DB, dan worker
export function warm() {
  hit(['hello', 'db', 'cpu', 'io'][Math.floor(Math.random() * 4)]);
  sleep(0.05);
}

export function run() {
  hit(pickAction());
  if (THINK > 0) sleep(THINK);
}
