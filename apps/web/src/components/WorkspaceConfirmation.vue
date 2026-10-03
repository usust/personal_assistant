<script setup lang="ts">
import WorkspacePanel from './WorkspacePanel.vue'
import { confirmation, settleConfirmation } from '@/composables/workspacePanels'

/** 处理面板收起。参数：visible 为显示状态；返回值：无。收起等同取消，不执行写操作。 */
function updateVisibility(visible: boolean) {
  if (!visible) settleConfirmation(false)
}
</script>
<template>
  <WorkspacePanel :model-value="!!confirmation" :title="confirmation?.title" destroy-on-close @update:model-value="updateVisibility">
    <div v-if="confirmation" class="workspace-confirmation">
      <el-tag :type="confirmation.options.type === 'warning' ? 'warning' : 'info'">请确认操作</el-tag>
      <p>{{ confirmation.message }}</p>
    </div>
    <template #footer>
      <el-button @click="settleConfirmation(false)">{{ confirmation?.options.cancelButtonText || '取消' }}</el-button>
      <el-button :type="confirmation?.options.type === 'warning' ? 'danger' : 'primary'" @click="settleConfirmation(true)">{{ confirmation?.options.confirmButtonText || '确认' }}</el-button>
    </template>
  </WorkspacePanel>
</template>
