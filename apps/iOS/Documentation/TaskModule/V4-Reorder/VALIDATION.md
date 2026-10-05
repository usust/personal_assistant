# v4 真实UI拖动排序独立验收

2026-10-05，runtime_baseline；iPhone18Pro/iOS27、浅色默认large。使用现有v4样本和当前Debug产物，未改生产/mock接口，仅新增testV4ActualReorder及证据。

实际步骤：进入工作，收起产品发布子树，菜单排序；AX原生按钮“Reorder 下一阶段…”与“Reorder 产品发布…”存在。source实际元素中心长按0.8秒拖到target实际frame归一化0.5/0.1位置，未猜屏幕坐标。日志明确包含press then drag事件。退出排序，断言下一阶段frame.minY在产品发布之前；下拉刷新、返回清单根并重新进入，顺序仍成立。重新进入默认展开子树，设计准备/阅读/确认三节点可达；设计准备详情仍6/11，截图确认父层次与数量保持。

最终单项TEST SUCCEEDED，20.631秒。首尝试仅XCTest编译API类型错（Element与Coordinate），改用source.coordinate.press后实际拖动一次成功，不是产品失败。

这填补此前只有菜单/生产函数、没有UI拖动的运行缺口。HTTP内存mock保存排序再GET，不证明真实后端联调。只拖一个同父根，未运行leaf3/4、跨父拒绝、归档hidden节点UI拖动或多设备矩阵；生产hidden-slot保留测试沿用前轮真实函数证据。无新数据或功能。

复跑：独立runner only-testing:LoanSwipeTests/LoanSwipeTests/testV4ActualReorder，启动v4场景。前后/重进与子树截图、AX、实际日志本目录。结论：本轮同父根UI拖动及刷新重进保留实际通过。
