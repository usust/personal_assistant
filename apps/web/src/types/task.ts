export interface TaskList {
  id: number
  name: string
  remark: string
  color: string
  icon: string
  createdAt: string
  updatedAt: string
}

export interface SaveTaskListPayload {
  name: string
  remark?: string
  color?: string
  icon?: string
}

export type TaskPriority = 'high' | 'medium' | 'low'
export type TaskType = 'main' | 'subtask'

export interface TaskRecord {
  icon?: string
  id: number
  title: string
  remark: string
  listId: number
  startDate: string
  startTime: string
  endDate: string
  endTime: string
  priority: TaskPriority
  archived: boolean
  parentId: number | null
  taskType: TaskType
  sortOrder?: number
  progressTotal?: number
  progressCompleted?: number
  progressStep?: number
  progressUnit?: string
  createdAt: string
  updatedAt: string
}

export interface Task {
  icon?: string
  id: number
  title: string
  remark: string
  listId: number
  startDate: string
  startTime: string
  endDate: string
  endTime: string
  priority: TaskPriority
  archived: boolean
  parentId: number | null
  taskType: TaskType
  sortOrder: number
  progressPercent: number
  progressTotal: string
  progressCompleted: string
  progressStep: string | null
  progressUnit: string
  progressConfigTotal: string
  progressConfigCompleted: string
  progressConfigStep: string
  progressConfigUnit: string
  subtaskTotal: number
  subtaskCompleted: number
  createdAt: string
  updatedAt: string
}

export interface CreateTaskPayload {
  icon?: string
  title: string
  remark?: string
  listId: number
  startDate?: string
  startTime?: string
  endDate?: string
  endTime?: string
  priority?: TaskPriority
  parentId?: number | null
  taskType?: TaskType
  progressTotal?: string
  progressCompleted?: string
  progressStep?: string
  progressUnit?: string
}

export interface UpdateTaskPayload {
  icon?: string
  archived?: boolean
  title?: string
  remark?: string
  startDate?: string
  startTime?: string
  endDate?: string
  endTime?: string
  priority?: TaskPriority
  parentId?: number | null
  taskType?: TaskType
  progressTotal?: string
  progressCompleted?: string
  progressStep?: string
  progressUnit?: string
}

export interface TaskMutationResult {
  task: Task
  affectedParent: Task | null
}

export type ProgressOperationPayload = {
  operation: 'increment' | 'decrement'
  allowExceedTotal?: boolean
}

export interface ReorderTasksPayload {
  taskIds: number[]
}
