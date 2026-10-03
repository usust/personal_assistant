<script setup lang="ts">
import WorkspacePanel from '@/components/WorkspacePanel.vue'
import { onMounted, reactive, ref, watch } from 'vue'
import { ElMessage } from 'element-plus'
import { getCurrentUser } from '@/api/auth'
import { createProviderConfig, deleteProviderConfig, getProviderConfigs, getProviderModels, getProviders, updateProviderConfig } from '@/api/aiConfig'
import type { Provider, ProviderConfig } from '@/types/aiConfig'
import { confirmInPanel } from '@/composables/workspacePanels'
import type { User } from '@/types/user'
const profile = ref<User | null>(null)
const profileError = ref(false)
const providers = ref<Provider[]>([])
const configs = ref<ProviderConfig[]>([])
const aiLoading = ref(false)
const aiError = ref(false)
const creating = ref(false)
const deletingID = ref<number | null>(null)
const models = ref<string[]>([])
const loadingModels = ref(false)
const modelError = ref('')
let modelGeneration = 0
const dialog = ref(false)
const editing = ref<ProviderConfig | null>(null)
const form = reactive({ name: '', provider_name: '', base_url: '', model_name: '', api_key: '', visibility: 'private' as 'private' | 'shared' })
// 连接监听的取值回调无参数，返回连接及面板状态；变更回调无参数和返回值，废弃迟到目录响应。
watch(() => [form.base_url, form.provider_name, form.api_key, dialog.value, editing.value?.id], () => {
  modelGeneration++
  models.value = []
  modelError.value = ''
  loadingModels.value = false
}, { flush: 'sync' })

// 加载当前身份；参数：无；返回值：无，失败显示状态并禁止新增。
async function loadProfile() {
  profileError.value = false
  try { profile.value = await getCurrentUser() } catch { profileError.value = true }
}
// 刷新后端配置与提供商；参数：无；返回值：无，失败保留错误状态。
async function loadAI() {
  aiLoading.value = true
  aiError.value = false
  try { [providers.value, configs.value] = await Promise.all([getProviders(), getProviderConfigs()]) }
  catch { aiError.value = true }
  finally { aiLoading.value = false }
}
// selectProvider 在用户切换提供商时填入默认地址，用户随后仍可手动修改。
// 参数：providerID 为所选提供商 ID；返回值：无；更新表单地址，未知或自定义提供商清空地址。
function selectProvider(providerID: string) {
  // 仅由选择事件触发，避免覆盖用户在地址输入框中的后续修改。
  for (const provider of providers.value) {
    if (provider.id === providerID) {
      form.base_url = provider.base_url || ''
      return
    }
  }
  form.base_url = ''
}
// 清除编辑草稿及密钥；参数：无；返回值：无。
function resetForm() {
  editing.value = null
  Object.assign(form, { name: '', provider_name: '', base_url: '', model_name: '', api_key: '', visibility: 'private' })
}
// 编辑配置草稿；参数：config 为有编辑权限的无密钥摘要；返回值：无，打开第三栏。
function editConfig(config: ProviderConfig) {
  resetForm()
  editing.value = config
  Object.assign(form, { name: config.name, provider_name: config.provider_name, base_url: config.base_url, model_name: config.model_name, visibility: config.visibility })
  dialog.value = true
}
// 判断编辑归属；参数：config 为列表配置；返回值：本人或管理员系统配置是否可编辑，服务端再次校验。
function canEdit(config: ProviderConfig): boolean {
  return config.owner_type === 'user' && config.owner_id === profile.value?.id || config.owner_type === 'system' && ['admin', 'sys_admin'].includes(profile.value?.role || '')
}
// 刷新模型列表；参数：无；返回值：无，失败显示短错误；编辑时可让后端复用原连接密钥。
async function refreshModels() {
  if (loadingModels.value || creating.value) return
  const generation = ++modelGeneration
  loadingModels.value = true
  modelError.value = ''
  try {
    const result = await getProviderModels({ base_url: form.base_url.trim(), provider_name: form.provider_name, api_key: form.api_key, ...(editing.value ? { config_id: editing.value.id } : {}) })
    // 仅允许仍属于当前连接和当前面板的响应更新目录。
    if (generation === modelGeneration) models.value = result
  } catch {
    if (generation === modelGeneration) modelError.value = '模型列表获取失败'
  } finally {
    if (generation === modelGeneration) loadingModels.value = false
  }
}
// 删除配置；参数：config 为有管理权限的配置；返回值：无，第三栏确认取消时不提交写入。
async function removeConfig(config: ProviderConfig) {
  if (!canEdit(config) || deletingID.value !== null || creating.value) return
  deletingID.value = config.id
  try {
    await confirmInPanel(`删除“${config.name}”？`, '删除模型服务', { confirmButtonText: '删除', type: 'warning' })
    await deleteProviderConfig(config.id)
    ElMessage.success('模型服务已删除')
    await loadAI()
  } catch { /* 取消不执行删除；请求失败由 HTTP 客户端提示，保留列表。 */ }
  finally { deletingID.value = null }
}
// 保存新建或局部编辑；参数：无；返回值：无；失败保留草稿，成功刷新后端列表。
async function createConfig() {
  if (!profile.value || creating.value) return
  if (![form.name, form.provider_name, form.base_url, form.model_name, ...(editing.value ? [] : [form.api_key])].every(value => value.trim())) {
    ElMessage.warning('请填写完整的配置'); return
  }
  if (form.name.trim().length > 255 || form.model_name.trim().length > 255 || form.base_url.trim().length > 2048) {
    ElMessage.warning('名称、模型最多 255 字符，地址最多 2048 字符'); return
  }
  try { const url = new URL(form.base_url); if (!['https:', 'http:'].includes(url.protocol) || url.username || url.password) throw new Error() }
  catch { ElMessage.warning('请填写有效的 HTTP 或 HTTPS 地址，地址中不要包含凭证'); return }
  if (!providers.value.some(provider => provider.id === form.provider_name)) { ElMessage.warning('请选择有效的提供商'); return }
  creating.value = true
  try {
    const fields = { name: form.name.trim(), provider_name: form.provider_name, base_url: form.base_url.trim(), model_name: form.model_name.trim(), visibility: form.visibility }
    if (editing.value) {
      // 比较白名单字段，未修改及留空的密钥不提交，保留后端原值。
      const patch: Partial<typeof fields> & { api_key?: string } = {}
      for (const field of Object.keys(fields) as (keyof typeof fields)[]) {
        if (fields[field] !== editing.value[field]) Object.assign(patch, { [field]: fields[field] })
      }
      if (form.api_key.trim()) patch.api_key = form.api_key
      if (Object.keys(patch).length) await updateProviderConfig(editing.value.id, patch)
    } else await createProviderConfig({ ...fields, api_key: form.api_key, owner_type: 'user', owner_id: profile.value.id })
    resetForm()
    dialog.value = false
    ElMessage.success('AI 配置已保存')
    await loadAI()
  } catch { /* 创建失败保留输入，避免重复创建；刷新失败由列表提示。 */ }
  finally { creating.value = false }
}
// 展示配置归属；参数：config 为无密钥摘要；返回值：归属名称。
function ownerLabel(config: ProviderConfig) {
  if (config.owner_type === 'system') return '系统'
  if (config.owner_type === 'group') return '群体'
  return config.owner_id === profile.value?.id ? '本人' : '其他用户'
}
onMounted(() => { void loadProfile(); void loadAI() })
</script>
<template>
  <div class="page-heading"><div><p class="eyebrow">AI SETTINGS</p><h1>AI 配置</h1></div></div>
  <el-alert v-if="profileError" title="账号信息加载失败，暂时无法新增配置" type="error" :closable="false"><el-button text @click="loadProfile">重试</el-button></el-alert>
    <article v-loading="aiLoading" class="panel">
      <div class="ai-heading"><div><h2>模型服务</h2></div><div><el-button :disabled="aiLoading" @click="loadAI">刷新</el-button><el-button type="primary" :disabled="!profile || aiLoading || aiError || deletingID !== null || !providers.length" @click="resetForm(); dialog = true">新增配置</el-button></div></div>
      <el-alert v-if="aiError" title="配置列表加载失败，请点击刷新重试" type="error" :closable="false"/>
      <template v-else>
        <el-table :data="configs" empty-text="暂无可用配置" style="width: 100%">
          <el-table-column prop="name" label="名称" min-width="150"/>
          <el-table-column label="提供商" min-width="140"><template #default="{ row }">{{ providers.find(p => p.id === row.provider_name)?.name || row.provider_name }}</template></el-table-column>
          <el-table-column prop="model_name" label="模型" min-width="150"/>
          <el-table-column prop="base_url" label="地址" min-width="220" show-overflow-tooltip/>
          <el-table-column label="归属" width="110"><template #default="{ row }">{{ ownerLabel(row) }}</template></el-table-column>
          <el-table-column label="共享范围" width="120"><template #default="{ row }"><el-tag :type="row.visibility === 'shared' ? 'success' : 'info'">{{ row.visibility === 'shared' ? '共享' : '私有' }}</el-tag></template></el-table-column>
          <el-table-column label="操作" width="140"><template #default="{ row }"><el-button text :disabled="!canEdit(row) || deletingID !== null || creating" @click="editConfig(row)">编辑</el-button><el-button text type="danger" :disabled="!canEdit(row) || deletingID !== null || creating" :loading="deletingID === row.id" @click="removeConfig(row)">删除</el-button></template></el-table-column>
        </el-table>

      </template>
    </article>  <WorkspacePanel v-model="dialog" :title="editing ? '编辑 AI 配置' : '新增 AI 配置'" :close-on-press-escape="!creating" :show-close="!creating" @closed="resetForm">
    <el-form label-position="top" :disabled="creating" @submit.prevent="createConfig">
      <el-form-item label="配置名称" required><el-input v-model="form.name" maxlength="255"/></el-form-item>
      <el-form-item label="提供商" required><el-select v-model="form.provider_name" @change="selectProvider"><el-option v-for="provider in providers" :key="provider.id" :label="provider.name" :value="provider.id"/></el-select></el-form-item>
      <el-form-item label="服务地址" required><el-input v-model="form.base_url" placeholder="https://api.example.com/v1" maxlength="2048"/></el-form-item>
      <el-form-item label="模型名称" required><el-select v-model="form.model_name" filterable allow-create default-first-option><el-option v-for="model in models" :key="model" :label="model" :value="model"/></el-select></el-form-item>
      <el-form-item :label="editing ? 'API 密钥（留空保留）' : 'API 密钥'" :required="!editing"><el-input v-model="form.api_key" type="password" autocomplete="new-password" show-password/></el-form-item>
      <el-form-item><el-button :loading="loadingModels" :disabled="!form.base_url || !form.provider_name || (!editing && !form.api_key)" @click="refreshModels">刷新模型</el-button><span v-if="modelError" role="alert">{{ modelError }}</span></el-form-item>
      <el-form-item label="共享范围"><el-radio-group v-model="form.visibility"><el-radio value="private">仅自己使用</el-radio><el-radio value="shared">共享给所有登录用户</el-radio></el-radio-group></el-form-item>
      <p v-if="form.visibility === 'shared'">共享后，其他登录用户也能看到此配置的信息。</p>

    </el-form>
    <template #footer><el-button :disabled="creating" @click="dialog = false">取消</el-button><el-button type="primary" :loading="creating" @click="createConfig">保存</el-button></template>
  </WorkspacePanel>
</template>
<style scoped>
.settings-stack { display: grid; gap: 24px; }
.preference-form { max-width: 520px; margin-top: 20px; }
.el-select { width: 100%; }
.ai-heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 20px; }
.settings-note { color: var(--text-secondary, #64748b); font-size: 13px; margin-top: 16px; }
.dialog-actions { display: flex; justify-content: flex-end; margin-top: 24px; }
</style>
