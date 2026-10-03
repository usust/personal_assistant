import { http } from './http'
import type { ApiResponse } from '@/types/api'
import type { Provider, ProviderConfig, CreateProviderConfig } from '@/types/aiConfig'

// getProviders 获取配置页面可选的提供商；参数：无；返回值：提供商列表，HTTP 失败时拒绝 Promise。
export async function getProviders(): Promise<Provider[]> {
  const { data } = await http.get<ApiResponse<Provider[]>>('/setting/ai/providers')
  return data.data
}

// getProviderConfigs 获取当前用户可使用的配置元数据；参数：无；返回值：不含密钥的列表，HTTP 失败时拒绝 Promise。
export async function getProviderConfigs(): Promise<ProviderConfig[]> {
  const { data } = await http.get<ApiResponse<ProviderConfig[]>>('/setting/ai/provider_config')
  return data.data
}

// createProviderConfig 创建独立配置；参数：input 为填写完整的连接与归属信息，包含仅提交一次的密钥。
// 返回值：Promise<void>，保存失败时拒绝；成功后由调用方重新加载无密钥列表，不保留创建响应。
export async function createProviderConfig(input: CreateProviderConfig): Promise<void> {
  await http.post('/setting/ai/provider_config/create', input)
}

// updateProviderConfig 同步实际修改的白名单字段；参数：id 为配置 ID，input 为局部字段，空密钥应省略。
// 返回值：无密钥的最新配置；网络、校验及权限错误会拒绝 Promise。
export async function updateProviderConfig(id: number, input: Partial<Pick<CreateProviderConfig, 'name' | 'provider_name' | 'base_url' | 'model_name' | 'api_key' | 'visibility'>>): Promise<ProviderConfig> {
  const { data } = await http.patch<ApiResponse<ProviderConfig>>(`/setting/ai/provider_config/${id}`, input)
  return data.data
}

// getProviderModels 查询连接的模型目录；参数：input 为地址、提供商、密钥及可选的已保存配置 ID。
// 返回值：模型 ID 列表；授权或连接错误拒绝 Promise；密钥仅提交，不缓存，超时覆盖后端 15 秒限制。
export async function getProviderModels(input: { base_url: string; provider_name: string; api_key: string; config_id?: number }): Promise<string[]> {
  const { data } = await http.post<ApiResponse<string[]>>('/setting/ai/models', input, { timeout: 20_000 })
  return data.data
}

// deleteProviderConfig 删除已确认且有管理权限的配置；参数：id 为目标配置 ID；返回值：无，失败拒绝 Promise。
export async function deleteProviderConfig(id: number): Promise<void> {
  await http.delete(`/setting/ai/provider_config/${id}`)
}
