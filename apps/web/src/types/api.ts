// 跨业务共用的响应信封；业务数据类型放在各自命名文件。
export interface ApiResponse<T> {
  code: number
  message: string
  data: T
}
