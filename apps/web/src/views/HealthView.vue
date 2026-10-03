<script setup lang="ts">
import { ref, onMounted } from 'vue'
import { ElMessage } from 'element-plus'
import WorkspacePanel from '@/components/WorkspacePanel.vue'
import { confirmInPanel } from '@/composables/workspacePanels'
import { getHealth, analyzeHealth, deleteHealth, type HealthOverview, type HealthReport } from '@/api/health'
import { getProviderConfigs } from '@/api/aiConfig'
import type { ProviderConfig } from '@/types/aiConfig'
const data = ref<HealthOverview>({ days: [], reports: [] })
const configs = ref<ProviderConfig[]>([])
const configID = ref<number>()
const busy = ref(false)
const error = ref('')
const panel = ref(false)
const consent = ref(false)
const selected = ref<HealthReport>()
// load 获取本人健康数据和可用配置；参数：无；返回值：Promise<void>；失败显示可重试错误。
async function load() {
  busy.value = true; error.value = ''
  try { const [overview, providers] = await Promise.all([getHealth(), getProviderConfigs()]); data.value = overview; configs.value = providers; configID.value ??= providers.find(c => c.is_selected)?.id ?? providers[0]?.id }
  catch { error.value = '加载失败，请稍后重试。' } finally { busy.value = false }
}
// openAnalysis 打开第三栏分析表单；参数：无；返回值：无，重新获取本次发送同意。
function openAnalysis() { selected.value = undefined; consent.value = false; panel.value = true }
// showReport 在第三栏展示历史报告；参数：report 为本人报告；返回值：无。
function showReport(report: HealthReport) { selected.value = report; panel.value = true }
// analyze 生成报告；参数：无；返回值：Promise<void>；提交期间锁定第三栏，失败保留重试入口。
async function analyze() {
  if (!configID.value || !consent.value) return
  busy.value = true
  try { const report = await analyzeHealth(configID.value); selected.value = report; data.value.reports.unshift(report) }
  catch { ElMessage.error('分析失败，请检查数据和 AI 配置后重试。') } finally { busy.value = false }
}
// clear 删除服务端健康信息；参数：无；返回值：Promise<void>；统一第三栏确认，取消不会写入。
async function clear() {
  try { await confirmInPanel('删除全部已同步健康数据和 AI 报告？手机健康数据不受影响，再次同步会重新上传。', '清除健康数据') } catch { return }
  busy.value = true
  try { await deleteHealth(); data.value = { days: [], reports: [] }; panel.value = false } catch { ElMessage.error('删除失败，请重试。') } finally { busy.value = false }
}
onMounted(load)
</script>
<template>
  <section class="health-page">
    <header><div><h1>健康管理</h1><p>从 iPhone 同步日常健康数据，了解近期变化。</p></div><el-button :disabled="busy" @click="load">刷新</el-button></header>
    <el-alert v-if="error" :title="error" type="error" :closable="false" />
    <el-alert title="健康报告仅供生活方式参考，不用于诊断或替代医生。未读取到的数据以 — 表示，不视为零。" type="info" :closable="false" />
    <div class="health-actions"><el-button type="primary" :disabled="busy || !data.days.length" @click="openAnalysis">生成 AI 健康报告</el-button><el-button type="danger" plain :disabled="busy || (!data.days.length && !data.reports.length)" @click="clear">清除云端数据</el-button></div>
    <el-empty v-if="!busy && !data.days.length" description="请在 iPhone 客户端的健康管理中授权并同步。" />
    <template v-else><h2>每日趋势 · 最近 {{ data.days.length }} 个记录日</h2><p>步数、距离及能量为日总量，静息心率和体重为日平均。日期按同步设备时区划分，今天的数据截至同步时刻。</p>
    <el-table :data="data.days" v-loading="busy" style="width:100%">
      <el-table-column prop="date" label="日期" min-width="115" />
      <el-table-column v-for="metric in [{key:'steps',label:'步数'}, {key:'active_energy',label:'活动千卡'}, {key:'distance',label:'距离（米）'}, {key:'resting_heart_rate',label:'静息心率'}, {key:'weight',label:'体重（kg）'}]" :key="metric.key" :label="metric.label" min-width="110"><template #default="{ row }">{{ row[metric.key] == null ? '—' : Number(row[metric.key]).toLocaleString(undefined, { maximumFractionDigits: 1 }) }}</template></el-table-column>
    </el-table></template>
    <h2>历史健康报告</h2><el-empty v-if="!data.reports.length" description="尚未生成报告" />
    <div v-for="report in data.reports" :key="report.id" class="report-row"><span>{{ new Date(report.created_at).toLocaleString() }}</span><el-button @click="showReport(report)">查看报告 #{{ report.id }}</el-button></div>
    <WorkspacePanel v-model="panel" :title="selected ? '健康报告' : 'AI 健康分析'" :show-close="!busy" :close-on-press-escape="!busy">
      <template v-if="selected"><p>生成时间：{{ new Date(selected.created_at).toLocaleString() }}</p><div class="report-content">{{ selected.content }}</div><h3>分析依据（日汇总快照）</h3><pre>{{ selected.snapshot }}</pre></template>
      <template v-else><p>分析会将最近 30 个记录日的健康汇总发送给所选 AI 服务提供商。仅在你确认后发送。</p><el-select v-model="configID" placeholder="选择 AI 配置" style="width:100%"><el-option v-for="config in configs" :key="config.id" :value="config.id" :label="`${config.name} · ${config.model_name}`" /></el-select><p v-if="!configs.length">请先在系统设置中添加 AI 配置。</p><el-checkbox v-model="consent">同意发送本次健康汇总用于分析</el-checkbox><el-button type="primary" :loading="busy" :disabled="!consent || !configID" @click="analyze">开始分析</el-button></template>
    </WorkspacePanel>
  </section>
</template>
<style scoped>
.health-page { display:grid; gap:18px; min-width:0; } header,.health-actions,.report-row { display:flex; gap:12px; justify-content:space-between; align-items:center; flex-wrap:wrap; } h1,h2,p { margin:0; } h2 { font-size:18px; } p { color:var(--el-text-color-secondary); line-height:1.7; } .health-actions { justify-content:flex-start; } .report-content { white-space:pre-wrap; line-height:1.8; overflow-wrap:anywhere; } pre { white-space:pre-wrap; overflow-wrap:anywhere; font-size:12px; } .el-checkbox { white-space:normal; height:auto; margin:20px 0; }
</style>
