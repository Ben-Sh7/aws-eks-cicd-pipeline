import { Injectable, NotFoundException } from '@nestjs/common';
import { InjectRepository } from '@nestjs/typeorm';
import { FindOptionsWhere, Repository } from 'typeorm';
import { CreateTaskDto } from './dto/create-task.dto';
import { ListTasksQuery } from './dto/list-tasks.query';
import { UpdateTaskDto } from './dto/update-task.dto';
import { Task } from './task.entity';
import { TaskPriority, TaskStatus } from './task.enums';

// Every query is scoped by userId. Another user's task id is therefore
// indistinguishable from a missing one (404, never 403), so ids cannot be
// probed for existence.
@Injectable()
export class TasksService {
  constructor(
    @InjectRepository(Task) private readonly tasks: Repository<Task>,
  ) {}

  list(userId: string, query: ListTasksQuery): Promise<Task[]> {
    // TypeORM 1.x throws on undefined values in `where`, so filters are only
    // added when they are set.
    const where: FindOptionsWhere<Task> = { userId };
    if (query.status) {
      where.status = query.status;
    }
    if (query.priority) {
      where.priority = query.priority;
    }
    return this.tasks.find({ where, order: { createdAt: 'DESC' } });
  }

  create(userId: string, dto: CreateTaskDto): Promise<Task> {
    const task = this.tasks.create({
      userId,
      title: dto.title,
      description: dto.description ?? null,
      status: dto.status ?? TaskStatus.Todo,
      priority: dto.priority ?? TaskPriority.Medium,
      dueDate: dto.dueDate ?? null,
    });
    return this.tasks.save(task);
  }

  async get(userId: string, id: string): Promise<Task> {
    const task = await this.tasks.findOneBy({ id, userId });
    if (!task) {
      throw new NotFoundException('Task not found');
    }
    return task;
  }

  async update(userId: string, id: string, dto: UpdateTaskDto): Promise<Task> {
    const task = await this.get(userId, id);
    if (dto.title !== undefined) {
      task.title = dto.title;
    }
    if (dto.description !== undefined) {
      task.description = dto.description;
    }
    if (dto.status !== undefined) {
      task.status = dto.status;
    }
    if (dto.priority !== undefined) {
      task.priority = dto.priority;
    }
    if (dto.dueDate !== undefined) {
      task.dueDate = dto.dueDate;
    }
    return this.tasks.save(task);
  }

  async remove(userId: string, id: string): Promise<void> {
    const result = await this.tasks.delete({ id, userId });
    if (!result.affected) {
      throw new NotFoundException('Task not found');
    }
  }
}
