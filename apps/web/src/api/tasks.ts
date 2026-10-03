import { http } from './http'
import type { ApiResponse } from '@/types/api'
import type { CreateTaskPayload, ProgressOperationPayload, ReorderTasksPayload, Task, TaskRecord, UpdateTaskPayload } from '@/types/task'

interface ProgressSummary {
  total: number
  completed: number
  step: number
  unit: string
}

function formatStoredAmount(value: number) {
	if (Number.isInteger(value)) return String(value)
	return value.toFixed(2).replace(/0+$/, '').replace(/\.$/, '')
}

function minuteTime(value: string) {
  return value ? value.slice(0, 5) : ''
}

function normalizeTaskTimePayload(payload: CreateTaskPayload): CreateTaskPayload
function normalizeTaskTimePayload(payload: UpdateTaskPayload): UpdateTaskPayload
function normalizeTaskTimePayload(payload: CreateTaskPayload | UpdateTaskPayload) {
  return {
    ...payload,
    ...(payload.startTime === undefined ? {} : { startTime: minuteTime(payload.startTime) }),
    ...(payload.endTime === undefined ? {} : { endTime: minuteTime(payload.endTime) }),
  }
}

function buildTasks(items: TaskRecord[]): Task[] {
  // 兼容旧接口使用 0 表示顶级节点的数据；当前前后端统一以 null 表示无上级节点。
  items = items.map(item => item.parentId === 0 ? { ...item, parentId: null } : item)
  const children = new Map<number, TaskRecord[]>()
  const itemsById = new Map(items.map(item => [item.id, item]))
  for (const item of items) {
    if (item.parentId === null) continue
    const directChildren = children.get(item.parentId) ?? []
    directChildren.push(item)
    children.set(item.parentId, directChildren)
  }

  const summaries = new Map<number, ProgressSummary>()
  const visiting = new Set<number>()
  const taskProgress = (item: TaskRecord): ProgressSummary => ({
    total: item.progressTotal ?? 0,
    completed: item.progressCompleted ?? 0,
    step: item.progressStep ?? 0,
    unit: item.progressUnit?.trim() ?? '',
  })
  const summarize = (id: number): ProgressSummary => {
    const cached = summaries.get(id)
    if (cached) return cached

    const item = itemsById.get(id)
    if (!item) return { total: 0, completed: 0, step: 0, unit: '' }
    if (visiting.has(id)) return taskProgress(item)

    visiting.add(id)
    // 归档只控制任务的显示与可操作状态，不能从父级进度汇总中排除。
    const directChildren = children.get(id) ?? []
    let summary: ProgressSummary
    if (directChildren.length === 0) {
      summary = taskProgress(item)
    } else {
      const childSummaries = directChildren.map(child => summarize(child.id))
      const firstUnit = childSummaries[0]?.unit.trim() ?? ''
      summary = {
        total: childSummaries.reduce((total, child) => total + child.total, 0),
        completed: childSummaries.reduce((completed, child) => completed + child.completed, 0),
        step: 0,
        unit: firstUnit && childSummaries.every(child => child.unit.trim() === firstUnit) ? firstUnit : '工作量',
      }
    }
    visiting.delete(id)
    summaries.set(id, summary)
    return summary
  }
  items.forEach(item => summarize(item.id))

  return items.map((item) => {
    const directChildren = children.get(item.id) ?? []
    const summary = summaries.get(item.id) ?? taskProgress(item)
    const isEmptyMainTask = item.taskType === 'main' && directChildren.length === 0
    return {
      ...item,
      sortOrder: item.sortOrder ?? 0,
      startTime: minuteTime(item.startTime),
      endTime: minuteTime(item.endTime),
      progressPercent: isEmptyMainTask ? 100 : summary.total > 0 ? summary.completed * 100 / summary.total : 0,
      progressTotal: formatStoredAmount(summary.total),
      progressCompleted: formatStoredAmount(summary.completed),
      progressStep: directChildren.length === 0 ? formatStoredAmount(summary.step) : null,
      progressUnit: summary.unit,
      progressConfigTotal: formatStoredAmount(item.progressTotal ?? 0),
      progressConfigCompleted: formatStoredAmount(item.progressCompleted ?? 0),
      progressConfigStep: formatStoredAmount(item.progressStep ?? 0),
      progressConfigUnit: item.progressUnit ?? '',
      subtaskTotal: directChildren.length,
      subtaskCompleted: directChildren.filter((child) => {
        const childSummary = summaries.get(child.id)
        return Boolean(childSummary && childSummary.total > 0 && childSummary.completed >= childSummary.total)
      }).length,
    }
  })
}

export async function getTasks() {
  const { data } = await http.get<ApiResponse<TaskRecord[]>>('/tasks')
  return buildTasks(data.data)
}

export async function createTask(payload: CreateTaskPayload): Promise<void> {
  await http.post('/tasks', normalizeTaskTimePayload(payload))
}

export async function updateTask(taskId: number, payload: UpdateTaskPayload): Promise<void> {
  await http.patch(`/tasks/${taskId}`, normalizeTaskTimePayload(payload))
}

export async function updateTaskProgress(taskId: number, payload: ProgressOperationPayload) {
  await http.patch(`/tasks/${taskId}/progress`, payload)
}

export async function reorderTasks(payload: ReorderTasksPayload): Promise<void> {
  await http.put('/tasks/reorder', payload)
}

export async function deleteTask(taskId: number, cascade = false) {
  const { data } = await http.delete<ApiResponse<null>>(`/tasks/${taskId}`, { params: cascade ? { cascade: true } : undefined })
  return data.data
}
