import { http } from './http'
import type { UserSettings } from '@/types/preferences'

// getUserSettings 保留停用页面的偏好读取协议；参数：无；返回值：服务端偏好，HTTP 失败时拒绝 Promise。
// 当前后端模块已删除，正式路由使用占位页，不调用此函数；恢复功能时需同步恢复对应接口。
export async function getUserSettings(): Promise<UserSettings> {
  const { data } = await http.get<{ data: UserSettings }>('/settings/user')
  return data.data
}

// saveUserSettings 提交局部个人偏好；参数：input 只包含本次提交的语言或时区；返回值：服务端规范化后的偏好。
// 当前功能停用；调用会修改服务端数据，HTTP 错误拒绝 Promise，未提交字段不加入请求。
export async function saveUserSettings(input: Partial<UserSettings>): Promise<UserSettings> {
  const { data } = await http.patch<{ data: UserSettings }>('/settings/user', input)
  return data.data
}
