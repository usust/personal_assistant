<script setup lang="ts">
import { computed } from 'vue'
import { money, ratio, sumMoney } from '@/finance/utils/money'

const props = defineProps<{ data: Array<{ name: string; amount: string; color?: string }> }>()
const palette = ['#5658cf', '#249c77', '#d7a241', '#b46f9c', '#4f8da8', '#9299a9']
const total = computed(() => props.data.reduce((sum, item) => sum + Math.max(0, Number(item.amount)), 0))
const totalString = computed(() => sumMoney(props.data.map(item => item.amount)))
const background = computed(() => {
  if (!total.value) return '#eef0f4'
  let start = 0
  const stops = props.data.map((item, index) => {
    const end = start + Math.max(0, Number(item.amount)) / total.value * 100
    const color = item.color || palette[index % palette.length]
    const segment = `${color} ${start}% ${end}%`
    start = end
    return segment
  })
  return `conic-gradient(${stops.join(',')})`
})
</script>

<template>
  <div class="finance-donut-layout">
    <div class="finance-donut" :style="{ background }"><span><small>合计</small><strong>{{ money(totalString) }}</strong></span></div>
    <div class="finance-legend">
      <div v-for="(item, index) in data" :key="item.name" class="finance-legend-row">
        <i :style="{ background: item.color || palette[index % palette.length] }" />
        <span>{{ item.name }}</span><b>{{ money(item.amount) }}</b><em>{{ total ? `${ratio(item.amount, totalString).toFixed(1)}%` : '--' }}</em>
      </div>
      <div v-if="!data.length" class="finance-chart-empty">暂无结构数据</div>
    </div>
  </div>
</template>
