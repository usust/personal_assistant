import type { User } from './user'

export interface LoginResult {
  token: string
  expiresAt: number
  user: User
}

export interface CaptchaResult {
  captchaId: string
  image: string
  expiresAt: number
}
