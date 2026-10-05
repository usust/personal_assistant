<script setup lang="ts">
import { confirmInPanel } from '@/composables/workspacePanels'
import WorkspacePanel from '@/components/WorkspacePanel.vue'
import { computed, onBeforeUnmount, onMounted, reactive, ref, watch } from 'vue'
import { ArrowDown, ArrowRight, Calendar, Check, Clock, Delete, Document, Edit, FolderOpened, Hide, Minus, MoreFilled, Plus, RefreshLeft, Search, View } from '@element-plus/icons-vue'
import { ElMessage } from 'element-plus'
import { createTaskList, deleteTaskList, getTaskLists, updateTaskList } from '@/api/taskLists'
import { createTask, deleteTask, getTasks, reorderTasks, updateTask, updateTaskProgress } from '@/api/tasks'
import { taskListIconOptions } from '@/data/taskListIcons'
import type { Task, TaskList, TaskPriority as Priority, TaskType } from '@/types/task'

const taskLists = ref<TaskList[]>([])
const tasks = ref<Task[]>([])
const activeViewStorageKey = 'personal-assistant:tasks:active-view'
const loadSavedActiveView = () => {
  try { return localStorage.getItem(activeViewStorageKey) || 'all' }
  catch { return 'all' }
}
const activeView = ref(loadSavedActiveView())
watch(activeView, (value) => {
  try { localStorage.setItem(activeViewStorageKey, value) }
  catch { /* 浏览器禁用本地存储时仍保持当前页面可用 */ }
})
const taskDialogVisible = ref(false)
const listDialogVisible = ref(false)
const remarkDialogTask = ref<Task | null>(null)
const remarkDialogVisible = computed({
  get: () => remarkDialogTask.value !== null,
  set: (visible: boolean) => { if (!visible) remarkDialogTask.value = null },
})
const parentLocked = ref(false)
const creatingUnderTaskId = ref<number | null>(null)
const editingTaskId = ref<number | null>(null)
const taskMoreVisible = ref(false)
const editingListId = ref<number | null>(null)
const customListColor = ref('#6B7280')
const collapsedTasks = ref(new Set<number>())
const pendingTasks = ref(new Set<number>())
const hiddenArchivedTasksStorageKey = 'personal-assistant:tasks:hidden-archived'
const loadHiddenArchivedTasks = () => {
  try {
    const ids: unknown = JSON.parse(localStorage.getItem(hiddenArchivedTasksStorageKey) || '[]')
    if (!Array.isArray(ids)) return new Set<number>()
    return new Set(ids.filter((id): id is number => Number.isInteger(id) && id > 0))
  } catch {
    return new Set<number>()
  }
}
const hiddenArchivedTasks = ref(loadHiddenArchivedTasks())
const inlineTimeDrafts = reactive<Record<string, string>>({})
const iconKeyword = ref('')
const iconSearchVisible = ref(false)
const loadError = ref(false)
const loadingTasks = ref(true)
const statusClock = ref(new Date())
let statusClockTimer: number | undefined
const draggedTaskId = ref<number | null>(null)
const dragTargetTaskId = ref<number | null>(null)
let dragHoldTimer: number | undefined
let dragPointerId: number | null = null
let dragStartX = 0
let dragStartY = 0
let dragLatestX = 0
let dragLatestY = 0
let dragSourceElement: HTMLElement | null = null
let dragGhostElement: HTMLElement | null = null
let dragGhostOffsetX = 0
let dragGhostOffsetY = 0
let tasksBeforeDrag: Task[] = []
let autoScrollFrame: number | undefined

const today = () => {
  const date = new Date()
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, '0')}-${String(date.getDate()).padStart(2, '0')}`
}
const deadlineStateFor = (date: string): 'none' | 'overdue' | 'today' | 'upcoming' => !date ? 'none' : date < today() ? 'overdue' : date === today() ? 'today' : 'upcoming'

const draft = reactive({
  title: '', remark: '', listId: 0, startDate: today(), startTime: '00:00', endDate: today(), endTime: '00:00',
  priority: 'medium' as Priority, parentId: null as number | null, taskType: 'main' as TaskType,
  progressTotal: '100', progressCompleted: '0', progressStep: '1', progressUnit: '',
})
const listDraft = reactive({ name: '', remark: '', color: '#6B7280', icon: 'Briefcase' })

const commonTaskListColors = [
  { value: '#EF4444', label: '红色' }, { value: '#F97316', label: '橙色' }, { value: '#EAB308', label: '黄色' },
  { value: '#22C55E', label: '绿色' }, { value: '#14B8A6', label: '青色' }, { value: '#3B82F6', label: '蓝色' },
  { value: '#6366F1', label: '靛蓝' }, { value: '#A855F7', label: '紫色' }, { value: '#EC4899', label: '粉色' },
  { value: '#6B7280', label: '灰色' },
]
const priorityLabels: Record<Priority, string> = {
  high: '高优先级',
  medium: '中优先级',
  low: '低优先级',
}
const taskListIconMap = Object.fromEntries(taskListIconOptions.map(option => [option.value, option.component]))
const legacyTaskListIcons: Record<string, string> = { Bicycle: 'Bike', CoffeeCup: 'Coffee', FirstAidKit: 'Stethoscope', Football: 'BallFootball', House: 'Home', Reading: 'Book', TrendCharts: 'ChartLine' }
const taskListIconComponent = (name: string) => taskListIconMap[name] ?? taskListIconMap[legacyTaskListIcons[name]] ?? taskListIconMap.Star
const visibleTaskListIcons = computed(() => {
  const keyword = iconKeyword.value.trim().toLowerCase()
  return keyword ? taskListIconOptions.filter(option => option.value.toLowerCase().includes(keyword) || option.label.includes(keyword)) : taskListIconOptions
})
const parentSelection = computed({
  get: () => draft.parentId ?? 0,
  set: (value: number) => { draft.parentId = value === 0 ? null : value },
})
// 父候选回调输入无、输出同清单主任务路径；排除自身与后代，历史原父关系由表单草稿保留，不自动迁移。
const eligibleParents = computed(() => {
  const listTasks = tasks.value.filter(task => task.listId === draft.listId)
  const tasksById = new Map(listTasks.map(task => [task.id, task]))
  const excluded = new Set<number>()

  if (editingTaskId.value !== null) {
    const children = new Map<number, number[]>()
    for (const task of listTasks) {
      if (task.parentId === null) continue
      const childIDs = children.get(task.parentId) ?? []
      childIDs.push(task.id)
      children.set(task.parentId, childIDs)
    }
    const queue = [editingTaskId.value]
    while (queue.length > 0) {
      const id = queue.shift()!
      if (excluded.has(id)) continue
      excluded.add(id)
      queue.push(...(children.get(id) ?? []))
    }
  }

  // 路径回调输入候选主任务、输出从根至候选的名称路径；环检测避免旧异常数据无限遍历。
  const pathLabel = (task: Task) => {
    const titles: string[] = []
    const visited = new Set<number>()
    let current: Task | undefined = task
    while (current && !visited.has(current.id)) {
      visited.add(current.id)
      titles.unshift(current.title)
      current = current.parentId === null ? undefined : tasksById.get(current.parentId)
    }
    return titles.join(' / ')
  }

  const originalParent = tasks.value.find(task => task.id === editingTaskId.value)?.parentId
  // 候选转换输入同清单节点、输出名称与禁用状态；旧具体父仅显示当前原关系，不允许作为新重挂目标。
  return listTasks
    .filter(task => !excluded.has(task.id) && (task.taskType === 'main' || task.id === originalParent))
    .map(task => ({ id: task.id, label: pathLabel(task), disabled: task.taskType !== 'main' }))
})

function taskCompleted(task: Task) {
  const total = Number(task.progressTotal || 0)
  return total > 0 && Number(task.progressCompleted || 0) >= total
}
function taskStarted(task: Task) {
  return Number(task.progressCompleted || 0) > 0
}
type TaskDisplayStatus = 'archived' | 'completed' | 'overdue' | 'not-started' | 'in-progress'
function taskStatusFor(task: Task): { key: TaskDisplayStatus; label: string } {
  if (task.archived) return { key: 'archived', label: '已归档' }
  if (taskCompleted(task)) return { key: 'completed', label: '已完成' }

  const now = statusClock.value
  const nowKey = `${now.getFullYear()}-${String(now.getMonth() + 1).padStart(2, '0')}-${String(now.getDate()).padStart(2, '0')} ${String(now.getHours()).padStart(2, '0')}:${String(now.getMinutes()).padStart(2, '0')}`
  const endKey = task.endDate ? `${task.endDate} ${task.endTime || '23:59'}` : ''
  const startKey = task.startDate ? `${task.startDate} ${task.startTime || '00:00'}` : ''
  if (endKey && endKey < nowKey) return { key: 'overdue', label: '已逾期' }
  if (startKey && startKey > nowKey) return { key: 'not-started', label: '未开始' }
  return { key: 'in-progress', label: '进行中' }
}
function hasStepControls(task: Task) {
  return task.taskType === 'subtask' && !task.archived && task.subtaskTotal === 0
}

const currentList = computed(() => activeView.value.startsWith('list:') ? taskLists.value.find(item => item.id === Number(activeView.value.slice(5))) : undefined)
const actionableTasks = computed(() => tasks.value.filter(task => task.subtaskTotal === 0 && !task.archived))
const smartViews = computed(() => [
  { key: 'all', label: '全部任务', count: tasks.value.length },
  { key: 'today', label: '今天', count: actionableTasks.value.filter(task => !taskCompleted(task) && deadlineStateFor(task.endDate) === 'today').length },
  { key: 'upcoming', label: '即将到期', count: actionableTasks.value.filter(task => !taskCompleted(task) && deadlineStateFor(task.endDate) === 'upcoming').length },
  { key: 'done', label: '已完成', count: actionableTasks.value.filter(taskCompleted).length },
  { key: 'archived', label: '已归档', count: tasks.value.filter(task => task.archived).length },
])
const amountNumber = (value: string) => Number(value || 0)
const formatNumber = (value: number) => Number.isInteger(value) ? String(value) : value.toFixed(2).replace(/0+$/, '').replace(/\.$/, '')
const overall = computed(() => actionableTasks.value.reduce((result, task) => {
  result.total += amountNumber(task.progressTotal)
  result.completed += amountNumber(task.progressCompleted)
  return result
}, { total: 0, completed: 0 }))
const progress = computed(() => overall.value.total ? Number((overall.value.completed / overall.value.total * 100).toFixed(2)) : 0)

function matchesFilter(task: Task) {
  if (activeView.value === 'archived') return task.archived
  if (archivedTaskHidden(task)) return false
  if (currentList.value) return task.listId === currentList.value.id
  if (activeView.value === 'all') return true
  if (task.archived) return false
  if (activeView.value === 'done') return taskCompleted(task)
  if (activeView.value === 'today' || activeView.value === 'upcoming') return deadlineStateFor(task.endDate) === activeView.value
  return !taskCompleted(task)
}

const visibleTasks = computed(() => {
  const rows: Array<{ task: Task; depth: number; hasChildren: boolean; contextOnly: boolean }> = []
  const treeTasks = tasks.value
  const taskIDs = new Set(treeTasks.map(task => task.id))
  const children = new Map<number, Task[]>()
  treeTasks.forEach((task) => {
    if (task.parentId === null) return
    const siblings = children.get(task.parentId) ?? []
    siblings.push(task)
    children.set(task.parentId, siblings)
  })
  const subtreeMatches = (task: Task): boolean => matchesFilter(task) || (children.get(task.id) ?? []).some(subtreeMatches)
  const appendTask = (task: Task, depth: number) => {
    const directChildren = children.get(task.id) ?? []
    const visibleChildren = directChildren.filter(subtreeMatches)
    const taskMatches = matchesFilter(task)
    if (!taskMatches && !visibleChildren.length) return
    if (activeView.value !== 'archived' && archivedTaskHidden(task)) {
      visibleChildren.forEach(child => appendTask(child, depth))
      return
    }
    rows.push({ task, depth, hasChildren: visibleChildren.length > 0, contextOnly: !taskMatches })
    if (!collapsedTasks.value.has(task.id)) visibleChildren.forEach(child => appendTask(child, depth + 1))
  }
  treeTasks
    .filter(task => task.parentId === null || !taskIDs.has(task.parentId))
    .forEach(task => appendTask(task, 0))
  return rows
})

function sameParent(left: Task, right: Task) {
  return left.parentId === right.parentId
}

function isTaskControl(target: EventTarget | null) {
  return target instanceof Element && Boolean(target.closest('button, input, textarea, select, a, [role="button"], .el-input, .el-dropdown'))
}

function clearDragHold() {
  if (dragHoldTimer !== undefined) window.clearTimeout(dragHoldTimer)
  dragHoldTimer = undefined
}

function updateDragGhost(clientX: number, clientY: number) {
  if (!dragGhostElement) return
  dragGhostElement.style.transform = `translate3d(${clientX - dragGhostOffsetX}px, ${clientY - dragGhostOffsetY}px, 0) scale(1.018)`
}

function beginTaskPointerDrag(row: { task: Task }, event: PointerEvent) {
  if (!event.isPrimary || event.button !== 0 || isPending(row.task.id) || isTaskControl(event.target)) return
  clearDragHold()
  dragPointerId = event.pointerId
  dragStartX = event.clientX
  dragStartY = event.clientY
  dragLatestX = event.clientX
  dragLatestY = event.clientY
  dragSourceElement = event.currentTarget as HTMLElement
  dragHoldTimer = window.setTimeout(() => {
    if (dragPointerId !== event.pointerId || !dragSourceElement) return
    draggedTaskId.value = row.task.id
    dragTargetTaskId.value = row.task.id
    tasksBeforeDrag = [...tasks.value]

    const rect = dragSourceElement.getBoundingClientRect()
    dragGhostOffsetX = event.clientX - rect.left
    dragGhostOffsetY = event.clientY - rect.top
    dragGhostElement = dragSourceElement.cloneNode(true) as HTMLElement
    dragGhostElement.classList.add('task-drag-ghost')
    dragGhostElement.style.width = `${rect.width}px`
    dragGhostElement.style.height = `${rect.height}px`
    document.body.appendChild(dragGhostElement)
    document.body.classList.add('task-reordering-active')
    updateDragGhost(event.clientX, event.clientY)
    if ('vibrate' in navigator) navigator.vibrate(12)
    startTaskAutoScroll()
  }, 240)
}

function reorderTaskOver(destinationID: number) {
  const sourceID = draggedTaskId.value
  if (sourceID === null || sourceID === destinationID || dragTargetTaskId.value === destinationID) return
  const source = tasks.value.find(task => task.id === sourceID)
  const destination = tasks.value.find(task => task.id === destinationID)
  if (!source || !destination || !sameParent(source, destination)) return

  const next = [...tasks.value]
  const sourceIndex = next.findIndex(task => task.id === sourceID)
  const destinationIndex = next.findIndex(task => task.id === destinationID)
  const [moved] = next.splice(sourceIndex, 1)
  if (!moved) return
  const adjustedDestination = destinationIndex > sourceIndex ? destinationIndex - 1 : destinationIndex
  const insertionIndex = sourceIndex < destinationIndex ? adjustedDestination + 1 : adjustedDestination
  next.splice(insertionIndex, 0, moved)
  tasks.value = next
  dragTargetTaskId.value = destinationID
  if ('vibrate' in navigator) navigator.vibrate(5)
}

function taskPointerMove(event: PointerEvent) {
  if (dragPointerId !== event.pointerId) return
  dragLatestX = event.clientX
  dragLatestY = event.clientY
  if (draggedTaskId.value === null) {
    if (Math.hypot(event.clientX - dragStartX, event.clientY - dragStartY) > 8) {
      clearDragHold()
      dragPointerId = null
      dragSourceElement = null
    }
    return
  }

  event.preventDefault()
  updateDragGhost(event.clientX, event.clientY)
  const target = document.elementFromPoint(event.clientX, event.clientY)?.closest<HTMLElement>('[data-task-id]')
  const destinationID = Number(target?.dataset.taskId)
  if (Number.isInteger(destinationID) && destinationID > 0) reorderTaskOver(destinationID)
}

function startTaskAutoScroll() {
  if (autoScrollFrame !== undefined) return
  const tick = () => {
    if (draggedTaskId.value === null) {
      autoScrollFrame = undefined
      return
    }
    const edge = Math.min(110, window.innerHeight * 0.16)
    const topDistance = dragLatestY
    const bottomDistance = window.innerHeight - dragLatestY
    const speed = topDistance < edge
      ? -Math.ceil((1 - topDistance / edge) * 16)
      : bottomDistance < edge
        ? Math.ceil((1 - bottomDistance / edge) * 16)
        : 0
    if (speed) {
      window.scrollBy(0, speed)
      const target = document.elementFromPoint(dragLatestX, dragLatestY)?.closest<HTMLElement>('[data-task-id]')
      const destinationID = Number(target?.dataset.taskId)
      if (Number.isInteger(destinationID) && destinationID > 0) reorderTaskOver(destinationID)
    }
    autoScrollFrame = window.requestAnimationFrame(tick)
  }
  autoScrollFrame = window.requestAnimationFrame(tick)
}

function cleanTaskDragVisuals() {
  clearDragHold()
  dragGhostElement?.remove()
  dragGhostElement = null
  document.body.classList.remove('task-reordering-active')
  draggedTaskId.value = null
  dragTargetTaskId.value = null
  dragPointerId = null
  dragSourceElement = null
  if (autoScrollFrame !== undefined) window.cancelAnimationFrame(autoScrollFrame)
  autoScrollFrame = undefined
}

function finishTaskPointerDrag(event: PointerEvent, commit: boolean) {
  if (dragPointerId !== event.pointerId) return
  const sourceID = draggedTaskId.value
  const previousTasks = tasksBeforeDrag
  if (sourceID === null) {
    cleanTaskDragVisuals()
    return
  }
  event.preventDefault()
  const source = tasks.value.find(task => task.id === sourceID)
  const siblingIDs = source ? tasks.value.filter(task => task.parentId === source.parentId).map(task => task.id) : []
  cleanTaskDragVisuals()
  if (!commit || !source) {
    tasks.value = previousTasks
    return
  }
  void reorderTasks({ taskIds: siblingIDs }).catch(() => {
    tasks.value = previousTasks
    ElMessage.error('排序保存失败，已恢复原顺序')
  })
}

function suppressTaskContextMenu(event: MouseEvent) {
  if (dragPointerId !== null || draggedTaskId.value !== null) event.preventDefault()
}

function taskPointerUp(event: PointerEvent) {
  finishTaskPointerDrag(event, true)
}

function taskPointerCancel(event: PointerEvent) {
  finishTaskPointerDrag(event, false)
}

const isPending = (id: number) => pendingTasks.value.has(id)
const inlineTimeKey = (taskId: number, kind: 'start' | 'end') => `${taskId}:${kind}`
const inlineTimeValue = (task: Task, kind: 'start' | 'end') => inlineTimeDrafts[inlineTimeKey(task.id, kind)] ?? task[`${kind}Time`]

function updateInlineTimeDraft(task: Task, kind: 'start' | 'end', value: string | null) {
  if (value) inlineTimeDrafts[inlineTimeKey(task.id, kind)] = value
}
function handleInlineTimeVisible(task: Task, kind: 'start' | 'end', visible: boolean) {
  const key = inlineTimeKey(task.id, kind)
  if (visible) inlineTimeDrafts[key] = task[`${kind}Time`]
  else window.setTimeout(() => {
    if (!isPending(task.id)) delete inlineTimeDrafts[key]
  }, 0)
}

function setPending(ids: Array<number | null | undefined>, pending: boolean) {
  const next = new Set(pendingTasks.value)
  ids.forEach((id) => { if (id) pending ? next.add(id) : next.delete(id) })
  pendingTasks.value = next
}
function toggleTaskCollapse(id: number) {
  const next = new Set(collapsedTasks.value)
  next.has(id) ? next.delete(id) : next.add(id)
  collapsedTasks.value = next
}
function persistHiddenArchivedTasks() {
  try { localStorage.setItem(hiddenArchivedTasksStorageKey, JSON.stringify([...hiddenArchivedTasks.value])) }
  catch { /* 浏览器禁用本地存储时仍保持当前页面可用 */ }
}
function archivedTaskHidden(task: Task) {
  return task.archived && hiddenArchivedTasks.value.has(task.id)
}
function setArchivedTaskHidden(id: number, hidden: boolean) {
  const next = new Set(hiddenArchivedTasks.value)
  hidden ? next.add(id) : next.delete(id)
  hiddenArchivedTasks.value = next
  persistHiddenArchivedTasks()
}
function toggleArchivedTaskVisibility(task: Task) {
  const hidden = !archivedTaskHidden(task)
  setArchivedTaskHidden(task.id, hidden)
  ElMessage.success(hidden ? '归档任务已从常规视图隐藏，可在“已归档”中重新显示' : '归档任务已重新显示到常规视图')
}
function pruneHiddenArchivedTasks() {
  const archivedIDs = new Set(tasks.value.filter(task => task.archived).map(task => task.id))
  const next = new Set([...hiddenArchivedTasks.value].filter(id => archivedIDs.has(id)))
  if (next.size === hiddenArchivedTasks.value.size) return
  hiddenArchivedTasks.value = next
  persistHiddenArchivedTasks()
}
function closeIconSearchIfEmpty() { if (!iconKeyword.value) iconSearchVisible.value = false }
function closeIconSearch() { iconKeyword.value = ''; iconSearchVisible.value = false }

async function loadData() {
  loadingTasks.value = true
  loadError.value = false
  const [lists, taskItems] = await Promise.allSettled([getTaskLists(), getTasks()])
  taskLists.value = lists.status === 'fulfilled' ? lists.value : []
  tasks.value = taskItems.status === 'fulfilled' ? taskItems.value : []
  pruneHiddenArchivedTasks()
  if (lists.status === 'fulfilled' && activeView.value.startsWith('list:') && !taskLists.value.some(item => `list:${item.id}` === activeView.value)) activeView.value = 'all'
  loadError.value = taskItems.status === 'rejected'
  loadingTasks.value = false
}
onMounted(() => {
  loadData()
  statusClockTimer = window.setInterval(() => { statusClock.value = new Date() }, 30_000)
  window.addEventListener('pointermove', taskPointerMove, { passive: false })
  window.addEventListener('pointerup', taskPointerUp)
  window.addEventListener('pointercancel', taskPointerCancel)
})
onBeforeUnmount(() => {
  if (statusClockTimer !== undefined) window.clearInterval(statusClockTimer)
  window.removeEventListener('pointermove', taskPointerMove)
  window.removeEventListener('pointerup', taskPointerUp)
  window.removeEventListener('pointercancel', taskPointerCancel)
  cleanTaskDragVisuals()
})

function resetTaskDraft() {
  taskMoreVisible.value = false
  creatingUnderTaskId.value = null
  Object.assign(draft, { title: '', remark: '', startDate: today(), startTime: '00:00', endDate: today(), endTime: '00:00', priority: 'medium', parentId: null, taskType: 'main', progressTotal: '100', progressCompleted: '0', progressStep: '1', progressUnit: '' })
}
function clearTaskTime(kind: 'start' | 'end') {
  if (kind === 'start') Object.assign(draft, { startDate: '', startTime: '' })
  else Object.assign(draft, { endDate: '', endTime: '' })
}
/** 打开创建草稿；参数parentId为可选主父任务，listId为清单上下文；返回无，仅主任务允许新下级，普通创建不锁归属。 */
function openTaskEditor(parentId: number | null = null, listId?: number) {
  const parent = tasks.value.find(task => task.id === parentId)
  if (parentId !== null && (!parent || parent.taskType !== 'main' || parent.archived)) return
  resetTaskDraft()
  editingTaskId.value = null
  parentLocked.value = Boolean(parent)
  draft.listId = listId ?? parent?.listId ?? 0
  if (parent) {
    creatingUnderTaskId.value = parent.id
    Object.assign(draft, { taskType: 'subtask', parentId: parent.id, priority: parent.priority, startDate: parent.startDate, startTime: parent.startTime, endDate: parent.endDate, endTime: parent.endTime, progressUnit: parent.progressUnit === '工作量' ? '' : parent.progressUnit })
  }
  taskDialogVisible.value = true
}
function openTaskInfoEditor(task: Task) {
  resetTaskDraft()
  editingTaskId.value = task.id
  parentLocked.value = true
  taskMoreVisible.value = task.taskType === 'subtask'
  Object.assign(draft, {
    title: task.title,
    remark: task.remark,
    listId: task.listId,
    startDate: task.startDate,
    startTime: task.startTime,
    endDate: task.endDate,
    endTime: task.endTime,
    priority: task.priority,
    parentId: task.parentId,
    taskType: task.taskType,
    progressTotal: task.taskType === 'subtask' ? task.progressConfigTotal : '100',
    progressCompleted: task.taskType === 'subtask' ? task.progressConfigCompleted : '0',
    progressStep: task.taskType === 'subtask' ? task.progressConfigStep : '1',
    progressUnit: task.taskType === 'subtask' ? task.progressConfigUnit : '',
  })
  taskDialogVisible.value = true
}
function openTaskRemark(task: Task) {
  remarkDialogTask.value = task
}
function changeTaskType(type: TaskType) {
  draft.taskType = type
  if (editingTaskId.value !== null) taskMoreVisible.value = type === 'subtask'
}
function validProgressDraft() {
  const values = [draft.progressTotal, draft.progressCompleted, draft.progressStep]
  if (!values.every(value => /^\d+(\.\d{1,2})?$/.test(value))) return false
  const total = amountNumber(draft.progressTotal)
  const completed = amountNumber(draft.progressCompleted)
  const step = amountNumber(draft.progressStep)
  return total > 0 && completed >= 0 && completed <= total && step > 0 && step <= total
}
async function saveTask() {
  const isCreating = editingTaskId.value === null
  const parentId = draft.parentId
  const isSubtask = draft.taskType === 'subtask'
  if (!draft.title.trim() || !draft.listId || (isSubtask && (!validProgressDraft() || (isCreating && !parentId)))) return
  if (draft.startDate && draft.endDate && `${draft.startDate} ${draft.startTime || '00:00'}` > `${draft.endDate} ${draft.endTime || '23:59'}`) return ElMessage.warning('结束时间不能早于开始时间')
  try {
    const commonPayload = { title: draft.title.trim(), remark: draft.remark.trim(), startDate: draft.startDate, startTime: draft.startTime, endDate: draft.endDate, endTime: draft.endTime, priority: draft.priority }
    if (isCreating) {
      const progressPayload = isSubtask ? { progressTotal: draft.progressTotal, progressCompleted: draft.progressCompleted, progressStep: draft.progressStep, progressUnit: draft.progressUnit.trim() } : {}
      await createTask({ ...commonPayload, listId: draft.listId, parentId, taskType: draft.taskType, ...progressPayload })
      tasks.value = await getTasks()
    } else {
      const progressPayload = isSubtask ? { progressTotal: draft.progressTotal, progressCompleted: draft.progressCompleted, progressStep: draft.progressStep, progressUnit: draft.progressUnit.trim() } : {}
      await updateTask(editingTaskId.value!, { ...commonPayload, parentId, taskType: draft.taskType, ...progressPayload })
      tasks.value = await getTasks()
    }
    taskDialogVisible.value = false
    ElMessage.success(isCreating ? (isSubtask ? '子任务已创建' : '任务已创建') : (isSubtask ? '子任务已更新' : '任务已更新'))
  } catch {}
}

// quickIncrement 为任务增加一步，最后不足一步时补齐总量。
// 参数：task 为当前用户可执行的叶子任务；返回值：异步完成，无结果；更新远端进度并刷新列表，失败由请求层提示。
async function quickIncrement(task: Task) {
  setPending([task.id, task.parentId], true)
  try { await updateTaskProgress(task.id, { operation: 'increment', allowExceedTotal: true }); tasks.value = await getTasks(); ElMessage.success('进度已增加一个 Step') }
  catch {}
  finally { setPending([task.id, task.parentId], false) }
}
async function quickDecrement(task: Task) {
  setPending([task.id, task.parentId], true)
  try { await updateTaskProgress(task.id, { operation: 'decrement' }); tasks.value = await getTasks(); ElMessage.success('进度已减少一个 Step') }
  catch {}
  finally { setPending([task.id, task.parentId], false) }
}
/** 切换任务归档状态。参数：task 为当前任务；返回值：完成 Promise。归档需右栏确认，取消时不更新。 */
async function toggleTaskArchived(task: Task) {
  const archived = !task.archived
  if (archived) try { await confirmInPanel(`归档后任务仍会保留，其进度继续计入上级任务完成度，并可单独隐藏显示内容。确定归档“${task.title}”吗？`, '归档任务', { type: 'info', confirmButtonText: '确认归档' }) } catch { return }
  setPending([task.id, task.parentId], true)
  try {
    await updateTask(task.id, { archived })
    tasks.value = await getTasks()
    if (!archived) setArchivedTaskHidden(task.id, false)
    ElMessage.success(archived ? '任务已归档，并在清单中弱化显示' : '任务已恢复，可继续编辑')
  } catch {}
  finally { setPending([task.id, task.parentId], false) }
}
async function updateTaskDateTimePart(task: Task, kind: 'start' | 'end', part: 'date' | 'time', value: string | null) {
  if (!value || isPending(task.id)) return
  const field = `${kind}${part === 'date' ? 'Date' : 'Time'}` as 'startDate' | 'startTime' | 'endDate' | 'endTime'
  if (task[field] === value) return
  const dateTime: Partial<Pick<Task, 'startDate' | 'startTime' | 'endDate' | 'endTime'>> = { [field]: value }
  const startDate = dateTime.startDate ?? task.startDate
  const startTime = dateTime.startTime ?? task.startTime
  const endDate = dateTime.endDate ?? task.endDate
  const endTime = dateTime.endTime ?? task.endTime
  if (startDate && endDate && `${startDate} ${startTime || '00:00'}` > `${endDate} ${endTime || '23:59'}`) {
    ElMessage.warning('结束时间不能早于开始时间')
    return
  }
  setPending([task.id, task.parentId], true)
  try {
    await updateTask(task.id, { [field]: value })
    tasks.value = await getTasks()
    ElMessage.success(`${kind === 'start' ? '开始' : '结束'}${part === 'date' ? '日期' : '时间'}已更新`)
  } catch {}
  finally {
    setPending([task.id, task.parentId], false)
    if (part === 'time') delete inlineTimeDrafts[inlineTimeKey(task.id, kind)]
  }
}
/** 删除任务及其下级。参数：task 为待删除任务；返回值：完成 Promise。需右栏确认，失败由请求层提示。 */
async function removeTask(task: Task) {
  const cascade = task.subtaskTotal > 0
  try { await confirmInPanel(cascade ? `确定删除任务“${task.title}”及其全部下级任务吗？` : `确定删除任务“${task.title}”吗？`, '删除任务', { type: 'warning', confirmButtonText: '确认删除' }) } catch { return }
  await deleteTask(task.id, cascade)
  setArchivedTaskHidden(task.id, false)
  tasks.value = await getTasks()
  ElMessage.success('任务已删除')
}

function openListEditor(item?: TaskList) {
  editingListId.value = item?.id ?? null; listDraft.name = item?.name ?? ''; listDraft.remark = item?.remark ?? ''; listDraft.color = item?.color ?? '#6B7280'; customListColor.value = item?.color ?? '#6B7280'; listDraft.icon = item?.icon ?? 'Briefcase'; iconKeyword.value = ''; iconSearchVisible.value = false; listDialogVisible.value = true
}
function chooseCustomListColor(color: string | null) { if (color) listDraft.color = color }
async function saveTaskList() {
  const name = listDraft.name.trim()
  if (!name) return
  if (taskLists.value.some(item => item.name === name && item.id !== editingListId.value)) return ElMessage.warning('任务清单名称不能重复')
  try {
    const payload = { name, remark: listDraft.remark.trim(), color: listDraft.color, icon: listDraft.icon.trim() }
    if (editingListId.value === null) { const item = await createTaskList(payload); taskLists.value.push(item); activeView.value = `list:${item.id}`; ElMessage.success('任务清单已创建') }
    else { const item = await updateTaskList(editingListId.value, payload); const index = taskLists.value.findIndex(current => current.id === item.id); if (index !== -1) taskLists.value[index] = item; ElMessage.success('任务清单已更新') }
    listDialogVisible.value = false
  } catch { /* HTTP 拦截器统一提示 */ }
}
/** 删除任务及其下级。参数：task 为待删除任务；返回值：完成 Promise。需右栏确认，失败由请求层提示。 */
/** 删除任务清单及所属任务。参数：item 为待删除清单；返回值：完成 Promise。需右栏确认，取消不写入。 */
async function removeTaskList(item: TaskList) {
  const taskCount = tasks.value.filter(task => task.listId === item.id).length
  try { await confirmInPanel(`确定删除任务清单“${item.name}”和其中 ${taskCount} 项任务吗？此操作无法撤销。`, '删除任务清单', { type: 'warning', confirmButtonText: '确认删除' }) } catch { return }
  await deleteTaskList(item.id); tasks.value = tasks.value.filter(task => task.listId !== item.id); taskLists.value = taskLists.value.filter(current => current.id !== item.id); if (currentList.value?.id === item.id) activeView.value = 'all'; ElMessage.success('任务清单已删除')
}
</script>

<template>
  <div class="task-summary-grid">
    <article class="task-summary-card"><span class="summary-icon blue"><Calendar /></span><div><strong>{{ smartViews[1].count }}</strong><p>今日待办</p></div></article>
    <article class="task-summary-card"><span class="summary-icon orange"><Clock /></span><div><strong>{{ actionableTasks.filter(t => !taskCompleted(t) && deadlineStateFor(t.endDate) === 'overdue').length }}</strong><p>已逾期</p></div></article>
    <article class="task-summary-card progress-card"><div class="progress-copy"><span><strong>{{ progress }}%</strong><small>整体完成度</small></span><em>{{ formatNumber(overall.completed) }} / {{ formatNumber(overall.total) }} 工作量</em></div><el-progress :percentage="progress" :show-text="false" :stroke-width="7" /></article>
  </div>
  <section class="task-workspace">
    <aside class="task-views">
      <p class="task-views-title">智能视图</p><button v-for="view in smartViews" :key="view.key" :class="{ active: activeView === view.key }" @click="activeView = view.key"><span>{{ view.label }}</span><b>{{ view.count }}</b></button>
      <div class="task-list-heading"><span>任务清单</span><el-button text circle :icon="Plus" aria-label="新建任务清单" @click="openListEditor()" /></div>
      <div v-for="item in taskLists" :key="item.id" :class="['task-list-tree-row', { active: activeView === `list:${item.id}` }]" :style="{ '--list-depth': 0 }">
        <span class="task-list-collapse"><component :is="taskListIconComponent(item.icon)" /></span><button class="task-list-select" @click="activeView = `list:${item.id}`"><span>{{ item.name }}</span></button>
        <div class="inline-actions"><div class="inline-action-buttons"><button aria-label="新建主任务" title="新建主任务" @click="openTaskEditor(null, item.id)"><Plus /></button><button aria-label="修改清单" @click="openListEditor(item)"><Edit /></button><button class="danger" aria-label="删除清单" @click="removeTaskList(item)"><Delete /></button></div></div>
      </div>
    </aside>
    <div class="task-list-panel">
      <div v-if="loadingTasks" class="task-empty"><span><Clock /></span><h3>正在加载任务</h3><p>请稍候……</p></div>
      <div v-else-if="loadError" class="task-empty"><span><Clock /></span><h3>任务加载失败</h3><p><el-button text type="primary" @click="loadData">重新加载</el-button></p></div>
      <TransitionGroup v-else-if="visibleTasks.length" name="task-reorder" tag="div" class="task-list">
        <article v-for="row in visibleTasks" :key="row.task.id" :data-task-id="row.task.id" :class="['task-row', { completed: taskCompleted(row.task), archived: row.task.archived, 'context-only': row.contextOnly, nested: row.depth > 0, 'drag-source': draggedTaskId === row.task.id }]" :style="{ '--task-depth': row.depth }" @pointerdown="beginTaskPointerDrag(row, $event)" @contextmenu="suppressTaskContextMenu">
          <button v-if="row.hasChildren" :class="['task-expand', { collapsed: collapsedTasks.has(row.task.id) }]" @click="toggleTaskCollapse(row.task.id)"><ArrowRight /></button><span v-else class="task-expand-placeholder"></span>
          <div class="task-main">
            <div class="task-header">
              <div class="task-heading-cluster">
                <div class="task-title-line"><span :class="['task-status-tag', taskStatusFor(row.task).key]">{{ taskStatusFor(row.task).label }}</span><span :class="['task-priority-tag', row.task.priority]">{{ priorityLabels[row.task.priority] }}</span><h3>{{ row.task.title }}</h3><span class="task-type-tag">{{ row.task.taskType === 'main' ? '主任务' : '子任务' }}</span><span v-if="archivedTaskHidden(row.task)" class="task-visibility-tag"><Hide />已隐藏</span></div>
                <div class="task-meta"><span class="task-meta-chip task-inline-date-chip"><Calendar /><small>开始</small><el-date-picker class="task-inline-date-picker" :model-value="row.task.startDate" type="date" value-format="YYYY-MM-DD" format="YYYY.MM.DD" placeholder="日期" :clearable="false" :editable="false" :disabled="isPending(row.task.id) || row.task.archived" :aria-label="`修改${row.task.title}的开始日期`" @update:model-value="updateTaskDateTimePart(row.task, 'start', 'date', $event)" /><el-time-picker class="task-inline-date-picker task-inline-time-picker" :model-value="inlineTimeValue(row.task, 'start')" value-format="HH:mm" format="HH:mm" placeholder="时间" :clearable="false" :editable="false" :disabled="isPending(row.task.id) || row.task.archived" :aria-label="`修改${row.task.title}的开始时间`" @update:model-value="updateInlineTimeDraft(row.task, 'start', $event)" @visible-change="handleInlineTimeVisible(row.task, 'start', $event)" @change="updateTaskDateTimePart(row.task, 'start', 'time', $event)" /></span><span :class="['task-meta-chip', 'task-inline-date-chip', 'task-end-time', deadlineStateFor(row.task.endDate)]"><Clock /><small>结束</small><el-date-picker class="task-inline-date-picker" :model-value="row.task.endDate" type="date" value-format="YYYY-MM-DD" format="YYYY.MM.DD" placeholder="日期" :clearable="false" :editable="false" :disabled="isPending(row.task.id) || row.task.archived" :aria-label="`修改${row.task.title}的结束日期`" @update:model-value="updateTaskDateTimePart(row.task, 'end', 'date', $event)" /><el-time-picker class="task-inline-date-picker task-inline-time-picker" :model-value="inlineTimeValue(row.task, 'end')" value-format="HH:mm" format="HH:mm" placeholder="时间" :clearable="false" :editable="false" :disabled="isPending(row.task.id) || row.task.archived" :aria-label="`修改${row.task.title}的结束时间`" @update:model-value="updateInlineTimeDraft(row.task, 'end', $event)" @visible-change="handleInlineTimeVisible(row.task, 'end', $event)" @change="updateTaskDateTimePart(row.task, 'end', 'time', $event)" /></span></div>
              </div>
              <div class="task-hover-actions">
                <div class="task-row-actions">
                  <div v-if="hasStepControls(row.task)" class="task-step-controls">
                    <el-button class="task-step-adjust-button decrease" size="small" :icon="Minus" circle :disabled="isPending(row.task.id) || !taskStarted(row.task)" :aria-label="`为${row.task.title}减少一个 Step`" @click="quickDecrement(row.task)" />
                    <span class="task-step-progress"><span class="task-progress-track"><i :style="{ width: `${row.task.progressPercent}%` }"></i></span><strong>{{ Number(row.task.progressPercent.toFixed(2)) }}%</strong></span>
                    <el-button class="task-step-adjust-button increase" size="small" type="primary" plain :icon="Plus" circle :loading="isPending(row.task.id)" :disabled="taskCompleted(row.task)" :aria-label="`为${row.task.title}增加一个 Step`" @click="quickIncrement(row.task)" />
                  </div>
                  <div v-else class="task-step-controls task-step-controls-readonly"><span class="task-step-progress"><span class="task-progress-track"><i :style="{ width: `${row.task.progressPercent}%` }"></i></span><strong>{{ Number(row.task.progressPercent.toFixed(2)) }}%</strong></span></div>
                </div>
                <el-dropdown trigger="click" placement="bottom-end" popper-class="task-actions-popper" @click.stop>
                  <el-button class="task-more-action" size="small" :icon="MoreFilled" circle :disabled="isPending(row.task.id)" :aria-label="`展开${row.task.title}的操作菜单`" />
                  <template #dropdown>
                    <el-dropdown-menu>
                      <el-dropdown-item v-if="row.task.remark" :icon="Document" @click="openTaskRemark(row.task)">查看备注</el-dropdown-item>
                      <el-dropdown-item v-if="!row.task.archived" :icon="Edit" @click="openTaskInfoEditor(row.task)">编辑信息</el-dropdown-item>
                      <el-dropdown-item v-if="row.task.archived" :icon="archivedTaskHidden(row.task) ? View : Hide" @click="toggleArchivedTaskVisibility(row.task)">{{ archivedTaskHidden(row.task) ? '在常规视图显示' : '从常规视图隐藏' }}</el-dropdown-item>
                      <el-dropdown-item :icon="row.task.archived ? RefreshLeft : FolderOpened" @click="toggleTaskArchived(row.task)">{{ row.task.archived ? '恢复任务' : '归档任务' }}</el-dropdown-item>
                      <el-dropdown-item v-if="!row.task.archived && row.task.taskType === 'main'" :icon="Plus" @click="openTaskEditor(row.task.id)">添加下级任务</el-dropdown-item>
                      <el-dropdown-item class="task-action-danger" :icon="Delete" divided @click="removeTask(row.task)">删除任务</el-dropdown-item>
                    </el-dropdown-menu>
                  </template>
                </el-dropdown>
              </div>
            </div>
          </div>
        </article>
      </TransitionGroup>
      <div v-else class="task-empty"><span><Check /></span><h3>这里已经清空了</h3><p>换个视图，或在当前清单创建一项新任务。</p></div>
    </div>
  </section>

  <WorkspacePanel v-model="remarkDialogVisible" title="任务备注">
    <div v-if="remarkDialogTask" class="task-remark-dialog-content">
      <h3>{{ remarkDialogTask.title }}</h3>
      <p>{{ remarkDialogTask.remark }}</p>
    </div>
    <template #footer><el-button type="primary" @click="remarkDialogVisible = false">关闭</el-button></template>
  </WorkspacePanel>
  <WorkspacePanel v-model="taskDialogVisible" :title="editingTaskId === null ? (parentLocked ? '添加下级任务' : '新建任务') : '编辑任务'">
    <el-form label-position="top" @submit.prevent="saveTask">
      <el-form-item v-if="editingTaskId !== null || creatingUnderTaskId !== null" class="task-type-top" label="任务类型" required><el-radio-group :model-value="draft.taskType" @update:model-value="changeTaskType"><el-radio-button value="main">主任务</el-radio-button><el-radio-button value="subtask">子任务</el-radio-button></el-radio-group></el-form-item>
      <el-form-item label="任务名" required><el-input v-model="draft.title" maxlength="200" /></el-form-item><el-form-item label="任务备注"><el-input v-model="draft.remark" type="textarea" :rows="3" maxlength="1000" /></el-form-item>
      <div class="task-time-range"><el-form-item label="开始时间"><div class="task-time-fields"><el-date-picker v-model="draft.startDate" type="date" value-format="YYYY-MM-DD" format="YYYY-MM-DD" placeholder="" :clearable="false" /><el-time-picker v-model="draft.startTime" value-format="HH:mm" format="HH:mm" placeholder="" :disabled="!draft.startDate" clearable @clear="clearTaskTime('start')" /></div></el-form-item><el-form-item label="结束时间"><div class="task-time-fields"><el-date-picker v-model="draft.endDate" type="date" value-format="YYYY-MM-DD" format="YYYY-MM-DD" placeholder="" :clearable="false" /><el-time-picker v-model="draft.endTime" value-format="HH:mm" format="HH:mm" placeholder="" :disabled="!draft.endDate" clearable @clear="clearTaskTime('end')" /></div></el-form-item></div>
      <el-form-item label="优先级"><el-radio-group v-model="draft.priority"><el-radio-button value="high">高</el-radio-button><el-radio-button value="medium">中</el-radio-button><el-radio-button value="low">低</el-radio-button></el-radio-group></el-form-item>
      <el-form-item label="上级节点"><el-select v-model="parentSelection" filterable><el-option label="无上级节点（顶级）" :value="0" /><el-option v-for="parent in eligibleParents" :key="parent.id" :label="parent.label" :value="parent.id" :disabled="parent.disabled" /></el-select></el-form-item>
      <div v-if="draft.taskType === 'subtask'" class="task-more-settings"><button type="button" class="task-more-toggle" :aria-expanded="taskMoreVisible" @click="taskMoreVisible = !taskMoreVisible"><span>{{ taskMoreVisible ? '收起设置' : '更多设置' }}</span><ArrowDown :class="{ expanded: taskMoreVisible }" /></button><el-collapse-transition><div v-show="taskMoreVisible" class="progress-settings"><h4>进度设置</h4><div class="progress-input-grid"><el-form-item label="进度总量" required><el-input v-model="draft.progressTotal" /></el-form-item><el-form-item label="当前完成量" required><el-input v-model="draft.progressCompleted" /></el-form-item><el-form-item label="每次添加" required><el-input v-model="draft.progressStep" /></el-form-item><el-form-item label="单位（可选）"><el-input v-model="draft.progressUnit" maxlength="20" placeholder="如：页、次、小时" /></el-form-item></div><p v-if="!validProgressDraft()" class="progress-form-error">总量需大于 0，完成量不能超过总量，每次添加需在 0 与总量之间，最多保留两位小数。</p></div></el-collapse-transition></div>
    </el-form><template #footer><el-button @click="taskDialogVisible = false">取消</el-button><el-button type="primary" :disabled="!draft.title.trim() || !draft.listId || (draft.taskType === 'subtask' && (!validProgressDraft() || (editingTaskId === null && !draft.parentId)))" @click="saveTask">{{ editingTaskId === null ? '添加任务' : '保存修改' }}</el-button></template>
  </WorkspacePanel>
  <WorkspacePanel v-model="listDialogVisible" :title="editingListId === null ? '新建任务清单' : '编辑任务清单'"><el-form label-position="top" @submit.prevent="saveTaskList"><el-form-item label="清单名称" required><el-input v-model="listDraft.name" maxlength="128" show-word-limit /></el-form-item><el-form-item label="备注"><el-input v-model="listDraft.remark" type="textarea" :rows="1" maxlength="2000" show-word-limit /></el-form-item><el-form-item label="清单颜色" required><div class="task-list-color-field"><div class="task-list-color-options"><button v-for="color in commonTaskListColors" :key="color.value" type="button" class="task-list-color-swatch" :class="{ selected: listDraft.color.toUpperCase() === color.value }" :style="{ '--swatch-color': color.value }" :aria-label="color.label" @click="listDraft.color = color.value"><span></span></button><el-color-picker v-model="customListColor" @change="chooseCustomListColor" /></div></div></el-form-item><el-form-item required><template #label><span class="task-list-icon-label">清单图标<el-input v-if="iconSearchVisible" v-model="iconKeyword" class="task-list-icon-search-inline" clearable :prefix-icon="Search" placeholder="搜索图标" autofocus @keyup.esc="closeIconSearch" @blur="closeIconSearchIfEmpty" /><button v-else type="button" aria-label="搜索图标" @click="iconSearchVisible = true"><Search /></button></span></template><div class="task-list-icon-browser"><div class="task-list-icon-picker"><button v-for="option in visibleTaskListIcons" :key="option.value" type="button" :class="{ selected: listDraft.icon === option.value }" :aria-label="option.label" @click="listDraft.icon = option.value"><component :is="option.component" /></button></div></div></el-form-item></el-form><template #footer><el-button @click="listDialogVisible = false">取消</el-button><el-button type="primary" :disabled="!listDraft.name.trim() || !listDraft.color || !listDraft.icon.trim()" @click="saveTaskList">{{ editingListId === null ? '创建' : '保存' }}</el-button></template></WorkspacePanel>
</template>
