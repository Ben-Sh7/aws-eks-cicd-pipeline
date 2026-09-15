import { IsEnum, IsOptional } from 'class-validator';
import { TaskPriority, TaskStatus } from '../task.enums';

export class ListTasksQuery {
  @IsOptional()
  @IsEnum(TaskStatus)
  status?: TaskStatus;

  @IsOptional()
  @IsEnum(TaskPriority)
  priority?: TaskPriority;
}
