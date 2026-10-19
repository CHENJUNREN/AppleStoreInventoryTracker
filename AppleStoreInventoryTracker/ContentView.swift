//
//  ContentView.swift
//  AppleStoreInventoryTracker
//
//  Created by Chenjun Ren on 2023/10/16.
//

import SwiftUI

struct ContentView: View {
    
    let vm: ContentViewModel
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
            actionButton
                .padding()
            quitButton
                .padding([.horizontal, .bottom])
        }
        .frame(width: 350)
        .onAppear {
            vm.requestUNAuthorization()
        }
    }
    
    @ViewBuilder
    private var mainContent: some View {
        if vm.isTracking {
            if !vm.inventoryInfos.isEmpty {
                VStack(alignment: .leading, spacing: 0) {
                    ProgressView(value: Double(vm.countdown - vm.countdownRemaining), total: Double(vm.countdown)) {
                        Text("第 \(vm.trackingCount) 次扫描完成")
                            .font(.title2)
                            .bold()
                    } currentValueLabel: {
                        Text("00:\(String(format: "%02d", vm.countdown - vm.countdownRemaining))")
                            .bold()
                    }
                    .padding()
                    
                    resultList
                }
            } else {
                ContentUnavailableView {
                    Label("暂无数据", systemImage: "sparkles")
                        .symbolRenderingMode(.multicolor)
                }
            }
        } else {
            formSheet
        }
    }
    
    private var resultList: some View {
        List {
            ForEach(vm.inventoryInfos) { inventoryInfo in
                purchaseEntry(for: inventoryInfo) {
                    ProductInventoryHeader(inventory: inventoryInfo)
                }
                .help("在 Apple 官网购买 \(inventoryInfo.productName)，并选择取货门店")
            }
        }
        .listStyle(.sidebar)
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
                Text("产品信息")
            } footer: {
                Label("如需监控多个产品, 请使用 **逗号** 分隔", systemImage: "info.circle")
                    .foregroundStyle(.secondary)
            }

            Section("所在地区") {
                TextField("省份", text: $province)
                TextField("城镇/城市", text: $city)
                TextField("区", text: $district)
            }
            
            Section("扫描间隔时间") {
                TextField("秒", value: $countdown, format: .number)
            }
            
            Section("通知推送") {
                Toggle("App", isOn: $isAppNotificationOn)
                Toggle("Bark", isOn: $isBarkNotificationOn)
                if isBarkNotificationOn {
                    TextField("Bark URL", text: $barkPushUrl, prompt: Text("https://api.day.app/{Key}/"))
                }
            }
        }
        .formStyle(.grouped)
    }
    
    private var actionButton: some View {
        Button(action: {
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
            Text(vm.isTracking ? "停止" : "开始")
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
        })
        .clipShape(.capsule)
        .buttonStyle(.borderedProminent)
        .tint(vm.isTracking ? .secondary : .blue)
    }
    
    private var quitButton: some View {
        Button {
            // kill app
            NSApplication.shared.terminate(nil)
        } label: {
            Text("退出")
                .padding(.vertical, 10)
                .frame(maxWidth: .infinity)
        }
        .clipShape(.capsule)
        .buttonStyle(.borderedProminent)
        .tint(.red)
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
