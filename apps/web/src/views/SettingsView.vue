<script setup lang="ts">
import { onMounted, reactive, ref } from 'vue'
import { ElMessage } from 'element-plus'
import { getUserSettings, saveUserSettings } from '@/api/preferences'
const preferences = reactive({ language: '', timezone: '' })
const preferencesReady = ref(false)
const preferencesLoading = ref(false)
const preferencesError = ref(false)
const saving = ref(false)
async function loadPreferences() {
  preferencesLoading.value = true
  preferencesError.value = false
  preferencesReady.value = false
  try { Object.assign(preferences, await getUserSettings()); preferencesReady.value = true }
  catch { preferencesError.value = true }
  finally { preferencesLoading.value = false }
}
async function savePreferences() {
  if (!preferencesReady.value || saving.value) return
  if (!preferences.language.trim() || !preferences.timezone.trim()) { ElMessage.warning('请填写语言和时区'); return }
  saving.value = true
  try {
    Object.assign(preferences, await saveUserSettings({ language: preferences.language.trim(), timezone: preferences.timezone.trim() }))
    ElMessage.success('个人偏好已保存')
  } catch { /* 请求错误由统一拦截器提示，保留用户输入。 */ }
  finally { saving.value = false }
}
onMounted(loadPreferences)
</script>
<template>
  <div class="page-heading"><h1>个人偏好</h1></div>
    <article v-loading="preferencesLoading" class="panel">
      <h2>个人偏好</h2><p>保存偏好供个人助手使用，当前页面语言不会立即切换。</p>
      <el-alert v-if="preferencesError" title="偏好加载失败，请重试后再保存" type="error" :closable="false"><el-button text @click="loadPreferences">重试</el-button></el-alert>
      <el-form label-position="top" class="preference-form" :disabled="!preferencesReady || saving" @submit.prevent="savePreferences">
        <el-form-item label="语言"><el-select v-model="preferences.language" filterable allow-create default-first-option><el-option label="简体中文" value="zh-CN"/><el-option label="繁体中文" value="zh-TW"/><el-option label="English" value="en"/></el-select></el-form-item>
        <el-form-item label="时区"><el-select v-model="preferences.timezone" filterable allow-create default-first-option><el-option v-for="zone in ['UTC', 'Asia/Shanghai', 'Asia/Singapore', 'Asia/Tokyo', 'Europe/London', 'America/New_York']" :key="zone" :label="zone" :value="zone"/></el-select></el-form-item>
        <el-button type="primary" native-type="submit" :loading="saving">保存偏好</el-button>
      </el-form>
    </article>
</template>
<style scoped>
.settings-stack { display: grid; gap: 24px; }
.preference-form { max-width: 520px; margin-top: 20px; }
.el-select { width: 100%; }
.ai-heading { display: flex; align-items: center; justify-content: space-between; gap: 16px; flex-wrap: wrap; margin-bottom: 20px; }
.settings-note { color: var(--text-secondary, #64748b); font-size: 13px; margin-top: 16px; }
.dialog-actions { display: flex; justify-content: flex-end; margin-top: 24px; }
</style>
