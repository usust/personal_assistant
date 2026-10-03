import axios from 'axios'
import { ElMessage } from 'element-plus'

export const http = axios.create({
  baseURL: import.meta.env.VITE_API_BASE_URL || '/api',
  timeout: 10_000,
})

http.interceptors.request.use((config) => {
  const token = localStorage.getItem('access_token')
  if (token && !config.headers.Authorization) config.headers.Authorization = `Bearer ${token}`
  return config
})

http.interceptors.response.use(
  (response) => response,
  (error) => {
    const status = error.response?.status
    if (status === 401) {
      localStorage.removeItem('access_token')
      if (window.location.pathname !== '/login') {
        window.location.href = '/login'
      } else {
        ElMessage.error(error.response?.data?.message || error.response?.data?.error || '登录失败')
      }
    } else {
      ElMessage({
        type: 'error',
        grouping: true,
        message: error.response?.data?.message || error.response?.data?.error ||
          (!error.response || [502, 503, 504].includes(status)
            ? '无法连接后端服务，请检查服务是否启动及前端代理地址'
            : `请求失败（HTTP ${status}），请检查服务或代理日志`),
      })
    }
    return Promise.reject(error)
  },
)
