# AppleStoreInventoryTracker

一款查询附近 Apple Store 产品到店取货情况的 macOS 菜单栏应用，支持多型号监测、系统通知和 Bark 推送。

## 使用

1. 点击菜单栏图标，填写产品型号；多个型号用逗号分隔。
2. 填写省、市、区和扫描间隔，按需开启系统通知或配置 Bark URL。
3. 点击开始监测，查看各产品的可取货门店；点击产品可打开 Apple 官网购买页。
4. 点击停止结束监测。

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

## 参考

- [woke/apple-store](https://github.com/woke/apple-store)
- [Apple Pickup Watcher](https://github.com/ENCHIGO/apple-pickup-watcher)
