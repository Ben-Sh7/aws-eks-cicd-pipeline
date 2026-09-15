import { Transform } from 'class-transformer';
import {
  IsEnum,
  IsISO8601,
  IsNotEmpty,
  IsOptional,
  IsString,
  Matches,
  MaxLength,
  ValidateIf,
} from 'class-validator';
import { TaskPriority, TaskStatus } from '../task.enums';
import {
  DATE_ONLY,
  DESCRIPTION_MAX_LENGTH,
  TITLE_MAX_LENGTH,
  trim,
} from './task-fields';

// Validates the field whenever it is present. Unlike @IsOptional(), which also
// skips null, this rejects null for columns that are NOT NULL.
const IfPresent = () => ValidateIf((_object, value) => value !== undefined);

// Every field is optional. null clears description and dueDate.
export class UpdateTaskDto {
  @IfPresent()
  @Transform(trim)
  @IsString()
  @IsNotEmpty()
  @MaxLength(TITLE_MAX_LENGTH)
  title?: string;

  @IsOptional()
  @Transform(trim)
  @IsString()
  @MaxLength(DESCRIPTION_MAX_LENGTH)
  description?: string | null;

  @IfPresent()
  @IsEnum(TaskStatus)
  status?: TaskStatus;

  @IfPresent()
  @IsEnum(TaskPriority)
  priority?: TaskPriority;

  @IsOptional()
  @Matches(DATE_ONLY, { message: 'dueDate must be in YYYY-MM-DD format' })
  @IsISO8601({ strict: true })
  dueDate?: string | null;
}
