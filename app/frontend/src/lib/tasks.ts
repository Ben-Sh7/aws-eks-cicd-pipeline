// Mirrors the backend's API shapes (app/backend/src/tasks/task.response.ts).

export const TASK_STATUSES = ['todo', 'in_progress', 'done'] as const;
export type TaskStatus = (typeof TASK_STATUSES)[number];

export const TASK_PRIORITIES = ['low', 'medium', 'high'] as const;
export type TaskPriority = (typeof TASK_PRIORITIES)[number];

export const STATUS_LABELS: Record<TaskStatus, string> = {
  todo: 'To do',
  in_progress: 'In progress',
  done: 'Done',
};

export const PRIORITY_LABELS: Record<TaskPriority, string> = {
  low: 'Low',
  medium: 'Medium',
  high: 'High',
};

export const TITLE_MAX_LENGTH = 200;
export const DESCRIPTION_MAX_LENGTH = 2000;

export interface Task {
  id: string;
  title: string;
  description: string | null;
  status: TaskStatus;
  priority: TaskPriority;
  dueDate: string | null;
  createdAt: string;
  updatedAt: string;
}

export interface TaskInput {
  title: string;
  description: string | null;
  priority: TaskPriority;
  dueDate: string | null;
}

export type TaskChanges = Partial<TaskInput> & { status?: TaskStatus };

export interface UserProfile {
  id: string;
  /** Set for username/password accounts. */
  username: string | null;
  /** Set for Google accounts. */
  email: string | null;
  name: string | null;
  avatarUrl: string | null;
}
