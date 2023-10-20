//
//  ContentView.swift
//  AppleStoreInventoryTracker
//
//  Created by Chenjun Ren on 2023/10/16.
//

import SwiftUI

struct ContentView: View {
    
    @State private var vm = ContentViewModel()
    
    @State private var partNumber: String = ""
    @State private var province: String = "上海"
    @State private var city: String = "上海"
    @State private var district: String = "徐汇区"
    @State private var frequency: Int = 60
    
    var body: some View {
        HStack(spacing: 0) {
            VStack {
                Form {
                    Section {
                        TextField("型号", text: $partNumber, prompt: .init("MU2Q3CH/A"))
                    } header: {
                        Text("产品信息")
                    } footer: {
                        Label("如需查询多个产品型号, 请使用 **半角逗号(,)** 分隔", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }

                    Section("所在地区") {
                        TextField("省份", text: $province, prompt: .init("上海"))
                        TextField("城镇/城市", text: $city, prompt: .init("上海"))
                        TextField("区", text: $district, prompt: .init("徐汇区"))
                    }
                    
                    Section("查询频率") {
                        TextField("频率(秒)", value: $frequency, format: .number, prompt: .init("60"))
                    }
                }
                .formStyle(.grouped)
                .scrollDisabled(true)
                
                Button(action: {
                    withAnimation(.bouncy) {
                        if vm.isTracking {
                            vm.stopTracking()
                        } else {
                            vm.startTracking(
                                for: "MU2Q3CH/A",
                                location: "上海 上海 徐汇区",
                                frequency: self.frequency
                            )
                        }
                    }
                }, label: {
                    Text(vm.isTracking ? (vm.trackingCount > 0 ? "✅完成第 \(vm.trackingCount) 次查询" : "🔍查询中...") : "开始查询")
                        .padding(.vertical, 10)
                        .frame(width: 250)
                })
                .clipShape(.capsule)
                .buttonStyle(.borderedProminent)
                .tint(vm.isTracking ? .secondary : .blue)
                .padding(.bottom, 40)
            }
            .frame(width: 350, height: 500)
            
            Divider()
            
            VStack(alignment: .leading) {
                if vm.isTracking && !vm.inventoryInfo.isEmpty {
                    if let first = vm.inventoryInfo.first {
                        Text(first.productName)
                            .font(.headline)
                            .padding()
                    }
                    List(vm.inventoryInfo) { info in
                        StoreInventoryView(store: info)
                            .padding(.top, 8)
                            .listRowSeparator(.hidden)
                    }
                    .scrollContentBackground(.hidden)
                } else {
                    ContentUnavailableView {
                        Label("无数据", systemImage: "sparkles")
                            .symbolRenderingMode(.multicolor)
                    } description: {
                        Text("点击开始查询按钮将会显示实时货源信息")
                    }
                }
            }
            .frame(width: 350, height: 500)
        }
        .frame(height: 500)
    }
}

#Preview {
    ContentView()
}
