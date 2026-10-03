<script setup lang="ts">
import { onMounted, ref } from 'vue'
import { Calendar, Bell, Document, CircleCheck } from '@element-plus/icons-vue'
import { getHealth } from '@/api/system'

const summary = { tasks: '—', notes: '—', reminders: '—' }
const apiStatus = ref('检查中')

onMounted(async () => {
  try {
    const health = await getHealth()
    apiStatus.value = health.status === 'ok' ? '运行正常' : '状态异常'
  } catch {
    apiStatus.value = '连接失败'
  }
})

const cards = [
  { key: 'tasks', label: '待办任务', icon: Calendar, tone: 'indigo' },
  { key: 'notes', label: '我的笔记', icon: Document, tone: 'amber' },
  { key: 'reminders', label: '近期提醒', icon: Bell, tone: 'rose' },
] as const
</script>

<template>
  <div class="page-heading"><div><p class="eyebrow">OVERVIEW</p><h1>工作台</h1></div><span class="date-chip">2026 · 管理中心</span></div>
  <div class="stat-grid">
    <article v-for="card in cards" :key="card.key" class="stat-card">
      <div :class="['stat-icon', card.tone]"><component :is="card.icon" /></div>
      <div><strong>{{ summary[card.key] }}</strong><p>{{ card.label }}</p></div>
      <span class="stat-link">暂未开放</span>
    </article>
  </div>
  <div class="content-grid">
    <article class="panel welcome-panel">
      <p class="eyebrow">GET STARTED</p><h2>欢迎使用个人助手</h2><p>你可以管理个人偏好和 AI 配置。任务、日历及财务功能正在调整，暂时无法使用。</p>
      <div class="next-steps"><el-button type="primary" @click="$router.push('/settings')">管理个人偏好与 AI 配置</el-button></div>
    </article>
    <article class="panel status-panel"><div class="status-icon"><CircleCheck /></div><div><p class="eyebrow">SYSTEM STATUS</p><h3>后端服务</h3><p>{{ apiStatus }}</p></div><span v-if="apiStatus === '运行正常'" class="status-dot"></span></article>
  </div>
</template>
