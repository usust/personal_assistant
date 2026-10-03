import { http } from './http'
import type { CaptchaResult } from '@/types/auth'
import type { User } from '@/types/user'

// getCaptcha 请求一次性验证码并转换字段名；参数：无；返回值：图片、ID 与过期时间，HTTP 失败拒绝 Promise。
export async function getCaptcha(): Promise<CaptchaResult> {
  const { data } = await http.get<{ data: { captcha_id: string; image: string; expires_at: number } }>('/auth/captcha')
  return { captchaId: data.data.captcha_id, image: data.data.image, expiresAt: data.data.expires_at }
}

// login 使用验证码和密码登录，再用新 token 查询资料；参数：username 为账号，password 为原始密码，captchaId 为验证码 ID，captchaCode 为答案。
// 返回值：token 与用户资料；任一步 HTTP 请求失败均拒绝 Promise，调用方成功后再保存 token。
export async function login(username: string, password: string, captchaId: string, captchaCode: string) {
  const { data } = await http.post<{ data: { token: string; token_type: string } }>('/auth/login', {
    account: username,
    password,
    captcha_id: captchaId,
    captcha_answer: captchaCode,
  })
  const token = data.data.token
  return { token, user: await getCurrentUser(token) }
}

// getCurrentUser 获取当前身份；参数：token 可选，为刚签发的凭证，省略时由 HTTP 拦截器提供。
// 返回值：规范化的用户资料，HTTP 失败拒绝 Promise；无本地存储副作用。
export async function getCurrentUser(token?: string): Promise<User> {
  const profile = await http.get<{ data: { id: number; account: string; nickname: string; role: string } }>('/users/me',
    token ? { headers: { Authorization: `Bearer ${token}` } } : undefined)
  const { id, account, nickname, role } = profile.data.data
  return { id, username: account, nickname, role }
}
