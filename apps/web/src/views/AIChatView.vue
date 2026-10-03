<script setup lang="ts">
import { nextTick, onMounted, ref } from 'vue'
import MarkdownMessage from '@/components/MarkdownMessage.vue'
import { sendChat, type ChatMessage, type ChatAction } from '@/api/ai'
import { getProviderConfigs } from '@/api/aiConfig'
import type { ProviderConfig } from '@/types/aiConfig'

interface DisplayMessage extends ChatMessage { actions?: ChatAction[]; error?: string }
const configs = ref<ProviderConfig[]>([])
const configID = ref<number>()
const messages = ref<DisplayMessage[]>([])
const draft = ref('')
const sending = ref(false)
const loading = ref(false)
const loadError = ref(false)
const conversation = ref<HTMLElement>()

// loadConfigs 加载当前用户可用配置，优先选中已标记配置；参数：无；返回：异步完成，失败展示重试入口。
async function loadConfigs() {
  loading.value = true
  loadError.value = false
  try {
    configs.value = await getProviderConfigs()
    configID.value = configs.value.find(config => config.is_selected)?.id ?? configs.value[0]?.id
  } catch { loadError.value = true }
  finally { loading.value = false }
}

// clearConversation 清空本页会话，不撤销已执行操作；参数：无；返回：无。
function clearConversation() {
  if (sending.value) return
  messages.value = []
  draft.value = ''
}

// scrollToLatest 等待 DOM 更新后定位最新消息；参数：无；返回：异步完成。
async function scrollToLatest() {
  await nextTick()
  conversation.value?.scrollTo({ top: conversation.value.scrollHeight, behavior: 'smooth' })
}

// send 提交当前输入和文本历史，不自动重试；参数：无；返回：异步完成，追加回复及操作记录。
async function send() {
  const content = draft.value.trim()
  if (!content || !configID.value || sending.value) return
  messages.value.push({ role: 'user', content })
  draft.value = ''
  sending.value = true
  await scrollToLatest()
  try {
    // 仅发送文本；工具记录由本次后端执行产生，不作为客户端工具调用提交。
    const history = messages.value.map(message => ({
      role: message.role,
      content: message.content + (message.actions?.length ? '\n本轮操作记录：' + message.actions.map(action => `${action.name}: ${action.success ? '成功' : '失败'}`).join('；') : ''),
    }))
    const result = await sendChat(configID.value, history)
    messages.value.push({ role: 'assistant', content: result.reply || result.error || '本轮已结束', actions: result.actions, error: result.error })
  } catch {
    messages.value.push({ role: 'assistant', content: '请求未完成。若涉及修改，请先查询当前数据再继续，避免重复操作。', error: '请求失败，未自动重试' })
  } finally {
    sending.value = false
    await scrollToLatest()
  }
}

// onMounted 初始化可用配置；参数：无；返回：无。
onMounted(() => { void loadConfigs() })
</script>

<template>
  <div class="page-heading"><div><p class="eyebrow">AI ASSISTANT</p><h1>AI 对话</h1></div><el-button :disabled="sending" @click="clearConversation">新对话</el-button></div>
  <article class="panel chat-panel">
    <div class="chat-toolbar">
      <el-select v-model="configID" placeholder="选择 AI 配置" :loading="loading" :disabled="sending || loading" aria-label="AI 配置" @change="clearConversation">
        <el-option v-for="config in configs" :key="config.id" :label="`${config.name} · ${config.model_name}`" :value="config.id" />
      </el-select>
      <router-link to="/settings/ai">管理 AI 配置</router-link>
    </div>
    <p class="chat-note">选择支持工具调用的 Chat Completions 兼容配置。当前可查询、注册、修改和删除用户，操作遵循当前账号权限。</p>
    <el-alert v-if="loadError" type="error" title="配置加载失败" :closable="false"><el-button text @click="loadConfigs">重试</el-button></el-alert>
    <el-alert v-else-if="!loading && !configs.length" type="info" title="请先在 AI 配置中添加一个可用模型" :closable="false" />
    <div ref="conversation" class="conversation" aria-live="polite" :aria-busy="sending">
      <div v-if="!messages.length" class="chat-empty"><h2>让助手帮你管理用户</h2><p>试试“列出所有用户”，或“把用户 123 的昵称改成小明”。</p><p>对话仅保留在当前页面，刷新后清空。</p></div>
      <article v-for="(message, index) in messages" :key="index" class="chat-message" :class="message.role">
        <strong>{{ message.role === 'user' ? '你' : 'AI 助手' }}</strong>
        <MarkdownMessage v-if="message.role === 'assistant'" :content="message.content" />
        <p v-else class="user-message-text">{{ message.content }}</p>
        <ul v-if="message.actions?.length" class="action-list">
          <li v-for="(action, actionIndex) in message.actions" :key="actionIndex"><el-tag :type="action.success ? 'success' : 'danger'" size="small">{{ action.success ? '成功' : '失败' }}</el-tag> {{ action.name }} <span v-if="action.error">：{{ action.error }}</span></li>
        </ul>
        <small v-if="message.error">{{ message.error }}</small>
      </article>
      <p v-if="sending" role="status">正在处理，工具操作完成后会显示结果……</p>
    </div>
    <form class="chat-compose" @submit.prevent="send">
      <el-input v-model="draft" type="textarea" :rows="3" placeholder="描述你想做的事情，例如：列出所有用户" aria-label="对话消息" :disabled="sending" />
      <div class="compose-footer"><span>修改和删除会直接执行。</span><el-button type="primary" native-type="submit" :loading="sending" :disabled="!configID || !draft.trim() || loading">发送</el-button></div>
    </form>
  </article>
</template>

<style scoped>
.chat-panel { display: flex; flex-direction: column; gap: 16px; }
.chat-toolbar { display: flex; gap: 16px; align-items: center; flex-wrap: wrap; }
.chat-toolbar .el-select { width: min(420px, 100%); }
.chat-note, .compose-footer, .chat-empty { color: #718096; font-size: 14px; }
.chat-note { margin: 0; }
.conversation { height: clamp(300px, 48vh, 650px); overflow-y: auto; padding: 8px; }
.chat-empty { text-align: center; padding: 56px 12px; }
.chat-message { padding: 16px; border-radius: 12px; background: #f4f6fa; margin: 0 0 16px; max-width: 92%; overflow-wrap: anywhere; }
.chat-message.user { margin-left: auto; background: #edf2ff; }
.user-message-text { white-space: pre-wrap; margin: 10px 0 0; line-height: 1.7; }
.chat-message small { display: block; margin-top: 10px; color: #b45309; }
.action-list { list-style: none; padding: 0; margin-bottom: 0; }
.action-list li { margin-top: 8px; }
.compose-footer { display: flex; justify-content: space-between; align-items: center; margin-top: 12px; gap: 12px; }
</style>
