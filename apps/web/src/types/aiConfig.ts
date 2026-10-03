// AI 配置的接口类型，与个人偏好、对话消息分开维护。
export interface Provider { id: string; name: string; base_url: string }
export interface ProviderConfig {
  id: number
  owner_type: 'system' | 'user' | 'group'
  owner_id: number | null
  visibility: 'private' | 'shared'
  created_by: number | null
  is_selected: boolean
  name: string
  provider_name: string
  base_url: string
  model_name: string
  updated_at: string
}
export interface CreateProviderConfig {
  owner_type: 'user'
  owner_id: number
  visibility: 'private' | 'shared'
  name: string
  provider_name: string
  base_url: string
  model_name: string
  api_key: string
}
