<script setup lang="ts">
import { onBeforeUnmount, watch } from 'vue'
import WorkspaceConfirmation from '@/components/WorkspaceConfirmation.vue'
import { panelStack, settleConfirmation } from '@/composables/workspacePanels'
import { useRoute, useRouter } from 'vue-router'
import { Calendar, House, List, Setting, SwitchButton, Wallet, User, ChatDotRound } from '@element-plus/icons-vue'
import { useAuthStore } from '@/stores/auth'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()

/** 退出当前账号并返回登录页。参数：无；返回值：无。副作用：清理身份信息。 */
function logout() {
  auth.signOut()
  router.push('/login')
}
// 页面切换或布局卸载时取消未完成确认，避免在新页面执行旧操作；参数：无；返回值：无。
function cancelConfirmation() { settleConfirmation(false) }
watch(() => route.path, cancelConfirmation)
onBeforeUnmount(cancelConfirmation)
</script>

<template>
  <div class="admin-shell" :class="{ 'has-details': panelStack.length > 0 }">
    <aside class="sidebar">
      <div class="brand"><span class="brand-mark">P</span><span>Personal Assistant</span></div>
      <el-menu :default-active="route.path" :default-openeds="['/settings']" router class="nav-menu">
        <el-menu-item index="/" aria-label="工作台"><el-icon><House /></el-icon><span>工作台</span></el-menu-item>
        <el-menu-item index="/calendar" aria-label="日历"><el-icon><Calendar /></el-icon><span>日历</span></el-menu-item>
        <el-menu-item index="/tasks" aria-label="任务清单"><el-icon><List /></el-icon><span>任务清单</span></el-menu-item>
        <el-menu-item index="/finance" aria-label="财务管理"><el-icon><Wallet /></el-icon><span>财务管理</span></el-menu-item>
        <el-menu-item index="/health" aria-label="健康管理"><el-icon><User /></el-icon><span>健康管理</span></el-menu-item>
        <el-menu-item index="/ai" aria-label="AI 对话"><el-icon><ChatDotRound /></el-icon><span>AI 对话</span></el-menu-item>
        <el-menu-item index="/users" aria-label="用户管理"><el-icon><User /></el-icon><span>用户管理</span></el-menu-item>
        <el-sub-menu index="/settings" aria-label="系统设置">
          <template #title><el-icon><Setting /></el-icon><span>系统设置</span></template>
          <el-menu-item index="/settings/preferences">个人偏好</el-menu-item>
          <el-menu-item index="/settings/ai">AI 配置</el-menu-item>
        </el-sub-menu>
      </el-menu>
      <button class="logout-button" type="button" aria-label="退出登录" @click="logout">
        <el-icon><SwitchButton /></el-icon><span>退出登录</span>
      </button>
    </aside>
    <!-- 先挂载目标容器，供各页面将扩展内容呈现在同一个第三栏。 -->
    <aside id="workspace-details" v-show="panelStack.length" class="workspace-details" aria-label="详情工作区"></aside>
    <WorkspaceConfirmation />
    <main class="main-area">
      <section class="page-content"><router-view /></section>
    </main>
  </div>
</template>
