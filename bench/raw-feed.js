// Raw throughput probe (not scored): a fixed number of VUs request /feed back to back for 30 s.
// Reports how many feed requests per second the server can push when nobody thinks.
import http from 'k6/http';
import { check } from 'k6';

const BASE_URL = __ENV.BASE_URL || 'http://127.0.0.1:3000';

export const options = {
  vus: Number(__ENV.VUS || 64),
  duration: __ENV.DURATION || '30s',
  summaryTrendStats: ['avg', 'med', 'p(95)', 'p(99)', 'max'],
};

export default function () {
  check(http.get(`${BASE_URL}/feed`), { 'feed 200': (r) => r.status === 200 });
}
