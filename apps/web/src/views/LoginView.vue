<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { useRoute, useRouter } from 'vue-router'
import type { FormInstance, FormRules } from 'element-plus'
import { Key, Lock, RefreshRight, User } from '@element-plus/icons-vue'
import { getCaptcha } from '@/api/auth'
import { useAuthStore } from '@/stores/auth'

const route = useRoute()
const router = useRouter()
const auth = useAuthStore()
const formRef = ref<FormInstance>()
const loading = ref(false)
const captchaLoading = ref(false)
const captchaImage = ref('')
const captchaId = ref('')
const rememberedUsername = localStorage.getItem('personal-assistant-username')
const rememberAccount = ref(Boolean(rememberedUsername))
const form = reactive({ username: rememberedUsername || 'admin', password: '', captchaCode: '' })
const rules: FormRules = {
  username: [{ required: true, message: '请输入用户名', trigger: 'blur' }],
  password: [{ required: true, message: '请输入密码', trigger: 'blur' }],
  captchaCode: [{ required: true, message: '请输入验证码', trigger: 'blur' }],
}

async function refreshCaptcha() {
  captchaLoading.value = true
  captchaImage.value = ''
  captchaId.value = ''
  form.captchaCode = ''
  try {
    const captcha = await getCaptcha()
    captchaId.value = captcha.captchaId
    captchaImage.value = captcha.image
  } catch {
    captchaId.value = ''
    captchaImage.value = ''
  } finally {
    captchaLoading.value = false
  }
}

async function submit() {
  if (!(await formRef.value?.validate().catch(() => false))) return
  if (!captchaId.value) {
    await refreshCaptcha()
    return
  }
  loading.value = true
  try {
    await auth.signIn(form.username, form.password, captchaId.value, form.captchaCode)
    if (rememberAccount.value) localStorage.setItem('personal-assistant-username', form.username)
    else localStorage.removeItem('personal-assistant-username')
    const destination = typeof route.query.redirect === 'string' ? route.query.redirect : '/'
    await router.push(destination.startsWith('/') && !destination.startsWith('//') && destination.split('?')[0] !== '/login' ? destination : '/')
  } catch {
    await refreshCaptcha()
  } finally {
    loading.value = false
  }
}

onMounted(refreshCaptcha)
</script>

<template>
  <main class="login-page">
    <div class="login-atmosphere" aria-hidden="true">
      <span class="orb orb-left"></span>
      <span class="orb orb-right"></span>
      <span class="scan-line"></span>
    </div>

    <section class="login-stage">
      <header class="login-heading">
        <div class="login-brand-mark" aria-hidden="true"><span>PA</span></div>
        <div>
          <p class="login-kicker">PERSONAL INTELLIGENCE HUB</p>
          <h1>个人智能助理平台</h1>
          <p class="login-subtitle">Personal Assistant Management Platform</p>
        </div>
      </header>

      <div class="login-card">
        <div class="login-card-header">
          <span class="header-line"></span>
          <div>
            <p>WELCOME BACK</p>
            <h2>用户登录</h2>
          </div>
          <span class="header-line"></span>
        </div>

        <el-form ref="formRef" :model="form" :rules="rules" @keyup.enter="submit">
          <el-form-item prop="username">
            <el-input v-model="form.username" :prefix-icon="User" size="large" aria-label="用户名" placeholder="请输入用户名" />
          </el-form-item>
          <el-form-item prop="password">
            <el-input v-model="form.password" :prefix-icon="Lock" type="password" show-password size="large" aria-label="密码" placeholder="请输入密码" />
          </el-form-item>
          <el-form-item class="captcha-form-item" prop="captchaCode">
            <div class="captcha-row">
              <el-input v-model="form.captchaCode" :prefix-icon="Key" size="large" aria-label="验证码" autocomplete="off" inputmode="text" autocapitalize="off" :spellcheck="false" placeholder="请输入验证码" />
              <button class="captcha-image-button" type="button" :disabled="captchaLoading" aria-label="刷新验证码" title="点击刷新验证码" @click="refreshCaptcha">
                <img v-if="captchaImage" :src="captchaImage" alt="登录验证码" />
                <span v-else><el-icon :class="{ 'is-loading': captchaLoading }"><RefreshRight /></el-icon>{{ captchaLoading ? '加载中' : '点击刷新' }}</span>
              </button>
            </div>
          </el-form-item>

          <div class="login-options">
            <el-checkbox v-model="rememberAccount">记住账号</el-checkbox>
          </div>

          <el-button type="primary" size="large" :loading="loading" class="submit-button" @click="submit">
            {{ loading ? '正在登录' : '登 录' }}
          </el-button>
        </el-form>

      </div>

      <p class="copyright">© 2026 Personal Assistant · 让每一天更专注、更高效</p>
    </section>
  </main>
</template>
