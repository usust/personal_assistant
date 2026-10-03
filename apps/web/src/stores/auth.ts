import { computed, ref } from 'vue'
import { defineStore } from 'pinia'
import * as authApi from '@/api/auth'
import type { User } from '@/types/user'

export const useAuthStore = defineStore('auth', () => {
  const token = ref(localStorage.getItem('access_token') || '')
  const user = ref<User | null>(null)
  const isAuthenticated = computed(() => Boolean(token.value))

  async function signIn(username: string, password: string, captchaId: string, captchaCode: string) {
    const result = await authApi.login(username, password, captchaId, captchaCode)
    token.value = result.token
    user.value = result.user
    localStorage.setItem('access_token', result.token)
  }

  function signOut() {
    token.value = ''
    user.value = null
    localStorage.removeItem('access_token')
  }

  return { token, user, isAuthenticated, signIn, signOut }
})
