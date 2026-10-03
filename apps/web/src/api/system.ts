import { http } from './http'
import type { ApiResponse } from '@/types/api'
import type { HealthStatus } from '@/types/system'

// getHealth 获取进程健康状态；参数：无；返回值：健康数据，HTTP 失败拒绝 Promise；无副作用。
export async function getHealth() {
  const { data } = await http.get<ApiResponse<HealthStatus>>('/health')
  return data.data
}
