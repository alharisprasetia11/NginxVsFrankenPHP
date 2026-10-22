import http from 'k6/http';
import { check } from 'k6';

const TYPE     = __ENV.TYPE || 'hello'; 
const VUS      = __ENV.VUS || 50;
const DURATION = __ENV.DURATION || '30s';

export const options = {
  vus: parseInt(VUS),
  duration: DURATION,
  tags: {
    name: 'FrankenPHP_Test',
  },
};

export default function () {
  const url = `http://localhost:9002/?action=${TYPE}`;
  
  const params = { 
    headers: { 'Content-Type': 'application/json' },
    tags: { name: 'Franken_Req' }
  };

  const res = http.get(url, params);

  check(res, {
    'status is 200': (r) => r.status === 200,
  });
}