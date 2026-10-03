import { http } from './http'
import type { User } from '@/types/user'

export interface RegisterUserInput { account: string; password: string; nickname: string }
export type UserRole = 'user' | 'admin' | 'sys_admin'
export interface UpdateUserInput { account?: string; nickname?: string; password?: string; role?: UserRole }
interface UserResponse { id: number; account: string; nickname: string; role: string }

// toUser 将服务端账号字段转换为前端资料；参数：解构输入为服务器响应；返回值：明确字段组成的用户，不传播额外敏感属性。
function toUser({ id, account, nickname, role }: UserResponse): User {
  return { id, username: account, nickname, role }
}

// buildUserPatch 比较编辑前后资料；参数：original 为原资料，input 为表单值，空密码表示不修改。
// 返回值：实际变化字段；非法角色抛出错误，无网络或存储副作用。
export function buildUserPatch(original: User, input: RegisterUserInput & { role: string }): UpdateUserInput {
  const fields: UpdateUserInput = {}
  const account = input.account.trim().toLowerCase()
  const nickname = input.nickname.trim()
  if (account !== original.username) fields.account = account
  if (nickname !== original.nickname) fields.nickname = nickname
  if (input.role !== original.role) {
    if (!['user', 'admin', 'sys_admin'].includes(input.role)) throw new Error('角色无效')
    fields.role = input.role as UserRole
  }
  if (input.password !== '') fields.password = input.password
  return fields
}

// listUsers 读取公开用户列表；参数：无；返回值：规范化列表，HTTP 失败拒绝 Promise。
export async function listUsers(): Promise<User[]> {
  const { data } = await http.get<{ data: UserResponse[] }>('/users')
  return data.data.map(toUser)
}

// registerUser 创建普通账号；参数：input 为账号、原始密码和昵称；返回值：服务端新用户，HTTP 失败拒绝 Promise。
export async function registerUser(input: RegisterUserInput): Promise<User> {
  const { data } = await http.post<{ data: UserResponse }>('/users/register', {
    account: input.account.trim().toLowerCase(),
    password: input.password,
    nickname: input.nickname.trim(),
  })
  return toUser(data.data)
}

// updateUser 提交白名单局部字段；参数：id 为正用户 ID，input 为本次修改，保留显式空值交由后端校验。
// 返回值：服务端更新后用户；需要管理员权限，HTTP 失败拒绝 Promise。
export async function updateUser(id: number, input: UpdateUserInput): Promise<User> {
  // 显式白名单，保留已提交的空值交给后端校验，不通过 truthiness 丢弃字段。
  const fields: UpdateUserInput = {}
  if (input.account !== undefined) fields.account = input.account.trim().toLowerCase()
  if (input.nickname !== undefined) fields.nickname = input.nickname.trim()
  if (input.password !== undefined) fields.password = input.password
  if (input.role !== undefined) fields.role = input.role
  const { data } = await http.patch<{ data: UserResponse }>(`/users/${id}`, fields)
  return toUser(data.data)
}

// deleteUser 删除用户；参数：id 为正用户 ID；返回值：Promise<void>，需要管理员权限，失败拒绝 Promise。
export async function deleteUser(id: number): Promise<void> {
  await http.delete(`/users/${id}`)
}
