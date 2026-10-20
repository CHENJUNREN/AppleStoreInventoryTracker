//
//  ContentView.swift
//  AppleStoreInventoryTracker
//
//  Created by Chenjun Ren on 2023/10/16.
//

import SwiftUI

struct ContentView: View {
    
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let vm: ContentViewModel
    @State private var isQuitConfirmationPresented = false
    @AppStorage("partNumber") private var partNumber: String = "MYLU3CH/A"
    @AppStorage("province") private var province: String = "重庆"
    @AppStorage("city") private var city: String = "重庆"
    @AppStorage("district") private var district: String = "九龙坡区"
    @AppStorage("countdown") private var countdown: Int = 60
    @AppStorage("barkPushUrl") private var barkPushUrl: String = ""
    @AppStorage("isAppNotificationOn") private var isAppNotificationOn: Bool = true
    @AppStorage("isBarkNotificationOn") private var isBarkNotificationOn: Bool = true
    
    var body: some View {
        VStack(spacing: 0) {
            mainContent
                .frame(height: 560)
                .padding([.horizontal, .top], 12)
            actionControls
        }
        .frame(width: 350)
        // Leave the system menu-window material visible behind the glass controls.
        // Only reduced-transparency mode needs an opaque backing across the whole panel.
        .background {
            if reduceTransparency {
                Color(nsColor: .windowBackgroundColor)
            }
        }
        .tint(.blue)
        .onAppear {
            vm.requestUNAuthorization()
        }
    }
    
    @ViewBuilder
    private var actionControls: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 12) {
                actionStack
            }
            .padding(16)
        } else {
            actionStack
                .padding(16)
        }
    }

    private var actionStack: some View {
        VStack(spacing: 12) {
            actionButton
            quitButton
        }
        .controlSize(.large)
        .buttonBorderShape(.capsule)
    }

    @ViewBuilder
    private var mainContent: some View {
        if vm.isTracking {
            if !vm.hasCompletedRequest {
                VStack(spacing: 12) {
                    ProgressView().controlSize(.large)
                    Text("正在查询")
                        .font(.headline)
                    Text("正在查询附近门店的取货情况")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    countdownStatus
                    if vm.inventoryInfos.isEmpty {
                        ContentUnavailableView {
                            Label(vm.lastError == nil ? "暂无数据" : "查询暂未成功", systemImage: "shippingbox")
                        } description: {
                            Text(vm.lastError == nil ? "暂无附近门店的取货信息" : "将在倒计时结束后自动重试")
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    } else {
                        resultList
                    }
                }
            }
        } else {
            formSheet
        }
    }

    private var countdownStatus: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .center) {
                VStack(alignment: .leading, spacing: 4) {
                    if vm.trackingCount > 0 {
                        Text("已完成 \(vm.trackingCount) 次扫描")
                            .font(.subheadline.weight(.medium))
                    }
                    Text(vm.lastError == nil ? "下次查询" : "重试倒计时")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Text(vm.countdownText)
                    .font(.system(.title3, design: .rounded).weight(.semibold))
                    .monospacedDigit()
                    .contentTransition(.numericText(countsDown: true))
                    .animation(reduceMotion ? nil : .easeInOut(duration: 0.25),
                               value: vm.countdownRemaining)
            }
            ProgressView(value: Double(max(0, vm.countdown - vm.countdownRemaining)),
                         total: Double(max(1, vm.countdown)))
                .accessibilityLabel("等待下一次查询")
        }
        .padding(16)
    }

    private var resultList: some View {
        List {
            ForEach(vm.inventoryInfos) { inventoryInfo in
                purchaseEntry(for: inventoryInfo) {
                    ProductInventoryHeader(inventory: inventoryInfo)
                }
                .listRowSeparator(.hidden)
                .listRowBackground(Color.clear)
                .help("在 Apple 官网购买 \(inventoryInfo.productName)，并选择取货门店")
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }
    
    @ViewBuilder
    private func purchaseEntry<Content: View>(for inventory: ProductInventory,
                                               @ViewBuilder content: () -> Content) -> some View {
        if let url = inventory.purchaseURL {
            Link(destination: url, label: content)
                .buttonStyle(.plain)
        } else {
            content()
        }
    }

    private var formSheet: some View {
        Form {
            Section {
                TextField("型号", text: $partNumber)
            } header: {
                Label("产品信息", systemImage: "bag")
            } footer: {
                Label("如需监控多个产品, 请使用 **逗号** 分隔", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            Section {
                TextField("省份", text: $province)
                TextField("城镇/城市", text: $city)
                TextField("区", text: $district)
            } header: {
                Label("所在地区", systemImage: "mappin.and.ellipse")
            }
            
            Section {
                TextField("秒", value: $countdown, format: .number)
            } header: {
                Label("扫描间隔时间", systemImage: "timer")
            }
            
            Section {
                Toggle("App", isOn: $isAppNotificationOn)
                Toggle("Bark", isOn: $isBarkNotificationOn)
                if isBarkNotificationOn {
                    TextField("Bark URL", text: $barkPushUrl, prompt: Text("https://api.day.app/{Key}/"))
                }
            } header: {
                Label("通知推送", systemImage: "bell")
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
    
    private var actionButton: some View {
        Button(role: vm.isTracking ? .cancel : nil, action: {
            if vm.isTracking {
                vm.stopTracking()
            } else {
                vm.startTracking(
                    for: partNumber,
                    location: [province, city, district].joined(separator: " "),
                    countdown: countdown,
                    pushNotificationSettings: (isAppNotificationOn, isBarkNotificationOn, barkPushUrl)
                )
            }
        }, label: {
            Label(vm.isTracking ? "停止" : "开始", systemImage: vm.isTracking ? "stop.fill" : "play.fill")
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
        })
        .modifier(PickupControlStyle(prominent: !vm.isTracking, tint: vm.isTracking ? .gray : .blue))
    }
    
    private var quitButton: some View {
        Button(role: .destructive) {
            guard !isQuitConfirmationPresented else { return }
            isQuitConfirmationPresented = true
            defer { isQuitConfirmationPresented = false }
            guard QuitConfirmation.confirm(isTracking: vm.isTracking) else { return }
            vm.stopTracking()
            NSApplication.shared.terminate(nil)
        } label: {
            Label("退出", systemImage: "power")
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
        }
        .modifier(PickupControlStyle(prominent: true, tint: .red))
    }
}

/// An app-modal alert remains interactive even if the menu-bar window loses focus.
@MainActor
enum QuitConfirmation {
    static func confirm(isTracking: Bool) -> Bool {
        let alert = NSAlert()
        alert.messageText = "确定退出应用？"
        alert.informativeText = isTracking ? "退出后将停止库存监测和通知。" : "退出后将关闭菜单栏应用。"
        alert.alertStyle = .warning
        let cancel = alert.addButton(withTitle: "取消")
        cancel.keyEquivalent = "\r"
        let quit = alert.addButton(withTitle: "退出")
        quit.hasDestructiveAction = true
        quit.keyEquivalent = ""
        NSApplication.shared.activate()
        return alert.runModal() == .alertSecondButtonReturn
    }
}

/// Use native glass only for actions; older systems and reduced transparency use solid controls.
private struct PickupControlStyle: ViewModifier {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    let prominent: Bool
    let tint: Color

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(macOS 26.0, *), !reduceTransparency {
            content
                .buttonStyle(.glass(.clear))
                .tint(tint)
                .foregroundStyle(tint)
        } else if prominent {
            content.buttonStyle(.borderedProminent).tint(tint)
        } else {
            content.buttonStyle(.bordered).tint(tint)
        }
    }
}

//#Preview {
//    ContentView()
//}

struct ProductInventoryHeader: View {
    let inventory: ProductInventory
    @State private var imageURL: URL?

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            AsyncImage(url: imageURL) { phase in
                if let image = phase.image {
                    image.resizable().interpolation(.high).scaledToFill()
                } else {
                    Image(systemName: "photo")
                        .font(.title2)
                        .foregroundStyle(.gray)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .frame(width: 64, height: 64)
            .background(.white)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 4) {
                    Text(inventory.productName)
                        .foregroundStyle(.primary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text("(\(inventory.availableStores.count))")
                        .foregroundStyle(inventory.availableStores.isEmpty ? .red : .green)
                        .fixedSize()
                }
                .font(.subheadline.weight(.semibold))

                Text(inventory.availabilitySummary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(nil)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .task(id: inventory.id) {
            imageURL = nil
            let url = await ProductImageLoader.shared.imageURL(for: inventory.id)
            guard !Task.isCancelled else { return }
            imageURL = url
        }
    }
}
