import { ref, shallowRef } from 'vue'

// 面板只占用第三栏；保留先前层级，使嵌套表单返回时不会丢失输入。
export const panelStack = ref<symbol[]>([])

/** 注册展开层。参数：id 为组件唯一标识；返回值：无。重复注册不改变顺序。 */
export function openPanel(id: symbol) {
  if (!panelStack.value.includes(id)) panelStack.value = [...panelStack.value, id]
}

/** 移除指定层。参数：id 为组件唯一标识；返回值：无。用于关闭及卸载清理。 */
export function removePanel(id: symbol) {
  panelStack.value = panelStack.value.filter(
    // 保留其他展开层；参数：item 为层标识；返回值：是否保留。
    item => item !== id,
  )
}

type ConfirmOptions = { type?: string; confirmButtonText?: string; cancelButtonText?: string }
type Confirmation = { message: string; title: string; options: ConfirmOptions; resolve: () => void; reject: (reason: string) => void }
export const confirmation = shallowRef<Confirmation | null>(null)

/** 完成确认。参数：accepted 表示确认或取消；返回值：无。取消会拒绝原 Promise，阻止后续写操作。 */
export function settleConfirmation(accepted: boolean) {
  const current = confirmation.value
  confirmation.value = null
  if (accepted) current?.resolve()
  else current?.reject('cancel')
}

/** 在第三栏请求确认。参数：message 为纯文本内容，title 为标题，options 为按钮文案及提示类型；返回值：确认后兑现的 Promise，取消时拒绝。 */
export function confirmInPanel(message: string, title: string, options: ConfirmOptions = {}) {
  // 新确认替换旧确认时，先取消旧操作，避免悬空 Promise 或误执行。
  settleConfirmation(false)
  return new Promise<void>(
    // 保存本次确认的完成回调；参数：resolve/reject 为 Promise 回调；返回值：无。
    (resolve, reject) => { confirmation.value = { message, title, options, resolve, reject } },
  )
}
