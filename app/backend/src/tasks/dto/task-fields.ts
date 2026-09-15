import type { TransformFnParams } from 'class-transformer';

export const TITLE_MAX_LENGTH = 200;
export const DESCRIPTION_MAX_LENGTH = 2000;
export const DATE_ONLY = /^\d{4}-\d{2}-\d{2}$/;

export const trim = ({ value }: TransformFnParams): unknown =>
  typeof value === 'string' ? value.trim() : value;
