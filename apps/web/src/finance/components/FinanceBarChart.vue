<script setup lang="ts">
import { computed } from 'vue'

const props = defineProps<{ data: Array<{ label: string; income: number; expense: number; net?: number }> }>()
const max = computed(() => Math.max(1, ...props.data.flatMap(item => [item.income, item.expense, Math.abs(item.net ?? 0)])))
const width = 640
const height = 190
const plotHeight = 145
const groupWidth = computed(() => width / Math.max(props.data.length, 1))
const y = (value: number) => plotHeight - Math.max(0, value) / max.value * (plotHeight - 14)
</script>

<template>
  <div class="finance-chart-scroll">
    <svg class="finance-bar-chart" :viewBox="`0 0 ${width} ${height}`" role="img" aria-label="收入与支出趋势图">
      <line x1="0" :y1="plotHeight" :x2="width" :y2="plotHeight" class="chart-axis" />
      <g v-for="(item, index) in data" :key="item.label">
        <rect :x="index * groupWidth + groupWidth / 2 - 18" :y="y(item.income)" width="14" :height="plotHeight - y(item.income)" rx="4" class="chart-income"><title>{{ item.label }} 收入 {{ item.income }}</title></rect>
        <rect :x="index * groupWidth + groupWidth / 2 + 4" :y="y(item.expense)" width="14" :height="plotHeight - y(item.expense)" rx="4" class="chart-expense"><title>{{ item.label }} 支出 {{ item.expense }}</title></rect>
        <text :x="index * groupWidth + groupWidth / 2" y="174" text-anchor="middle">{{ item.label }}</text>
      </g>
    </svg>
  </div>
</template>
