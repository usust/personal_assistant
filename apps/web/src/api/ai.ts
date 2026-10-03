import { http } from './http'

export interface ChatMessage { role: 'user' | 'assistant'; content: string }
export interface ChatAction { name: string; success: boolean; error?: string }
export interface ChatResult { reply: string; actions: ChatAction[]; error?: string }

// sendChat 提交一轮对话；configID 为可用配置 ID，messages 为文本历史；返回回复与真实操作状态。
export async function sendChat(configID: number, messages: ChatMessage[]): Promise<ChatResult> {
  const { data } = await http.post<{ data: ChatResult }>('/ai/chat', { config_id: configID, messages }, { timeout: 100_000 })
  return data.data
}
