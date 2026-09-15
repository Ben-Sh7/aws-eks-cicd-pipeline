// Liveness/readiness for the frontend pod. Deliberately independent of the
// backend: a backend outage should not restart every frontend pod as well.
export function GET() {
  return Response.json({ status: 'ok' });
}
