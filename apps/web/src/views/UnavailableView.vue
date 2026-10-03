<script setup lang="ts">
defineProps<{ title: string }>()
</script>
<template>
  <div class="page-heading"><h1>{{ title }}</h1></div>
  <article class="panel">
    <el-empty :description="`${title}暂未开放`">
      <p>此功能正在调整中，暂时无法查看或保存数据。</p>
      <el-button type="primary" @click="$router.push('/settings')">前往设置</el-button>
    </el-empty>
  </article>
</template>
