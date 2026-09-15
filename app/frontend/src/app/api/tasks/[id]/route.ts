import type { NextRequest } from 'next/server';
import { forwardToBackend, jsonError } from '@/lib/server/bff';

interface Context {
  params: Promise<{ id: string }>;
}

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Only a UUID may be spliced into the backend path. Anything else - such as an
// encoded "../auth/me" - would otherwise let the URL escape /api/tasks.
async function taskPath(context: Context): Promise<string | null> {
  const { id } = await context.params;
  return UUID.test(id) ? `/api/tasks/${id}` : null;
}

const invalidId = () => jsonError(400, 'Invalid task id');

export async function GET(request: NextRequest, context: Context) {
  const path = await taskPath(context);
  return path ? forwardToBackend(request, path, 'GET') : invalidId();
}

export async function PATCH(request: NextRequest, context: Context) {
  const path = await taskPath(context);
  return path ? forwardToBackend(request, path, 'PATCH') : invalidId();
}

export async function DELETE(request: NextRequest, context: Context) {
  const path = await taskPath(context);
  return path ? forwardToBackend(request, path, 'DELETE') : invalidId();
}
