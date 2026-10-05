import { http } from './http'
import type { ApiResponse } from '@/types/api'
import type { CreateTaskPayload, ProgressOperationPayload, ReorderTasksPayload, Task, TaskRecord, UpdateTaskPayload } from '@/types/task'

interface ProgressSummary {
  total: number
  completed: number
  step: number
  unit: string
}

/** 格式化存储数量；参数value为有限数值；返回最多两位小数文本，无副作用。 */
function formatStoredAmount(value: number) {
	if (Number.isInteger(value)) return String(value)
	return value.toFixed(2).replace(/0+$/, '').replace(/\.$/, '')
}

/** 规范化时分；参数value为服务端时间文本；返回HH:mm或空串，无副作用。 */
function minuteTime(value: string) {
  return value ? value.slice(0, 5) : ''
}

/** 规范化创建时间白名单；参数payload为创建字段；返回保留未提交字段的HH:mm请求，无副作用。 */
function normalizeTaskTimePayload(payload: CreateTaskPayload): CreateTaskPayload
/** 规范化部分更新时间；参数payload为提交字段；返回保留未提交字段的HH:mm请求，无副作用。 */
function normalizeTaskTimePayload(payload: UpdateTaskPayload): UpdateTaskPayload
/** 实施时间规范化；参数payload为创建或PATCH字段；返回新字典，不改调用者草稿。 */
function normalizeTaskTimePayload(payload: CreateTaskPayload | UpdateTaskPayload) {
  return {
    ...payload,
    ...(payload.startTime === undefined ? {} : { startTime: minuteTime(payload.startTime) }),
    ...(payload.endTime === undefined ? {} : { endTime: minuteTime(payload.endTime) }),
  }
}

/** 构建展示任务；参数items为原始任务快照；返回具体叶量化求和后的树节点，空主任务为0/0，不改原始配置。 */
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
  // 叶数量回调输入原任务、输出配置进度；主任务自身配置不参与实际叶求和。
  const taskProgress = (item: TaskRecord): ProgressSummary => ({
    total: item.progressTotal ?? 0,
    completed: item.progressCompleted ?? 0,
    step: item.progressStep ?? 0,
    unit: item.progressUnit?.trim() ?? '',
  })
  // 汇总回调输入节点ID、输出量化进度；循环与空主节点贡献零，归档不影响汇总。
  const summarize = (id: number): ProgressSummary => {
    const cached = summaries.get(id)
    if (cached) return cached

    const item = itemsById.get(id)
    if (!item) return { total: 0, completed: 0, step: 0, unit: '' }
    if (visiting.has(id)) return { total: 0, completed: 0, step: 0, unit: '' }

    visiting.add(id)
    // 归档只控制任务的显示与可操作状态，不能从父级进度汇总中排除。
    const directChildren = children.get(id) ?? []
    let summary: ProgressSummary
    if (directChildren.length === 0) {
      summary = item.taskType === 'main' ? { total: 0, completed: 0, step: 0, unit: '' } : taskProgress(item)
    } else {
      const childSummaries = directChildren.map(child => summarize(child.id)).filter(child => child.total > 0)
      const firstUnit = childSummaries[0]?.unit.trim() ?? ''
      summary = {
        total: childSummaries.reduce((total, child) => total + Math.round(child.total * 100), 0) / 100,
        completed: childSummaries.reduce((completed, child) => completed + Math.round(child.completed * 100), 0) / 100,
        step: 0,
        unit: firstUnit && childSummaries.every(child => child.unit.trim() === firstUnit) ? firstUnit : '',
      }
    }
    visiting.delete(id)
    summaries.set(id, summary)
    return summary
  }
  items.forEach(item => summarize(item.id))

  // 转换回调输入原节点、输出展示节点；保留原配置供编辑，展示进度只含实际叶数量。
  return items.map((item) => {
    const directChildren = children.get(item.id) ?? []
    const summary = summaries.get(item.id) ?? taskProgress(item)
    return {
      ...item,
      sortOrder: item.sortOrder ?? 0,
      startTime: minuteTime(item.startTime),
      endTime: minuteTime(item.endTime),
      progressPercent: summary.total > 0 ? summary.completed * 100 / summary.total : 0,
      progressTotal: formatStoredAmount(summary.total),
      progressCompleted: formatStoredAmount(summary.completed),
      progressStep: item.taskType === 'subtask' && directChildren.length === 0 ? formatStoredAmount(summary.step) : null,
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

/** 读取任务；参数无；返回规范化任务快照，网络错误抛出。 */
export async function getTasks() {
  const { data } = await http.get<ApiResponse<TaskRecord[]>>('/tasks')
  return buildTasks(data.data)
}

/** 创建任务；参数payload为校验后字段；返回无，写入失败抛出，不自动重试。 */
export async function createTask(payload: CreateTaskPayload): Promise<void> {
  await http.post('/tasks', normalizeTaskTimePayload(payload))
}

/** 部分更新任务；参数taskId为目标，payload为提交字段；返回无，服务端同事务处理整树归属。 */
export async function updateTask(taskId: number, payload: UpdateTaskPayload): Promise<void> {
  await http.patch(`/tasks/${taskId}`, normalizeTaskTimePayload(payload))
}

/** 更新叶进度；参数taskId为目标，payload为单步操作；返回无，业务拒绝抛出。 */
export async function updateTaskProgress(taskId: number, payload: ProgressOperationPayload) {
  await http.patch(`/tasks/${taskId}/progress`, payload)
}

/** 保存排序；参数payload为目标ID序列；返回无，错误抛出。 */
export async function reorderTasks(payload: ReorderTasksPayload): Promise<void> {
  await http.put('/tasks/reorder', payload)
}

/** 删除任务；参数taskId为目标，cascade为是否删除后代；返回删除响应，失败抛出。 */
export async function deleteTask(taskId: number, cascade = false) {
  const { data } = await http.delete<ApiResponse<null>>(`/tasks/${taskId}`, { params: cascade ? { cascade: true } : undefined })
  return data.data
}
