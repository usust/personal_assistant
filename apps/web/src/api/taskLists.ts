import { http } from './http'
import type { ApiResponse } from '@/types/api'
import type { SaveTaskListPayload, TaskList } from '@/types/task'

export async function getTaskLists() {
  const { data } = await http.get<ApiResponse<TaskList[]>>('/task-lists')
  return data.data
}

export async function getTaskList(taskListId: number) {
  const { data } = await http.get<ApiResponse<TaskList>>(`/task-lists/${taskListId}`)
  return data.data
}

export async function createTaskList(payload: SaveTaskListPayload) {
  const { data } = await http.post<ApiResponse<TaskList>>('/task-lists', payload)
  return data.data
}

export async function updateTaskList(taskListId: number, payload: SaveTaskListPayload) {
  const { data } = await http.patch<ApiResponse<TaskList>>(`/task-lists/${taskListId}`, payload)
  return data.data
}

export async function deleteTaskList(taskListId: number) {
  await http.delete(`/task-lists/${taskListId}`)
}
