<script setup lang="ts">
import { computed, ref } from 'vue'
import WorkspacePanel from '@/components/WorkspacePanel.vue'
import AccountChoiceIcon from './AccountChoiceIcon.vue'
import { accountKinds, accountBanks, accountSections, matchesChoice, creditCardChoice, customAccountChoice, type AccountChoice } from '@/finance/accountCatalog'
const props = defineProps<{ modelValue: boolean }>()
const emit = defineEmits<{ 'update:modelValue': [value: boolean]; select: [value: AccountChoice] }>()
const query = ref('')
const bankQuery = ref('')
const bankVisible = ref(false)
const customVisible = ref(false)
const choosingCredit = ref(false)
const customName = ref('')
const customCredit = ref(false)
const filtered = computed(() => accountKinds.filter(item => matchesChoice(item, query.value)))
const bankResults = computed(() => accountBanks.filter(item => matchesChoice(item, bankQuery.value)))
const custom = computed(() => customAccountChoice(customName.value, customCredit.value))
/** 选择类型；参数 item 为共享目录选项；返回无，银行卡推进第三栏下一层，其他选项写父表单草稿。 */
function choose(item: AccountChoice) {
  if (item.route) { choosingCredit.value = item.route === 'creditCard'; bankQuery.value = ''; bankVisible.value = true; return }
  finish(item)
}
/** 确认完整选项；参数 item 为具体账户类型或银行；返回无，收起所有选择层并恢复原表单，不请求服务端。 */
function finish(item: AccountChoice) { emit('select', item); bankVisible.value = false; customVisible.value = false; emit('update:modelValue', false) }
/** 返回类型列表；参数 value 为面板显示状态；返回无，由统一 WorkspacePanel 管理焦点与 Esc。 */
function changeVisible(value: boolean) { emit('update:modelValue', value) }
</script>
<template>
  <WorkspacePanel :model-value="props.modelValue" title="选择类型" @update:model-value="changeVisible">
    <div class="account-type-selector">
      <el-input v-model="query" placeholder="搜索账户类型" clearable aria-label="搜索账户类型" />
      <section v-for="section in accountSections.filter(section => filtered.some(item => item.section === section.id))" :key="section.id" class="account-type-section">
        <h3>{{ section.title }}</h3>
        <div class="account-type-card"><button v-for="item in filtered.filter(item => item.section === section.id)" :key="item.id" type="button" class="account-type-row" @click="choose(item)"><AccountChoiceIcon :icon="item.icon" /><strong>{{ item.name }}</strong><span class="account-type-chevron" aria-hidden="true">›</span></button></div>
      </section>
      <el-empty v-if="!filtered.length" description="未找到类型，可自定义账户" :image-size="60" />
      <el-button class="account-custom-button" @click="customVisible = true">自定义账户类型</el-button>
    </div>
  </WorkspacePanel>
  <WorkspacePanel v-model="bankVisible" :title="choosingCredit ? '选择信用卡银行' : '选择储蓄卡银行'">
    <div class="account-type-selector"><el-input v-model="bankQuery" clearable placeholder="银行名称、拼音或首字母" aria-label="搜索银行" /><div class="account-type-card"><button v-for="bank in bankResults" :key="bank.id" type="button" class="account-type-row" @click="finish(choosingCredit ? creditCardChoice(bank) : bank)"><AccountChoiceIcon :icon="bank.icon" /><strong>{{ bank.name }}</strong><span class="account-type-chevron" aria-hidden="true">›</span></button></div><el-empty v-if="!bankResults.length" description="未找到银行" :image-size="60" /></div>
  </WorkspacePanel>
  <WorkspacePanel v-model="customVisible" title="自定义账户类型">
    <el-form label-position="top"><el-form-item label="名称"><el-input v-model="customName" placeholder="输入账户类型或机构名称" /></el-form-item><el-checkbox v-model="customCredit">信用／欠款账户</el-checkbox><p v-if="customName.trim() && !custom" role="alert">名称过长，请缩短。</p></el-form>
    <template #footer><el-button @click="customVisible = false">返回</el-button><el-button type="primary" :disabled="!custom" @click="custom && finish(custom)">选用</el-button></template>
  </WorkspacePanel>
</template>
<style>
.account-type-selector { display: grid; gap: 20px; padding: 2px; }
.account-type-section h3 { margin: 0 0 12px; font-size: 15px; font-weight: 650; color: var(--el-text-color-primary); }
.account-type-card { border: 1px solid var(--el-border-color-lighter); border-radius: 22px; background: var(--el-bg-color); overflow: hidden; }
.account-type-row { width: 100%; display: flex; align-items: center; gap: 14px; min-height: 74px; padding: 15px 18px; border: 0; background: transparent; color: var(--el-text-color-primary); text-align: left; cursor: pointer; font: inherit; }
.account-type-row + .account-type-row { border-top: 1px solid var(--el-border-color-extra-light); }
.account-type-row:hover { background: var(--el-fill-color-light); }
.account-type-row:focus-visible { outline: 2px solid var(--el-color-primary); outline-offset: -3px; }
.account-type-row strong { font-size: 15px; font-weight: 650; overflow-wrap: anywhere; }
.account-type-chevron { margin-left: auto; color: var(--el-text-color-placeholder); font-size: 25px; }
.account-custom-button { width: 100%; }
</style>
