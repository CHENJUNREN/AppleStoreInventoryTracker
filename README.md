# AppleStoreInventoryTracker

一款查询附近 Apple Store 产品到店取货情况的 macOS 菜单栏应用，支持多型号监测、系统通知和 Bark 推送。

## 使用

1. 点击菜单栏图标，填写产品型号；多个型号用逗号分隔。
2. 填写省、市、区和扫描间隔，按需开启系统通知或配置 Bark URL。
3. 点击开始监测，查看各产品的可取货门店；点击产品可打开 Apple 官网购买页。
4. 点击停止结束监测。

监测过程中，确认有产品可取货后会自动切换为 15 秒查询；连续三轮成功查询均无货后，进入 30 秒查询的观察期，持续 5 分钟后恢复设置的间隔。单次加速最多持续 10 分钟，随后进入观察期；持续有货不会无限续期，再次从无货变为有货可重新触发加速。若设置的间隔更短，则保留更短间隔。倒计时会显示当前加速、观察或重试状态，服务端要求的冷却时间优先。

首次有货或新增可取货门店会立即提醒，相同库存状态的重复提醒间隔至少 60 秒。推送耗时不会阻塞库存查询。

查询结果仅针对到店取货，实际可购买情况以 Apple 官网为准。请求失败时可能保留上一次查询结果。

## 开发与验证

使用 Xcode 打开 `AppleStoreInventoryTracker.xcodeproj`，选择 `AppleStoreInventoryTracker` scheme 运行。最低支持 macOS 14。

```sh
# 本地回归测试，不访问 Apple 或发送通知
./scripts/test.sh

# 实际库存查询和产品图片检查，不发送通知
./scripts/test.sh --live

# 编译
xcodebuild -project AppleStoreInventoryTracker.xcodeproj \
  -scheme AppleStoreInventoryTracker -configuration Debug \
  -derivedDataPath /tmp/apple-inventory-build CODE_SIGNING_ALLOWED=NO build
```

实时检查依赖 Apple 服务及型号销售状态，不固定断言有货数量。

代码按职责组织：

- `App/`：应用入口与菜单栏。
- `Views/`：表单、库存展示、玻璃按钮与退出确认。
- `Models/`：库存领域数据与产品展示属性。
- `Monitoring/`：监测协调、时钟、查询频率与通知策略。
- `Services/`：Apple 接口、响应模型、商品图片与通知发送。
- `Tests/`：离线回归与实时接口检查；`scripts/test.sh` 为统一入口。

## 参考

- [woke/apple-store](https://github.com/woke/apple-store)
- [Apple Pickup Watcher](https://github.com/ENCHIGO/apple-pickup-watcher)
