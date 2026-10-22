# 果到雷达自动结账源码调查

调查日期：2026-10-21。对象：[suversal/apple-store-inventory-monitor，固定提交 b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91](https://github.com/suversal/apple-store-inventory-monitor/tree/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91)。本报告是静态源码阅读，没有运行该项目、登录账户、提交订单或独立验证其当前可用性。源码中的“实测”注释属于作者描述。

## 核心结论

它实现的是**可见 Chromium 浏览器里的页面自动化**，不是 Apple 下单 API，也不是 Tauri 自带 WebView 承载结账。结账使用独立 `checkout-profile-v1`，启动外部有窗口 Chromium，通过 CDP 操作页面；因此它不能证明我们的 WKWebView 方案可行。[会话入口](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1725-L1758)、[浏览器启动与 CDP](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/chromium_fetcher.rs#L480-L675)

最有参考价值的是分阶段等待、购物袋核对、门店/时段异步稳定判断和提交结果不明时停止。流程可以预填联系人及付款偏好，但验证码、页面变化及缺失字段仍可能要求人工。源码没有提供“提交后保证锁库存多久”的证据。[流程状态](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L43-L91)、[提交结果](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1636-L1702)

## 具体怎么走

1. **准备购物袋**：可使用手动预放商品，也可按监控 SKU 打开商品链接。自动加购前确认空袋；如果已经恰好是对应 SKU、对应名称、数量 1，复用。其他商品或数量不符则报错。商品页核对 URL 与名称，选择不折抵、不加 AppleCare，然后加购，跳过配件推荐，重新进入购物袋核对。[购物袋实现](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L886-L1045)、[加购脚本](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout_add_to_bag.js#L1-L36)
2. **进入结账与取货**：点结账，等待 `Fulfillment` 状态，切换“我要取货”。依据门店目录设置省/市/区；区县用门店地址匹配，无法唯一确定则停止。门店由 `store-locator-result` 对应的门店编号定位。[地区脚本](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout_pickup_region.js#L1-L55)、[取货流程](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1095-L1304)
3. **确认门店与时段**：等待附近门店请求及连续 1.2 秒的状态稳定，避免页面异步重绘清空选择。可配置接受默认最近门店，也可接受同商品正在监控的其他门店；否则选目标门店。优先保留已有效时段，否则选择最早可用时段；当前日期没时段再试其他日期。最终确认门店选中、时段保持、继续按钮可用，最多三轮校正。[门店确认](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1169-L1304)、[稳定等待与选时段](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1324-L1480)
4. **填写联系人、选择付款方式**：用原生 input/select setter 加 `input`、`change` 事件更新受控表单，再验证值。付款方式支持支付宝、微信、分期；分期按页面标签找银行/方案及期数，不存在则停止。之后点“检查订单”。[联系人](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1482-L1578)、[付款与 Review](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1580-L1634)
5. **Review 边界**：重新核对商品名称、单件购物袋；自动加购模式还检查能读到的 SKU，读取总价。不提交模式直接返回 `ReachedReview`。开启提交模式才点一次 `continue-button-placeOrder`，等待订单号；读不到订单号也会返回“已尝试提交但结果未知”，不能当作订单成功。[Review 实现](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1636-L1694)

## 能提前在 App 配置什么

以下是该项目实现覆盖的字段，**不是我们已经在当前 Apple 页面独立核实的完整表单**。

| 类别 | 字段或策略 | 行为 |
| --- | --- | --- |
| 商品 | SKU、名称、商品 URL | 来自监控项；自动加购固定一件 |
| 门店 | 目标门店、监控门店集合、是否接受最近门店 | 地区来自门店目录；时段自动选择 |
| 联系人 | 姓氏、名字、电子邮件、手机号（不带 +86） | 可覆盖 Apple 预填值；配置空项沿用页面值；最终缺项则停止 |
| 证件 | 证件号码后四位 | 对应 `nationalIdSelf` 存在时填写；不是完整证件号码 |
| 付款偏好 | 支付宝、微信、分期方案及期数 | 只选付款方式，未实现代替用户完成支付 |
| 流程 | 自动加购、到 Review 停止/提交、成功后关闭 | 默认 `place_order=false` |

来源：[计划字段与联系人映射](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L101-L190)、[配置 UI](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src/components/CheckoutSettings.tsx#L219-L318)、[默认设置](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/crates/apw-core/src/config.rs#L319-L340)。阅读的流程没有发票资料、代取人或更多支付分支的完整处理，不能从现有代码推断所有订单都只需要这几项。

## 对当前 WebView 问题最直接的线索

加购脚本特意**不调用按钮的 JavaScript `click()`**，而是返回按钮坐标，由 Rust 发出 CDP `Input.dispatchMouseEvent` 的按下/释放事件。作者注释说明这样做是为了避免表单退回原生提交；源码另有加购后 `Page Not Found` / 404 检测。这与我们观察到的 GET 表单回退现象相似，是值得验证的线索，**不是已证明的 WKWebView 故障原因**。我们之前也通过 UI 点击，仍需区别网页初始化失败与脚本点击方式，不能仅移植坐标点击就声称修好。[坐标生成](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout_add_to_bag.js#L28-L33)、[CDP 点击及 404 检查](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L987-L1037)

## 防重复与失败处理：有可取之处，也有不能照搬的部分

- `Mutex` 与 reservation 标志让同一时间只有一个结账，不排队重复触发；加购真正点击后即便返回丢失也不重复加购。提交订单只点一次，提交阶段失败不自动重试；订单号不明时关闭自动结账。源码有忽略运行的真实 Review 测试入口，但存在测试代码不等于本次已验证通过。[加购一次](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L980-L1027)、[运行互斥](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1725-L1739)、[结果处理](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/lib.rs#L1306-L1320)、[实测入口](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L2733-L2759)
- 自动加购失败会触发专属购物袋清理。**实际 `cleanup_bag` 循环会删除读到的所有商品，并非严格只删除本轮新增 SKU**；即便初始检查拒绝不匹配商品，自动失败路径仍可能清空购物袋。UI 明确告知专属购物袋不要放其他商品。我们应保留用户购物袋，仅清理能够证明属于本轮的条目，不能照搬这一行为。[清理循环](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1047-L1117)、[失败进入清理](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1851-L1889)、[UI 说明](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src/components/CheckoutSettings.tsx#L175-L188)
- 有可选自动登录，通过 Apple 登录 iframe 操作；验证码/验证失败保留页面交给用户。账号密码存本机 `checkout-login.json` 明文、Unix 权限 0600，不是 Keychain。**不建议复制此密码存储方案**；我们的第一版继续用户手动登录和独立持久会话。[登录处理](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L712-L845)、[明文存储](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout_login.rs#L1-L95)
- Review 的总价仅被读取和返回，没有看到与预算上限的比较；型号缺失时某些 Review 校验也会放行。接入真实下单前，应额外明确价格、门店、取货日期/时段及最终提交授权，不把“DOM 按钮存在”当成购买条件全部核实。[商品读取](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout_line_items.js#L1-L30)、[Review 检查](https://github.com/suversal/apple-store-inventory-monitor/blob/b48a09fc6e1f6b9dccabc64719fdf760fd8cbb91/src-tauri/src/checkout.rs#L1636-L1694)

## 对本项目的建议

先借鉴其“购物袋 → 取货 → 联系人 → 付款偏好 → Review”的状态机和逐步核验，不复制整个项目；选择外部 Chromium 自动化时，它提供了具体实现参考。若坚持内嵌 WKWebView，需单独验证初始化、登录与加购兼容性，它不是现成解答。当前验证范围继续停在 Review，订单锁库存的成立条件与有效期另行核实。
