# v4 后端HTTP与AI工具契约独立补验

2026-10-05，runtime_baseline；仅修改backend/internal/task/handler/handler_test.go及capability/definitions_test.go测试与文档，未改业务代码。实际Gin Handler→共享Service→隔离SQLite；capability.Registry/Executor→真实Definitions→同Service；没有复制业务状态机。

HTTP TestHTTPEnvelope补充实际task POST/PATCH/GET：省略icon默认Folder；创建unknown-preserved-key并仅title修改原键保留；有子main转subtask拒绝400；leaf作新parent拒绝400；ownerId非白名单PATCH拒绝400；原listId+parentId:null PATCH将含嵌套main/归档leaf的整树移动目标清单，GET读回三个listId一致、旧父清空、归档与嵌套parent关系保留、unknown原键逐字一致。独立iconPATCH Target返回对应实体。

TestAIIconContract实际读取公开create/update Schema，确认changes.icon string；实际Executor创建Rocket、更新unknown-ai-key、仅title更新后task.list读回同原键；leaf作parent ErrInvalid，另用户更新原task ErrNotFound。没有调用真实语言模型。现有service TestTaskTreeAssignment同时运行，事务回滚沿用真实服务测试，不另引入HTTP假回滚实现。

最终命令 `GOCACHE=/private/tmp/pa-task-contract-cache go test ./internal/router ./internal/task/... -count=1 -v` 在backend目录执行，全部通过，无缓存结果。独立GOCACHE是因默认Library缓存沙盒读取拒绝，不改变编译/测试逻辑；前一失败为测试变量重名已修，不是产品失败。最终日志backend-contract.log。

身份边界：Handler测试middleware直接注入可信auth.user_id；AI使用可信Actor。验证服务owner隔离，但不是真实JWT签发/校验、中间件联调、在线登录或部署。router测试仅路由inventory/OpenAPI匹配，不作为JWT证据。隔离数据库AutoMigrate只在t.TempDir运行，不迁移真实数据。iOS真实HTTP联调未做，iOS私有fields未知键逐字PATCH尚未直接捕获；本轮提供的是后端真实HTTP rawkey证据。

结论：已执行契约检查通过，真实模型/JWT/跨客户端在线链路未验证。
