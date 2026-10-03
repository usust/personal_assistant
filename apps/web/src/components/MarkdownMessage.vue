<script setup lang="ts">
import { computed } from 'vue'
import { renderMarkdown } from '@/utils/markdown'

const props = defineProps<{ content: string }>()
// computed 仅在消息正文变化时重新解析；参数：无；返回：供展示的 HTML。
const html = computed(() => renderMarkdown(props.content))
</script>

<template>
  <!-- 只接收受限解析器生成的 HTML，不将模型原文直接交给 v-html。 -->
  <div class="markdown-message" v-html="html" />
</template>

<style scoped>
.markdown-message { min-width: 0; max-width: 100%; margin-top: 10px; line-height: 1.75; overflow-wrap: anywhere; }
.markdown-message :deep(p) { margin: 0 0 12px; white-space: normal; }
.markdown-message :deep(> :last-child) { margin-bottom: 0; }
.markdown-message :deep(h1), .markdown-message :deep(h2), .markdown-message :deep(h3), .markdown-message :deep(h4), .markdown-message :deep(h5), .markdown-message :deep(h6) { margin: 20px 0 10px; line-height: 1.4; font-weight: 650; }
.markdown-message :deep(h1) { font-size: 1.35em; }
.markdown-message :deep(h2) { font-size: 1.2em; }
.markdown-message :deep(h3), .markdown-message :deep(h4), .markdown-message :deep(h5), .markdown-message :deep(h6) { font-size: 1.05em; }
.markdown-message :deep(> :first-child) { margin-top: 0; }
.markdown-message :deep(ul), .markdown-message :deep(ol) { margin: 10px 0; padding-left: 1.6em; }
.markdown-message :deep(li + li) { margin-top: 4px; }
.markdown-message :deep(li > p) { margin: 4px 0; }
.markdown-message :deep(blockquote) { margin: 12px 0; padding: 8px 14px; border-left: 3px solid #a9b9d5; background: #eaf0f7; color: #526078; }
.markdown-message :deep(blockquote > :last-child) { margin-bottom: 0; }
.markdown-message :deep(a) { color: #315cbe; text-decoration: underline; text-underline-offset: 3px; }
.markdown-message :deep(code) { padding: 2px 5px; border-radius: 4px; background: #e5eaf2; font-family: ui-monospace, SFMono-Regular, Consolas, monospace; font-size: .9em; }
.markdown-message :deep(pre) { max-width: 100%; overflow-x: auto; margin: 12px 0; padding: 14px 16px; border-radius: 8px; background: #182235; color: #e8eef8; white-space: pre; overflow-wrap: normal; }
.markdown-message :deep(pre code) { padding: 0; background: none; color: inherit; }
.markdown-message :deep(.markdown-table) { max-width: 100%; overflow-x: auto; margin: 14px 0; border: 1px solid #dce3ed; border-radius: 8px; }
.markdown-message :deep(table) { width: 100%; border-collapse: collapse; font-size: .95em; }
.markdown-message :deep(th), .markdown-message :deep(td) { padding: 10px 14px; border-bottom: 1px solid #dce3ed; text-align: left; white-space: nowrap; }
.markdown-message :deep(th) { background: #e8edf5; font-weight: 600; }
.markdown-message :deep(td) { background: #fff; }
.markdown-message :deep(tr:nth-child(even) td) { background: #f8fafc; }
.markdown-message :deep(tbody tr:last-child td) { border-bottom: 0; }
.markdown-message :deep(hr) { margin: 18px 0; border: 0; border-top: 1px solid #dce3ed; }
.markdown-message :deep(a:focus-visible), .markdown-message :deep(.markdown-table:focus-visible) { outline: 2px solid #315cbe; outline-offset: 2px; }
</style>
