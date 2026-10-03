<script setup lang="ts">
import { confirmInPanel } from '@/composables/workspacePanels'
import WorkspacePanel from '@/components/WorkspacePanel.vue'
import { computed, onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { useRouter } from 'vue-router'
import { buildUserPatch, deleteUser, listUsers, registerUser, updateUser } from '@/api/users'
import { getCurrentUser } from '@/api/auth'
import { useAuthStore } from '@/stores/auth'
import type { User } from '@/types/user'

const auth = useAuthStore()
const router = useRouter()
const users = ref<User[]>([])
const loading = ref(false)
const loadFailed = ref(false)
const dialog = ref(false)
const saving = ref(false)
const deleting = ref<number | null>(null)
const editing = ref<User | null>(null)
const canManage = computed(() => ['admin', 'sys_admin'].includes(auth.user?.role || ''))
const busy = computed(() => loading.value || saving.value || deleting.value !== null)
const form = reactive({ account: '', nickname: '', password: '', confirmation: '', role: 'user' })
function roleName(role: string) { return role === 'sys_admin' ? '系统管理员' : role === 'admin' ? '管理员' : '普通用户' }
function reset() {
  editing.value = null
  Object.assign(form, { account: '', nickname: '', password: '', confirmation: '', role: 'user' })
}
function openEditor(user?: User) {
  reset()
  if (user) {
    editing.value = { ...user }
    Object.assign(form, { account: user.username, nickname: user.nickname, role: user.role })
  }
  dialog.value = true
}
async function load() {
  if (busy.value) return
  loading.value = true
  loadFailed.value = false
  try {
    const [profile, records] = await Promise.all([getCurrentUser(), listUsers()])
    auth.user = profile
    users.value = records
  } catch { loadFailed.value = true }
  finally { loading.value = false }
}
async function save() {
  if (saving.value) return
  if (editing.value && !canManage.value) return
  if (!/^[a-z0-9_]{3,64}$/.test(form.account.trim().toLowerCase())) { ElMessage.warning('账号须为 3～64 位字母、数字或下划线'); return }
  if (!form.nickname.trim() || [...form.nickname.trim()].length > 64) { ElMessage.warning('昵称须为 1～64 个字符'); return }
  if (!editing.value || form.password !== '') {
    const bytes = new TextEncoder().encode(form.password).length
    if (bytes < 8 || bytes > 72) { ElMessage.warning('密码长度须为 8～72 字节'); return }
  }
  if (form.password !== form.confirmation) { ElMessage.warning('两次密码输入不一致'); return }
  const original = editing.value
  const fields = original ? buildUserPatch(original, form) : null
  if (fields && Object.keys(fields).length === 0) { ElMessage.info('没有需要保存的修改'); return }
  saving.value = true
  try {
    const user = original && fields ? await updateUser(original.id, fields) : await registerUser(form)
    const index = users.value.findIndex(item => item.id === user.id)
    if (index === -1) users.value.push(user)
    else users.value.splice(index, 1, user)
    users.value.sort((a, b) => a.id - b.id)
    if (auth.user?.id === user.id) auth.user = user
    dialog.value = false
    ElMessage.success(original ? '用户已更新' : `用户 ${user.username} 已创建`)
  } catch { /* 保留输入，统一请求拦截器展示错误。 */ }
  finally { saving.value = false }
}
/** 删除指定用户。参数：user 为目标用户；返回值：完成 Promise。仅管理员可执行，取消确认不删除，删除自身后退出登录。 */
async function remove(user: User) {
  if (busy.value || !canManage.value) return
  deleting.value = user.id
  try {
    try {
      await confirmInPanel(
        `确定删除用户“${user.username}”吗？此操作不可撤销。${auth.user?.id === user.id ? '删除当前账号后将退出登录。' : ''}`,
        '删除用户', { type: 'warning', confirmButtonText: '删除', cancelButtonText: '取消' },
      )
    } catch { return }
    await deleteUser(user.id)
    users.value = users.value.filter(item => item.id !== user.id)
    ElMessage.success('用户已删除')
    if (auth.user?.id === user.id) {
      auth.signOut()
      await router.replace('/login')
    }
  } catch { /* 失败时保留列表，统一请求拦截器展示错误。 */ }
  finally { deleting.value = null }
}
onMounted(load)
</script>
<template>
  <div class="page-heading">
    <div><p class="eyebrow">USERS</p><h1>用户管理</h1></div>
    <div class="actions"><el-button :disabled="busy" @click="load">刷新</el-button><el-button type="primary" :disabled="busy" @click="openEditor()">新增用户</el-button></div>
  </div>
  <article class="panel" v-loading="loading">
    <el-alert v-if="loadFailed" title="用户信息加载失败，请点击刷新重试" type="error" :closable="false" show-icon />
    <p v-else-if="!loading && !canManage" class="hint">当前账号可查看和新增用户；编辑与删除需要管理员权限。</p>
    <el-table :data="users" :empty-text="loadFailed ? '暂时无法获取用户列表' : '暂无用户'">
      <el-table-column prop="id" label="用户 ID" width="100"/>
      <el-table-column prop="username" label="账号" min-width="160"/>
      <el-table-column prop="nickname" label="昵称" min-width="160"/>
      <el-table-column label="角色" min-width="120"><template #default="{ row }">{{ roleName(row.role) }}</template></el-table-column>
      <el-table-column v-if="canManage" label="操作" width="160" fixed="right">
        <template #default="{ row }">
          <el-button link type="primary" :disabled="busy" @click="openEditor(row)">编辑</el-button>
          <el-button link type="danger" :disabled="busy" :loading="deleting === row.id" @click="remove(row)">删除</el-button>
        </template>
      </el-table-column>
    </el-table>
  </article>
  <WorkspacePanel v-model="dialog" :title="editing ? '编辑用户' : '新增普通用户'" :show-close="!saving" :close-on-press-escape="!saving" @closed="reset">
    <el-form label-position="top" :disabled="saving" @submit.prevent="save">
      <el-form-item label="账号" required><el-input v-model="form.account" maxlength="64" autocomplete="off" placeholder="3～64 位字母、数字或下划线"/></el-form-item>
      <el-form-item label="昵称" required><el-input v-model="form.nickname"/></el-form-item>
      <el-form-item v-if="editing" label="角色" required>
        <el-select v-model="form.role"><el-option label="普通用户" value="user"/><el-option label="管理员" value="admin"/><el-option label="系统管理员" value="sys_admin"/></el-select>
        <p v-if="editing.id === auth.user?.id && form.role === 'user'" class="hint">保存后，当前账号将失去管理员权限。</p>
      </el-form-item>
      <el-form-item :label="editing ? '新密码（留空不修改）' : '密码'" :required="!editing"><el-input v-model="form.password" type="password" autocomplete="new-password" show-password/></el-form-item>
      <el-form-item label="确认密码" :required="!editing || form.password !== ''"><el-input v-model="form.confirmation" type="password" autocomplete="new-password" show-password/></el-form-item>
      <div class="actions"><el-button :disabled="saving" @click="dialog = false">取消</el-button><el-button type="primary" native-type="submit" :loading="saving">{{ editing ? '保存修改' : '创建用户' }}</el-button></div>
    </el-form>
  </WorkspacePanel>
</template>
<style scoped>
.actions { display: flex; justify-content: flex-end; gap: 12px; }
.hint { color: var(--el-text-color-secondary); font-size: 13px; }
</style>
