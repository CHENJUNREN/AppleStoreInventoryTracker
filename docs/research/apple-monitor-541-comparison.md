# Apple 购物袋 541 与参考项目实现对照

调查日期：2026-10-23。对象：[suversal/apple-store-inventory-monitor，固定提交 b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91](https://github.com/suversal/apple-store-inventory-monitor/tree/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91)。本次只读 `/tmp/apple-monitor-reference-1023` 的干净源码，未运行参考项目、未发送购物请求。当前项目对照文件是 [checkout.cjs](/Users/chenjunren/Developer/Personal/AppleStoreInventoryTracker/AppleStoreInventoryTracker/Resources/PurchaseAssistant/checkout.cjs)，本地行号按调查时工作区记录。

## 结论与证据边界

**参考项目没有提供 `/shop/bagx` 删除请求返回 541 的现成修复。** 它的购物袋删除仍调用页面按钮，未实现单独的删除 API、令牌修复或 541 恢复逻辑。最值得移植的是非零 CDP 端口，以及等待真实商品行消失再推进清理的规则；前者是待验证的启动参数差异，后者是可明确指出的等待条件差异，均不能直接宣称解决 541。[删除脚本](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout_remove_from_bag.js#L1-L23)、[清理等待](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1025-L1095)、[CDP 端口](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/chromium_fetcher.rs#L550-L568)

本次调查输入包含主任务已经观察到的现象：专用 profile 在不启用 CDP 的普通模式下删除仍出现 404；相同 Chrome、相同网络的无痕窗口加购和删除成功；原购物袋删除 POST `/shop/bagx` 返回 541。这些是主任务提供的实测记录，本报告没有独立复现。它们使“只是当前 CDP 连接造成失败”和“整个网络都无法购物”不足以解释现象；但无痕同时改变 Cookie、站点存储、登录状态等条件，因此仍不能确定是哪一种状态导致拒绝，也不能把 541 直接解释成账号、IP 或设备被封。

## 启动方式与会话

| 项目 | 参考项目 | 当前项目 | 可采取的行动 |
| --- | --- | --- | --- |
| CDP 端口 | 预先申请回环空闲端口，再以非零值传给 Chrome；读取 `/json/list` 连接页面 WebSocket | 传 `--remote-debugging-port=0`，读取 `DevToolsActivePort` 后由 Playwright 连接浏览器 | 改为显式非零端口是具体可试的差异；需要同步更改端点发现逻辑，不能只改参数后继续依赖旧文件 |
| 有窗口结账 | `start_visible`，独立持久 `checkout-profile-v1`；连接成功即返回 | 专用持久 profile，有窗口 Chrome；普通登录与 CDP 购买分开启动 | 参考也使用 CDP，不能据此认为必须放弃 CDP；对照测试应固定浏览器版本和会话状态 |
| UA 与屏幕覆盖 | 只在 headless 库存监控模式使用 UA、Client Hints、屏幕覆盖及 `AutomationControlled` 参数 | 当前购买启动没有这些覆盖 | 不应把库存监控的 headless 配置当作结账 541 修复照搬 |
| 生命周期 | 存活时复用内存中的结账会话，失效才以同 profile 重启；打开入口导航购物袋供登录、预热 | 当前显式重新登录会清 Apple Cookie、站点存储及浏览器缓存，然后切回普通登录 Chrome | 参考没有证明“清会话即能修复购物袋”；保留持久会话、重建独立会话属于不同验证条件 |

参考来源：[启动参数与端点发现](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/chromium_fetcher.rs#L544-L672)、[仅无头模式覆盖](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/chromium_fetcher.rs#L664-L697)、[profile 常量](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L26-L30)、[会话复用与打开入口](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1741-L1773)。本地来源：[启动参数](/Users/chenjunren/Developer/Personal/AppleStoreInventoryTracker/AppleStoreInventoryTracker/Resources/PurchaseAssistant/checkout.cjs:92)、[CDP 连接与会话清理](/Users/chenjunren/Developer/Personal/AppleStoreInventoryTracker/AppleStoreInventoryTracker/Resources/PurchaseAssistant/checkout.cjs:133)。

参考源码注释称端口 0 会成为自动化信号，但本报告没有独立验证该浏览器行为，更没有证据证明 Apple 的该次 541 使用了此信号。应把非零端口列为可控实验项；尤其已有“不带 CDP 仍失败”的观察，不能承诺只改端口便恢复原购物袋。[作者注释](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/chromium_fetcher.rs#L550-L553)

## 541 处理主要属于库存读取，不是购物袋恢复

`chromium_fetcher.rs` 文件头将普通 HTTP/WKWebView 的 541 与浏览器环境校验联系起来，这是作者对库存查询的说明。其库存查询通过锁串行使用会话，并将 541/403 分类为拒绝：同轮不继续同地区请求，下一轮仍可使用原会话。只有传输错误才在相关路径清掉会话；有模拟 541 后下一轮成功且保持连接的单元测试。该测试验证程序策略，不证明真实 Apple 购物袋可以通过等待下一轮恢复。[文件说明](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/chromium_fetcher.rs#L1-L9)、[串行与拒绝处理](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/chromium_fetcher.rs#L2070-L2084)、[错误与会话保留](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/chromium_fetcher.rs#L2136-L2156)、[模拟测试](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/chromium_fetcher.rs#L3860-L3891)

我们应继续保留实际 HTTP 541 与随后 404 页面之间的区分，并在明确拒绝后停止这一轮修改购物袋。参考项目不支持“收到 541 后立即删 Cookie、换 profile、重发删除请求”的结论。当前已有 Apple 域名 541 识别，可在删除等待中让拒绝状态立即结束等待，而不必等页面路径或按钮数量变化之后才检查。[本地 541 识别](/Users/chenjunren/Developer/Personal/AppleStoreInventoryTracker/AppleStoreInventoryTracker/Resources/PurchaseAssistant/checkout.cjs:8)、[本地删除等待](/Users/chenjunren/Developer/Personal/AppleStoreInventoryTracker/AppleStoreInventoryTracker/Resources/PurchaseAssistant/checkout.cjs:254)

## 购物袋清理：一项具体的等待条件问题

参考项目每轮读取第一条商品的删除 ID、SKU、名称及数量，删除前再次核验，然后调用 `remove.click()`。删除后等待 **商品行总数减少**，清完后重新导航购物袋，再次确认真正空袋。源码明确说明 Apple 会先隐藏删除按钮，再移除整行，因此不能以删除按钮消失作为完成依据。[行快照](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout_line_items.js#L1-L29)、[删除前核验](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout_remove_from_bag.js#L1-L23)、[移除等待与重新导航](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1072-L1095)

我们目前的等待条件是可见删除按钮数减少，或空袋按钮出现。这有可能在整行尚未移除时提前推进；建议改为确认目标商品行消失、行数减少，重新读取行快照后再处理下一条，最终确认空袋。每次操作继续只点击一次，失败时不要自动重发。本项改进能减少过早推进，**不能据此解释已经发生的服务端 541**。[本地现状](/Users/chenjunren/Developer/Personal/AppleStoreInventoryTracker/AppleStoreInventoryTracker/Resources/PurchaseAssistant/checkout.cjs:245)

参考项目的常规准备逻辑还会复用“恰好相同 SKU 的一件商品”，避免先删再加；不匹配则拒绝进入加购。当前流程每次先清空购物袋。如果本地产品策略允许，严格核对 SKU、名称、数量及 AppleCare 等配置后复用匹配条目，可减少不必要的删除请求，但这是减少操作的产品选择，不是恢复被拒绝会话的技术修复。参考项目失败清理仍会逐项清袋，不能把其初始拒绝逻辑误读为所有分支都保护原有商品。[复用规则](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L891-L948)、[失败后清理](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1843-L1867)

## 商品表单 GET / action="#"

参考加购脚本检查商品 URL、名称、选项和按钮可用性，然后返回按钮坐标；Rust 发 CDP 鼠标按下/释放事件。测试诊断分支会打印 form 的 action、method 和 product 值，但实际流程没有验证或重写 action/method，也没有专门修复 `action="#"` 的分支。加购后只等待进入购物袋或配件页，若标题为 `Page Not Found` 则报告 404。[商品脚本](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout_add_to_bag.js#L1-L35)、[诊断、鼠标事件与 404 检测](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L979-L1016)

所以参考代码不能证明 GET 或 `#` 一定错误，也不能证明坐标点击足以修复这种表单。当前代码已使用 Playwright 点击，并额外拒绝空 action、片段 action 或原路径 action；仅凭参考项目没有这项校验，不能删除保护或人为把 form 改成猜测的 POST 地址。若正常无痕商品页也出现 GET / `#` 且实际加购成功，则需重新审视本地校验假设；应先比较正常与失败页面的实际提交导航结果，保持不提交订单。[本地表单校验](/Users/chenjunren/Developer/Personal/AppleStoreInventoryTracker/AppleStoreInventoryTracker/Resources/PurchaseAssistant/checkout.cjs:22)

## 建议落实顺序

1. 修正删除完成条件：用商品行消失/行数减少，删除后重新读取，清空后再次确认；同时明确 541 后停止，避免等待超时掩盖真实拒绝。
2. 将 CDP 端口改为显式非零回环端口，并从相应端口发现端点；测试端口绑定失败、旧端点残留及正常连接。标记为启动方式对齐，不宣称 541 已修复。
3. 在独立、干净会话中手动验证加购和删除，再在相同会话中连接 CDP 验证，逐项改变条件。记录登录/未登录、普通/无痕、旧/新 profile 等差异，不从“无痕成功”直接跳到“账号/IP 被封”。避免把失败原袋反复删除作为验证循环。
4. 正常路径证据确认前，保留现有表单保护。参考项目没有可移植的 action="#" 修补，不能以改写表单或直接调用未验证 API 代替诊断。

以上是静态对照建议；本报告未修改购买流程，也未验证任何建议已经解决真实 541。

## 后续实际验证（主任务补充）

清理专用 Chrome 的 Apple 网站数据并由用户重新登录后，普通模式删除成功。原 port=0 自动化重跑仍被本地 `action="#"` 检查阻止；改为非零端口后也被同一检查阻止，但随后在该窗口通过界面加购成功，说明静态 action 校验不能作为加购不可用的充分依据。已移除该校验，改为检查真实导航结果，未改写网站表单或调用猜测的接口。

非零端口、重新登录后的会话实跑：成功自动清理已有商品、重新加购 MJY74CH/A 并进入结账，随后退出码 10（结账要求登录）。未到 review、未提交订单。此次同时包含会话清理、端口调整、删除等待修正及撤销误校验，不能将成功单独归因于非零端口。源码改动已通过 Node 浏览器流程测试、41 项 Swift 回归测试及 Xcode Debug 编译。

### 结账恢复已实际通过

用户完成安全结账登录后，以 `resume-purchase` 从现有 Fulfillment 页面继续，保留该会话。修正新会话的门店加载顺序（先选地区、再等门店）并兼容已预填地区；取货模式不展示原送货商品名称时，在同一会话的独立购物袋页面核对目标商品与数量，再恢复结账。实跑依次通过地区选择、优先门店与首个可用时段、保存的取货资料、付款方式、最终商品与数量校验，114 秒后到达 `_s=Review`，退出码 0。没有点击提交订单或付款。已保留确认页面，不为重复测试销毁该状态。

App 现增加结账登录后的“继续辅助购买”入口，复用等待中的任务参数；关闭/结束辅助会取消此恢复入口。此前错误的静态表单地址规则已移除，541 仍按实际响应识别并保留明确诊断。成功结果属于这次完整会话验证，不意味着 Apple 会话永久有效，也不能证明仅一个参数改变解决了所有 541。
