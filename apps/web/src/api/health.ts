import { http } from './http'
export interface HealthDay { id: number; date: string; timezone: string; updated_at: string; steps: number | null; active_energy: number | null; distance: number | null; resting_heart_rate: number | null; weight: number | null }
export interface HealthReport { id: number; content: string; snapshot: string; config_id: number; created_at: string }
export interface HealthOverview { days: HealthDay[]; reports: HealthReport[] }
// getHealth 获取本人最近 30 个记录日及 20 份报告；参数：无；返回值：汇总，网络失败抛错。
export async function getHealth(): Promise<HealthOverview> { return (await http.get<{ data: HealthOverview }>('/health-management')).data.data }
// analyzeHealth 明确授权发送日汇总至所选模型；参数：config_id 为可用配置；返回值：持久化报告，失败抛错。
export async function analyzeHealth(config_id: number): Promise<HealthReport> { return (await http.post<{ data: HealthReport }>('/health-management/reports', { config_id, consent: true }, { timeout: 100000 })).data.data }
// deleteHealth 清除本人服务端健康记录及报告；参数：无；返回值：无，失败抛错；不删除手机数据。
export async function deleteHealth(): Promise<void> { await http.delete('/health-management') }
