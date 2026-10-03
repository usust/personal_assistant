<script setup lang="ts">
import { computed, nextTick, onBeforeUnmount, ref, useId, watch } from 'vue'
import { ArrowLeft, Close } from '@element-plus/icons-vue'
import { openPanel, panelStack, removePanel } from '@/composables/workspacePanels'

defineOptions({ inheritAttrs: false })
const props = withDefaults(defineProps<{
  modelValue: boolean
  title?: string
  showClose?: boolean
  closeOnPressEscape?: boolean
  destroyOnClose?: boolean
}>(), { title: '详细信息', showClose: true, closeOnPressEscape: true, destroyOnClose: false })
const emit = defineEmits<{ 'update:modelValue': [value: boolean]; closed: [] }>()
const id = Symbol('workspace-panel')
const titleId = useId()
const element = ref<HTMLElement>()
const rendered = ref(false)
let trigger: HTMLElement | null = null
// 判断当前最上层；参数：无；返回值：是否显示当前层。
const active = computed(() => props.modelValue && panelStack.value.at(-1) === id)

/** 收起当前层。参数：无；返回值：无。提交锁定时不允许从标题栏关闭。 */
function close() {
  if (props.showClose) emit('update:modelValue', false)
}

/** 处理返回快捷键。参数：event 为键盘事件；返回值：无。输入法及下拉控件优先处理自己的 Esc。 */
function onKeydown(event: KeyboardEvent) {
  if (event.key !== 'Escape' || event.isComposing || event.defaultPrevented || !active.value || !props.closeOnPressEscape) return
  const target = event.target as HTMLElement | null
  if (target?.closest('.el-popper, [aria-expanded="true"]') || target?.querySelector('[aria-expanded="true"]')) return
  event.preventDefault()
  close()
}
document.addEventListener('keydown', onKeydown)

// 同步显示状态并记录返回焦点；参数：visible 为是否展开；返回值：无。
watch(() => props.modelValue, async (visible, previous) => {
  if (visible) {
    trigger = document.activeElement instanceof HTMLElement ? document.activeElement : null
    rendered.value = true
    openPanel(id)
  } else {
    removePanel(id)
    if (props.destroyOnClose) rendered.value = false
    if (previous) emit('closed')
    await nextTick()
    if (!props.modelValue && trigger?.isConnected) trigger.focus()
  }
}, { immediate: true })

// 新层展开后聚焦其标题区，便于键盘继续操作；参数：visible 为是否处于最上层；返回值：无。
watch(active, async (visible) => {
  if (visible) {
    await nextTick()
    if (active.value) element.value?.focus()
  }
}, { immediate: true })

// 卸载时解除全局监听和占位；参数：无；返回值：无。
onBeforeUnmount(() => {
  document.removeEventListener('keydown', onKeydown)
  removePanel(id)
})
</script>

<template>
  <!-- 布局与确认组件同轮挂载时，等待详情容器进入 DOM 后再传送内容。 -->
  <Teleport defer to="#workspace-details">
    <section v-if="rendered" v-show="active" ref="element" class="workspace-panel" tabindex="-1" role="region" :aria-labelledby="titleId" @keydown="onKeydown">
      <header class="workspace-panel-header">
        <div><p>{{ panelStack.length > 1 ? '详细信息 / 进一步操作' : '详细信息' }}</p><h2 :id="titleId">{{ title }}</h2></div>
        <button v-if="showClose" type="button" class="workspace-panel-close" :aria-label="panelStack.length > 1 ? '返回上一层' : '收起详情'" @click="close">
          <el-icon><ArrowLeft v-if="panelStack.length > 1" /><Close v-else /></el-icon>
        </button>
      </header>
      <div class="workspace-panel-body"><slot /></div>
      <footer v-if="$slots.footer" class="workspace-panel-footer"><slot name="footer" /></footer>
    </section>
  </Teleport>
</template>
