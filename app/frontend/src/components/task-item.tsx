'use client';

import { useState } from 'react';
import { errorMessage } from '@/lib/api-client';
import {
  PRIORITY_LABELS,
  STATUS_LABELS,
  type Task,
  TASK_STATUSES,
  type TaskChanges,
} from '@/lib/tasks';
import { TaskForm } from './task-form';

interface TaskItemProps {
  task: Task;
  onUpdate: (id: string, changes: TaskChanges) => Promise<void>;
  onDelete: (id: string) => Promise<void>;
}

const PRIORITY_STYLES = {
  low: 'bg-slate-100 text-slate-600',
  medium: 'bg-amber-100 text-amber-800',
  high: 'bg-red-100 text-red-700',
} as const;

// The user's local calendar date, in the same YYYY-MM-DD form as dueDate.
function today(): string {
  return new Date().toLocaleDateString('en-CA');
}

export function TaskItem({ task, onUpdate, onDelete }: TaskItemProps) {
  const [editing, setEditing] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function run(action: () => Promise<void>) {
    setBusy(true);
    setError(null);
    try {
      await action();
    } catch (actionError) {
      setError(errorMessage(actionError));
    } finally {
      setBusy(false);
    }
  }

  if (editing) {
    return (
      <li className="rounded-xl bg-white p-4 shadow-sm ring-2 ring-indigo-200">
        <TaskForm
          initial={task}
          submitLabel="Save"
          onSubmit={async (input) => {
            await onUpdate(task.id, input);
            setEditing(false);
          }}
          onCancel={() => setEditing(false)}
        />
      </li>
    );
  }

  const done = task.status === 'done';
  const overdue = !done && task.dueDate !== null && task.dueDate < today();

  return (
    <li
      className={`rounded-xl bg-white p-4 shadow-sm transition ${busy ? 'opacity-60' : ''}`}
    >
      <div className="flex items-start gap-3">
        <input
          type="checkbox"
          aria-label={done ? 'Mark as not done' : 'Mark as done'}
          className="mt-1 h-5 w-5 accent-indigo-600"
          checked={done}
          disabled={busy}
          onChange={(event) =>
            run(() =>
              onUpdate(task.id, {
                status: event.target.checked ? 'done' : 'todo',
              }),
            )
          }
        />

        <div className="min-w-0 flex-1">
          <p
            className={`break-words font-medium ${done ? 'text-slate-400 line-through' : ''}`}
          >
            {task.title}
          </p>
          {task.description && (
            <p className="mt-1 whitespace-pre-wrap break-words text-sm text-slate-600">
              {task.description}
            </p>
          )}
          <div className="mt-2 flex flex-wrap items-center gap-2 text-xs">
            <span
              className={`rounded-full px-2 py-0.5 font-medium ${PRIORITY_STYLES[task.priority]}`}
            >
              {PRIORITY_LABELS[task.priority]}
            </span>
            {task.dueDate && (
              <span
                className={`rounded-full px-2 py-0.5 ${overdue ? 'bg-red-600 text-white' : 'bg-slate-100 text-slate-600'}`}
              >
                {overdue ? 'Overdue · ' : 'Due '}
                {task.dueDate}
              </span>
            )}
          </div>
        </div>

        <div className="flex shrink-0 flex-col items-end gap-2">
          <select
            aria-label="Status"
            className="rounded-lg border border-slate-300 bg-white px-2 py-1 text-xs"
            value={task.status}
            disabled={busy}
            onChange={(event) => {
              const status = TASK_STATUSES.find(
                (value) => value === event.target.value,
              );
              if (status) {
                void run(() => onUpdate(task.id, { status }));
              }
            }}
          >
            {TASK_STATUSES.map((value) => (
              <option key={value} value={value}>
                {STATUS_LABELS[value]}
              </option>
            ))}
          </select>
          <div className="flex gap-1">
            <button
              type="button"
              disabled={busy}
              onClick={() => setEditing(true)}
              className="rounded-md px-2 py-1 text-xs font-medium text-indigo-600 hover:bg-indigo-50"
            >
              Edit
            </button>
            <button
              type="button"
              disabled={busy}
              onClick={() => {
                if (window.confirm(`Delete "${task.title}"?`)) {
                  void run(() => onDelete(task.id));
                }
              }}
              className="rounded-md px-2 py-1 text-xs font-medium text-red-600 hover:bg-red-50"
            >
              Delete
            </button>
          </div>
        </div>
      </div>
      {error && (
        <p role="alert" className="mt-2 text-sm text-red-600">
          {error}
        </p>
      )}
    </li>
  );
}
