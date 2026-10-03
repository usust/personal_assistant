import { fileURLToPath, URL } from 'node:url'
import { defineConfig, loadEnv } from 'vite'
import vue from '@vitejs/plugin-vue'

// 根据运行模式生成开发与预览配置，统一前端访问端口及 API 代理。
// 参数：mode 为 Vite 提供的运行模式，用于读取对应环境变量；返回值：Vite 配置对象。
export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, fileURLToPath(new URL('.', import.meta.url)), '')
  const proxy = {
    '/api': {
      target: env.API_PROXY_TARGET || 'http://127.0.0.1:20000',
      changeOrigin: true,
    },
  }
  return {
    plugins: [vue()],
    resolve: {
      alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) },
    },
    server: {
      host: '0.0.0.0',
      port: 10000,
      strictPort: true,
      proxy,
    },
    preview: {
      host: '0.0.0.0',
      port: 10000,
      strictPort: true,
      proxy,
    },
  }
})
