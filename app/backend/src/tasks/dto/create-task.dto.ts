import { Transform } from 'class-transformer';
import {
  IsEnum,
  IsISO8601,
  IsNotEmpty,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
} from 'class-validator';
import { TaskPriority, TaskStatus } from '../task.enums';
import {
  DATE_ONLY,
  DESCRIPTION_MAX_LENGTH,
  TITLE_MAX_LENGTH,
  trim,
} from './task-fields';

export class CreateTaskDto {
  @Transform(trim)
  @IsString()
  @IsNotEmpty()
  @MaxLength(TITLE_MAX_LENGTH)
  title!: string;

  @IsOptional()
  @Transform(trim)
  @IsString()
  @MaxLength(DESCRIPTION_MAX_LENGTH)
  description?: string | null;

  @IsOptional()
  @IsEnum(TaskStatus)
  status?: TaskStatus;

  @IsOptional()
  @IsEnum(TaskPriority)
  priority?: TaskPriority;

  @IsOptional()
  @Matches(DATE_ONLY, { message: 'dueDate must be in YYYY-MM-DD format' })
  @IsISO8601({ strict: true })
  dueDate?: string | null;
}
