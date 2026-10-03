<script setup lang="ts">
import WorkspacePanel from '@/components/WorkspacePanel.vue'
import { computed, onBeforeUnmount, onMounted, ref } from 'vue'
import { ArrowLeft, ArrowRight, Calendar, Clock, Right } from '@element-plus/icons-vue'
import { getTaskLists } from '@/api/taskLists'
import { getTasks } from '@/api/tasks'
import type { Task, TaskList, TaskPriority } from '@/types/task'

interface CalendarDay {
  key: string
  day: number
  currentMonth: boolean
  today: boolean
}

interface CalendarEventSegment {
  task: Task
  startColumn: number
  span: number
  lane: number
  continuesBefore: boolean
  continuesAfter: boolean
}

interface CalendarWeek {
  days: CalendarDay[]
  segments: CalendarEventSegment[]
}

const weekDays = ['一', '二', '三', '四', '五', '六', '日']
const tasks = ref<Task[]>([])
const taskLists = ref<TaskList[]>([])
const loading = ref(true)
const loadError = ref(false)
const agendaVisible = ref(false)
const selectedDate = ref(dateKey(new Date()))
const visibleMonth = ref(monthStart(new Date()))
const lastSyncedAt = ref<Date | null>(null)

const priorityLabels: Record<TaskPriority, string> = {
  high: '高优先级',
  medium: '中优先级',
  low: '低优先级',
}

function dateKey(date: Date) {
  return [
    date.getFullYear(),
    String(date.getMonth() + 1).padStart(2, '0'),
    String(date.getDate()).padStart(2, '0'),
  ].join('-')
}

function dateFromKey(value: string) {
  const [year, month, day] = value.split('-').map(Number)
  return new Date(year, month - 1, day)
}

function monthStart(date: Date) {
  return new Date(date.getFullYear(), date.getMonth(), 1)
}

function safeTaskRange(task: Task) {
  const start = task.startDate || task.endDate
  const end = task.endDate || task.startDate
  if (!start || !end) return null
  return start <= end ? { start, end } : { start: end, end: start }
}

function taskCompleted(task: Task) {
  const total = Number(task.progressTotal || 0)
  return total > 0 && Number(task.progressCompleted || 0) >= total
}

function taskStatus(task: Task) {
  if (task.archived) return '已归档'
  if (taskCompleted(task)) return '已完成'
  if (task.endDate && task.endDate < dateKey(new Date())) return '已逾期'
  if (task.startDate && task.startDate > dateKey(new Date())) return '未开始'
  return '进行中'
}

function listFor(task: Task) {
  return taskLists.value.find(list => list.id === task.listId)
}

function listColor(task: Task) {
  return listFor(task)?.color || '#6B7280'
}

function tasksForDate(key: string) {
  return visibleTasks.value
    .filter((task) => {
      const range = safeTaskRange(task)
      return range && key >= range.start && key <= range.end
    })
    .sort((left, right) => {
      const leftRange = safeTaskRange(left)!
      const rightRange = safeTaskRange(right)!
      return leftRange.start.localeCompare(rightRange.start)
        || left.startTime.localeCompare(right.startTime)
        || left.id - right.id
    })
}

function eventSegmentsForWeek(days: CalendarDay[]): CalendarEventSegment[] {
  const weekStart = days[0].key
  const weekEnd = days[days.length - 1].key
  const laneEndColumns: number[] = []

  return visibleTasks.value
    .map((task) => ({ task, range: safeTaskRange(task)! }))
    .filter(({ range }) => range.start <= weekEnd && range.end >= weekStart)
    .sort((left, right) => left.range.start.localeCompare(right.range.start)
      || right.range.end.localeCompare(left.range.end)
      || left.task.id - right.task.id)
    .map(({ task, range }) => {
      const segmentStart = range.start < weekStart ? weekStart : range.start
      const segmentEnd = range.end > weekEnd ? weekEnd : range.end
      const startColumn = days.findIndex(day => day.key === segmentStart) + 1
      const endColumn = days.findIndex(day => day.key === segmentEnd) + 1
      let lane = laneEndColumns.findIndex(column => column < startColumn)
      if (lane === -1) lane = laneEndColumns.length
      laneEndColumns[lane] = endColumn
      return {
        task,
        startColumn,
        span: endColumn - startColumn + 1,
        lane,
        continuesBefore: range.start < weekStart,
        continuesAfter: range.end > weekEnd,
      }
    })
}

function formatTaskRange(task: Task) {
  const range = safeTaskRange(task)
  if (!range) return '未设置日期'
  const start = `${range.start}${task.startTime ? ` ${task.startTime}` : ''}`
  const end = `${range.end}${task.endTime ? ` ${task.endTime}` : ''}`
  return start === end ? start : `${start} — ${end}`
}

function progressText(task: Task) {
  const total = Number(task.progressTotal || 0)
  if (total <= 0) return task.taskType === 'main' ? '主任务' : '未设置进度'
  return `${Number(task.progressPercent.toFixed(2))}%`
}

function moveMonth(offset: number) {
  const target = new Date(visibleMonth.value.getFullYear(), visibleMonth.value.getMonth() + offset, 1)
  visibleMonth.value = target
  const selectedDay = dateFromKey(selectedDate.value).getDate()
  const lastDay = new Date(target.getFullYear(), target.getMonth() + 1, 0).getDate()
  selectedDate.value = dateKey(new Date(target.getFullYear(), target.getMonth(), Math.min(selectedDay, lastDay)))
}

/** 选择日期并展开日程。参数：day 为日历网格日期；返回值：无。 */
function selectDay(day: CalendarDay) {
  agendaVisible.value = true
  selectedDate.value = day.key
  if (!day.currentMonth) visibleMonth.value = monthStart(dateFromKey(day.key))
}

function goToday() {
  const now = new Date()
  visibleMonth.value = monthStart(now)
  selectedDate.value = dateKey(now)
}

async function loadData() {
  loading.value = true
  loadError.value = false
  try {
    const [taskItems, listItems] = await Promise.all([getTasks(), getTaskLists()])
    tasks.value = taskItems
    taskLists.value = listItems
    lastSyncedAt.value = new Date()
  } catch {
    loadError.value = true
  } finally {
    loading.value = false
  }
}

function refreshWhenVisible() {
  if (document.visibilityState === 'visible') void loadData()
}

const monthTitle = computed(() => `${visibleMonth.value.getFullYear()}年${visibleMonth.value.getMonth() + 1}月`)

const calendarDays = computed<CalendarDay[]>(() => {
  const year = visibleMonth.value.getFullYear()
  const month = visibleMonth.value.getMonth()
  const firstDayOffset = (new Date(year, month, 1).getDay() + 6) % 7
  const firstCell = new Date(year, month, 1 - firstDayOffset)
  const currentToday = dateKey(new Date())
  return Array.from({ length: 42 }, (_, index) => {
    const date = new Date(firstCell.getFullYear(), firstCell.getMonth(), firstCell.getDate() + index)
    const key = dateKey(date)
    return {
      key,
      day: date.getDate(),
      currentMonth: date.getMonth() === month,
      today: key === currentToday,
    }
  })
})

const visibleTasks = computed(() => tasks.value.filter(task => task.taskType === 'subtask' && !task.archived && safeTaskRange(task)))
const calendarWeeks = computed<CalendarWeek[]>(() => Array.from({ length: 6 }, (_, index) => {
  const days = calendarDays.value.slice(index * 7, index * 7 + 7)
  return { days, segments: eventSegmentsForWeek(days) }
}))
const selectedTasks = computed(() => tasksForDate(selectedDate.value))
onMounted(() => {
  void loadData()
  document.addEventListener('visibilitychange', refreshWhenVisible)
})
onBeforeUnmount(() => document.removeEventListener('visibilitychange', refreshWhenVisible))
</script>

<template>
  <div class="calendar-page">
    <section class="calendar-card" aria-label="任务月日历">
      <div class="calendar-toolbar">
        <div class="calendar-title-group">
          <h2>{{ monthTitle }}</h2>
        </div>
        <div class="calendar-toolbar-actions">
          <el-button class="calendar-today-button" @click="goToday">今天</el-button>
          <el-button-group>
            <el-button :icon="ArrowLeft" aria-label="上个月" @click="moveMonth(-1)" />
            <el-button :icon="ArrowRight" aria-label="下个月" @click="moveMonth(1)" />
          </el-button-group>
        </div>
      </div>

      <div v-if="loading && !lastSyncedAt" class="calendar-state">
        <Calendar />
        <strong>正在同步任务日程</strong>
        <span>请稍候……</span>
      </div>
      <div v-else-if="loadError && !lastSyncedAt" class="calendar-state">
        <Calendar />
        <strong>日历加载失败</strong>
        <el-button text type="primary" @click="loadData">重新加载</el-button>
      </div>
      <div v-else class="calendar-content">
        <div class="calendar-month">
          <div class="calendar-weekdays" aria-hidden="true">
            <span v-for="day in weekDays" :key="day">{{ day }}</span>
          </div>
          <div class="calendar-grid">
            <div v-for="(week, weekIndex) in calendarWeeks" :key="weekIndex" class="calendar-week">
              <button
                v-for="day in week.days"
                :key="day.key"
                type="button"
                :class="['calendar-day', { adjacent: !day.currentMonth, today: day.today, selected: selectedDate === day.key }]"
                :aria-label="`${day.key}，${tasksForDate(day.key).length} 项任务`"
                :aria-pressed="selectedDate === day.key"
                @click="selectDay(day)"
              >
                <span class="calendar-day-number">{{ day.day }}</span>
                <span class="calendar-mobile-events" aria-hidden="true">
                  <i
                    v-for="task in tasksForDate(day.key).slice(0, 4)"
                    :key="task.id"
                    :style="{ backgroundColor: listColor(task) }"
                  ></i>
                </span>
                <span v-if="tasksForDate(day.key).length > 3" class="calendar-day-overflow">另有 {{ tasksForDate(day.key).length - 3 }} 项</span>
              </button>
              <div class="calendar-week-events" aria-hidden="true">
                <span
                  v-for="segment in week.segments.filter(item => item.lane < 3)"
                  :key="segment.task.id"
                  :class="['calendar-event', {
                    completed: taskCompleted(segment.task),
                    'continues-before': segment.continuesBefore,
                    'continues-after': segment.continuesAfter,
                  }]"
                  :style="{
                    '--event-color': listColor(segment.task),
                    gridColumn: `${segment.startColumn} / span ${segment.span}`,
                    gridRow: segment.lane + 1,
                  }"
                  :title="`${segment.task.title}：${formatTaskRange(segment.task)}`"
                >
                  <b>{{ segment.task.title }}</b>
                </span>
              </div>
            </div>
          </div>
        </div>

        <WorkspacePanel v-model="agendaVisible" :title="`${selectedDate} · 日程`"><div class="calendar-agenda" aria-live="polite">
          <div v-if="selectedTasks.length" class="calendar-agenda-list">
            <article
              v-for="task in selectedTasks"
              :key="task.id"
              class="calendar-agenda-item"
              :style="{ '--event-color': listColor(task) }"
            >
              <i class="calendar-agenda-color"></i>
              <div>
                <div class="calendar-agenda-title">
                  <h3>{{ task.title }}</h3>
                  <span :class="task.priority">{{ priorityLabels[task.priority] }}</span>
                </div>
                <p class="calendar-agenda-list-name">{{ listFor(task)?.name || '未命名清单' }} · {{ taskStatus(task) }} · {{ progressText(task) }}</p>
                <p class="calendar-agenda-time"><Clock />{{ formatTaskRange(task) }}</p>
                <p v-if="task.remark" class="calendar-agenda-remark">{{ task.remark }}</p>
              </div>
            </article>
          </div>
          <div v-else class="calendar-agenda-empty">
            <span><Calendar /></span>
            <strong>这一天没有任务</strong>
            <p>选择其他日期，或前往任务清单添加时间安排。</p>
          </div>
          <router-link class="calendar-task-link" to="/tasks">
            前往任务清单<Right />
          </router-link>
        </div></WorkspacePanel>
      </div>
    </section>
  </div>
</template>
