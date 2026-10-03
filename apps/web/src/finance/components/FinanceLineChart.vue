<script setup lang="ts">
import { computed } from 'vue'
import { money } from '@/finance/utils/money'

const props = defineProps<{ data: Array<{ label: string; assets: number; liabilities: number; netWorth: number }> }>()
const width = 640
const height = 190
const padding = 18
const values = computed(() => props.data.flatMap(item => [item.assets, item.liabilities, item.netWorth]))
const min = computed(() => Math.min(0, ...values.value))
const max = computed(() => Math.max(1, ...values.value))
const x = (index: number) => props.data.length <= 1 ? width / 2 : padding + index * (width - padding * 2) / (props.data.length - 1)
const y = (value: number) => padding + (max.value - value) / (max.value - min.value || 1) * (height - 48)
const points = (key: 'assets' | 'liabilities' | 'netWorth') => props.data.map((item, index) => `${x(index)},${y(item[key])}`).join(' ')
</script>

<template>
  <div v-if="data.length" class="finance-chart-scroll">
    <svg class="finance-line-chart" :viewBox="`0 0 ${width} ${height}`" role="img" aria-label="资产负债与净资产趋势图">
      <line x1="0" :y1="height - 30" :x2="width" :y2="height - 30" class="chart-axis" />
      <polyline :points="points('assets')" class="assets-line" /><polyline :points="points('liabilities')" class="liabilities-line" /><polyline :points="points('netWorth')" class="networth-line" />
      <g v-for="(item, index) in data" :key="item.label"><circle :cx="x(index)" :cy="y(item.netWorth)" r="3" class="networth-dot"><title>{{ item.label }} 资产 {{ money(item.assets) }}，负债 {{ money(item.liabilities) }}，净资产 {{ money(item.netWorth) }}</title></circle><text v-if="index === 0 || index === data.length - 1" :x="x(index)" :y="height - 10" :text-anchor="index === 0 ? 'start' : 'end'">{{ item.label.slice(5) }}</text></g>
    </svg>
  </div>
  <div v-else class="finance-empty compact"><strong>暂无余额历史</strong><span>添加账户或更新余额后即可查看净资产趋势。</span></div>
</template>
