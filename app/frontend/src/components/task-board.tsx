'use client';

import { useEffect, useMemo, useState } from 'react';
import { apiFetch, errorMessage } from '@/lib/api-client';
import {
  PRIORITY_LABELS,
  STATUS_LABELS,
  type Task,
  TASK_PRIORITIES,
  TASK_STATUSES,
  type TaskChanges,
  type TaskInput,
  type TaskPriority,
  type TaskStatus,
  type UserProfile,
} from '@/lib/tasks';
import { TaskForm } from './task-form';
import { TaskItem } from './task-item';
import { UserMenu } from './user-menu';

const selectClass =
  'rounded-lg border border-slate-300 bg-white px-3 py-1.5 text-sm';

export function TaskBoard() {
  const [user, setUser] = useState<UserProfile | null>(null);
  const [tasks, setTasks] = useState<Task[] | null>(null);
  const [loadError, setLoadError] = useState<string | null>(null);
  const [statusFilter, setStatusFilter] = useState<TaskStatus | 'all'>('all');
  const [priorityFilter, setPriorityFilter] = useState<TaskPriority | 'all'>(
    'all',
  );

  useEffect(() => {
    let active = true;
    // Sequential on purpose: when the access token has expired, the first
    // call refreshes the session and the second reuses the new cookie instead
    // of racing it with a second refresh.
    (async () => {
      const profile = await apiFetch<UserProfile>('/api/auth/me');
      const list = await apiFetch<Task[]>('/api/tasks');
      if (active) {
        setUser(profile);
        setTasks(list);
      }
    })().catch((error: unknown) => {
      if (active) {
        setLoadError(errorMessage(error));
      }
    });
    return () => {
      active = false;
    };
  }, []);

  const visibleTasks = useMemo(
    () =>
      (tasks ?? []).filter(
        (task) =>
          (statusFilter === 'all' || task.status === statusFilter) &&
          (priorityFilter === 'all' || task.priority === priorityFilter),
      ),
    [tasks, statusFilter, priorityFilter],
  );

  const openCount = tasks?.filter((task) => task.status !== 'done').length ?? 0;

  async function createTask(input: TaskInput) {
    const task = await apiFetch<Task>('/api/tasks', {
      method: 'POST',
      body: JSON.stringify(input),
    });
    setTasks((current) => [task, ...(current ?? [])]);
  }

  async function updateTask(id: string, changes: TaskChanges) {
    const updated = await apiFetch<Task>(`/api/tasks/${id}`, {
      method: 'PATCH',
      body: JSON.stringify(changes),
    });
    setTasks(
      (current) =>
        current?.map((task) => (task.id === id ? updated : task)) ?? null,
    );
  }

  async function deleteTask(id: string) {
    await apiFetch<void>(`/api/tasks/${id}`, { method: 'DELETE' });
    setTasks((current) => current?.filter((task) => task.id !== id) ?? null);
  }

  return (
    <div className="mx-auto max-w-3xl px-4 py-8">
      <header className="mb-6 flex items-center justify-between gap-4">
        <div>
          <h1 className="text-2xl font-semibold">Task Manager</h1>
          {tasks && (
            <p className="text-sm text-slate-500">
              {openCount === 0
                ? 'All caught up'
                : `${openCount} open task${openCount === 1 ? '' : 's'}`}
            </p>
          )}
        </div>
        <UserMenu user={user} />
      </header>

      <section className="mb-6 rounded-xl bg-white p-4 shadow-sm">
        <h2 className="mb-3 text-sm font-semibold text-slate-700">New task</h2>
        <TaskForm submitLabel="Add task" onSubmit={createTask} resetOnSubmit />
      </section>

      <div className="mb-4 flex flex-wrap items-center gap-2">
        <select
          aria-label="Filter by status"
          className={selectClass}
          value={statusFilter}
          onChange={(event) =>
            setStatusFilter(
              TASK_STATUSES.find((value) => value === event.target.value) ??
                'all',
            )
          }
        >
          <option value="all">All statuses</option>
          {TASK_STATUSES.map((value) => (
            <option key={value} value={value}>
              {STATUS_LABELS[value]}
            </option>
          ))}
        </select>
        <select
          aria-label="Filter by priority"
          className={selectClass}
          value={priorityFilter}
          onChange={(event) =>
            setPriorityFilter(
              TASK_PRIORITIES.find((value) => value === event.target.value) ??
                'all',
            )
          }
        >
          <option value="all">All priorities</option>
          {TASK_PRIORITIES.map((value) => (
            <option key={value} value={value}>
              {PRIORITY_LABELS[value]}
            </option>
          ))}
        </select>
      </div>

      {loadError ? (
        <p role="alert" className="rounded-lg bg-red-50 p-4 text-sm text-red-700">
          {loadError}
        </p>
      ) : tasks === null ? (
        <p className="p-8 text-center text-sm text-slate-500">Loading tasks…</p>
      ) : visibleTasks.length === 0 ? (
        <p className="rounded-xl border-2 border-dashed border-slate-200 p-8 text-center text-sm text-slate-500">
          {tasks.length === 0
            ? 'No tasks yet. Add your first one above.'
            : 'No tasks match these filters.'}
        </p>
      ) : (
        <ul className="space-y-3">
          {visibleTasks.map((task) => (
            <TaskItem
              key={task.id}
              task={task}
              onUpdate={updateTask}
              onDelete={deleteTask}
            />
          ))}
        </ul>
      )}
    </div>
  );
}
