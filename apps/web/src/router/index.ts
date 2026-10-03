import { createRouter, createWebHistory } from 'vue-router'
import { useAuthStore } from '@/stores/auth'
import { pinia } from '@/stores'

const router = createRouter({
  history: createWebHistory(),
  routes: [
    { path: '/login', name: 'login', component: () => import('@/views/LoginView.vue') },
    {
      path: '/',
      component: () => import('@/layouts/AdminLayout.vue'),
      meta: { requiresAuth: true },
      children: [
        { path: '', name: 'dashboard', component: () => import('@/views/DashboardView.vue') },
        { path: 'calendar', name: 'calendar', component: () => import('@/views/UnavailableView.vue'), props: { title: '日历' } },
        { path: 'tasks', name: 'tasks', component: () => import('@/views/TasksView.vue') },
        { path: 'health', name: 'health-management', component: () => import('@/views/HealthView.vue') },
        { path: 'finance', name: 'finance', component: () => import('@/views/FinanceView.vue') },
        { path: 'ai', name: 'ai-chat', component: () => import('@/views/AIChatView.vue') },
        { path: 'users', name: 'users', component: () => import('@/views/UsersView.vue') },
        { path: 'settings', name: 'settings', redirect: '/settings/preferences' },
        { path: 'settings/preferences', name: 'preferences', component: () => import('@/views/UnavailableView.vue'), props: { title: '个人偏好' } },
        { path: 'settings/ai', name: 'ai-settings', component: () => import('@/views/AISettingsView.vue') },
      ],
    },
    { path: '/:pathMatch(.*)*', redirect: '/' },
  ],
})

// 路由守卫依据登录状态选择页面；参数：to 为目标路由；返回值：重定向描述或 undefined（继续导航）。
router.beforeEach((to) => {
  const auth = useAuthStore(pinia)
  if (to.meta.requiresAuth && !auth.isAuthenticated) return { name: 'login', query: { redirect: to.fullPath } }
  if (to.name === 'login' && auth.isAuthenticated) return { name: 'dashboard' }
})

export default router
