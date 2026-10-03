// 文件职责：构建启动期能力目录，运行期间按只读方式提供能力检索。

package capability

// Registry 在启动时一次性注册能力，服务运行期间只读。
type Registry struct{ entries map[string]Capability }

// NewRegistry 用显式的能力列表组装注册表；重复名称属于启动代码错误。
//
// 参数：entries 是各模块提供的能力定义，名称必须唯一；允许为空。
// 返回值：新建的注册表，运行期间只读；名称重复时 panic，阻止有歧义的配置启动。
// 示例：NewRegistry(usercap.Definitions(users)...) 将用户模块的能力切片展开后注册。
func NewRegistry(entries ...Capability) *Registry {
	r := &Registry{entries: make(map[string]Capability, len(entries))}
	for _, entry := range entries {
		// 拒绝同名覆盖，避免模块注册顺序改变实际执行的业务。
		if _, exists := r.entries[entry.Name]; exists {
			panic("重复注册能力: " + entry.Name)
		}
		r.entries[entry.Name] = entry
	}
	return r
}
