<script setup lang="ts">
import { computed } from 'vue'
const props = withDefaults(defineProps<{ icon: string; size?: number }>(), { size: 40 })
const assets = import.meta.glob('../assets/icons/*.{svg,png}', { eager: true, import: 'default', query: '?url' }) as Record<string, string>
// 解析本地图标；输入为组件图标名，输出图片 URL；缺失时使用通用钱包，无网络请求。
const source = computed(() => assets[`../assets/icons/${props.icon}.svg`] || assets[`../assets/icons/${props.icon}.png`] || assets['../assets/icons/type-wallet.svg'])
</script>
<template><img :src="source" alt="" aria-hidden="true" class="account-choice-icon" :style="{ width: `${size}px`, height: `${size}px` }" /></template>
<style scoped>.account-choice-icon { border-radius: 9px; object-fit: contain; flex: none; background: white; }</style>
