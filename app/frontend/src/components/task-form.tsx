'use client';

import { type FormEvent, useState } from 'react';
import {
  DESCRIPTION_MAX_LENGTH,
  PRIORITY_LABELS,
  TASK_PRIORITIES,
  type TaskInput,
  type TaskPriority,
  TITLE_MAX_LENGTH,
} from '@/lib/tasks';

interface TaskFormProps {
  initial?: TaskInput;
  submitLabel: string;
  onSubmit: (input: TaskInput) => Promise<void>;
  onCancel?: () => void;
  /** Clears the fields after a successful submit (the "new task" form). */
  resetOnSubmit?: boolean;
}

const EMPTY: TaskInput = {
  title: '',
  description: null,
  priority: 'medium',
  dueDate: null,
};

const inputClass =
  'w-full rounded-lg border border-slate-300 bg-white px-3 py-2 text-sm focus:border-indigo-500 focus:outline-none focus:ring-2 focus:ring-indigo-200';

export function TaskForm({
  initial = EMPTY,
  submitLabel,
  onSubmit,
  onCancel,
  resetOnSubmit = false,
}: TaskFormProps) {
  const [title, setTitle] = useState(initial.title);
  const [description, setDescription] = useState(initial.description ?? '');
  const [priority, setPriority] = useState<TaskPriority>(initial.priority);
  const [dueDate, setDueDate] = useState(initial.dueDate ?? '');
  const [submitting, setSubmitting] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function handleSubmit(event: FormEvent<HTMLFormElement>) {
    event.preventDefault();
    setSubmitting(true);
    setError(null);
    try {
      await onSubmit({
        title: title.trim(),
        description: description.trim() || null,
        priority,
        dueDate: dueDate || null,
      });
      if (resetOnSubmit) {
        setTitle(EMPTY.title);
        setDescription('');
        setPriority(EMPTY.priority);
        setDueDate('');
      }
    } catch (submitError) {
      setError(
        submitError instanceof Error ? submitError.message : 'Something went wrong',
      );
    } finally {
      setSubmitting(false);
    }
  }

  return (
    <form onSubmit={handleSubmit} className="space-y-3">
      <input
        aria-label="Title"
        className={inputClass}
        placeholder="What needs to be done?"
        value={title}
        onChange={(event) => setTitle(event.target.value)}
        maxLength={TITLE_MAX_LENGTH}
        required
      />
      <textarea
        aria-label="Description"
        className={`${inputClass} min-h-20 resize-y`}
        placeholder="Details (optional)"
        value={description}
        onChange={(event) => setDescription(event.target.value)}
        maxLength={DESCRIPTION_MAX_LENGTH}
      />
      <div className="flex flex-wrap items-end gap-3">
        <label className="text-xs font-medium text-slate-600">
          Priority
          <select
            className={`${inputClass} mt-1`}
            value={priority}
            onChange={(event) =>
              setPriority(
                TASK_PRIORITIES.find((value) => value === event.target.value) ??
                  EMPTY.priority,
              )
            }
          >
            {TASK_PRIORITIES.map((value) => (
              <option key={value} value={value}>
                {PRIORITY_LABELS[value]}
              </option>
            ))}
          </select>
        </label>
        <label className="text-xs font-medium text-slate-600">
          Due date
          <input
            type="date"
            className={`${inputClass} mt-1`}
            value={dueDate}
            onChange={(event) => setDueDate(event.target.value)}
          />
        </label>
        <div className="ml-auto flex gap-2">
          {onCancel && (
            <button
              type="button"
              onClick={onCancel}
              className="rounded-lg px-4 py-2 text-sm font-medium text-slate-600 hover:bg-slate-100"
            >
              Cancel
            </button>
          )}
          <button
            type="submit"
            disabled={submitting || title.trim() === ''}
            className="rounded-lg bg-indigo-600 px-4 py-2 text-sm font-medium text-white hover:bg-indigo-700 disabled:cursor-not-allowed disabled:opacity-50"
          >
            {submitting ? 'Saving…' : submitLabel}
          </button>
        </div>
      </div>
      {error && (
        <p role="alert" className="text-sm text-red-600">
          {error}
        </p>
      )}
    </form>
  );
}
