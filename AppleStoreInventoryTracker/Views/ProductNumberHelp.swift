import SwiftUI

/// Deliberately schematic illustrations: no remote images, account data or device identifiers.
struct ProductNumberHelp: View {
    @Environment(\.dismiss) private var dismiss
    @State private var method = Method.website

    private enum Method: String, CaseIterable, Identifiable {
        case website = "官网购买页"
        case device = "同款设备"
        var id: Self { self }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("如何找到产品型号").font(.title2.bold())
                Text("填写部件号，例如 MG6W4CH/A。颜色、容量和销售地区需与目标产品一致。")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Picker("查找方式", selection: $method) {
                ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if method == .website {
                        websiteIllustration
                        VStack(alignment: .leading, spacing: 14) {
                            step(1, "选择具体配置", "在 Apple 中国大陆官网打开目标产品，选好机型、颜色与容量。")
                            step(2, "查看完整地址", "点击浏览器地址栏，找到类似 mg6w4ch/a 的一段，保留末尾的 /A。")
                            step(3, "填入部件号", "将 MG6W4CH/A 填回产品型号栏；不需要整条网址。")
                        }
                        Text("并非每个购买页面都会在网址中显示部件号。若地址中没有这段内容，可从同款设备查找，或向 Apple 选购支持确认。")
                            .font(.caption).foregroundStyle(.secondary)
                        Link("打开 Apple 在线商店 ↗", destination: URL(string: "https://www.apple.com.cn/store")!)
                    } else {
                        deviceIllustration
                        VStack(alignment: .leading, spacing: 14) {
                            step(1, "打开关于本机", "在同款 iPhone 或 iPad 上，前往“设置 › 通用 › 关于本机”。")
                            step(2, "读取型号号码", "复制这一栏显示的部件号。如果显示 A 开头的数字型号，轻点该栏切换。")
                            step(3, "确认配置一致", "仅适用于你要监测的同机型、同颜色、同容量及同销售地区产品。")
                        }
                        Link("查看 Apple 官方说明 ↗", destination: URL(string: "https://support.apple.com/zh-cn/106343")!)
                    }
                    Label("请勿填写序列号、IMEI 或 Axxxx 硬件型号。", systemImage: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            HStack {
                Spacer()
                Button("知道了") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        .frame(width: 580, height: 590)
    }

    private var websiteIllustration: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Image(systemName: "globe").foregroundStyle(.secondary)
                Text("apple.com.cn").font(.caption.weight(.medium))
                Spacer()
                Text("网址示意").font(.caption2).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text(verbatim: "www.apple.com.cn/shop/buy-iphone/")
                    .foregroundStyle(.secondary)
                HStack(spacing: 0) {
                    Text("iphone-17/").foregroundStyle(.secondary)
                    Text("mg6w4ch/a")
                        .fontWeight(.semibold).foregroundStyle(Color.accentColor)
                        .padding(.horizontal, 6).padding(.vertical, 4)
                        .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 5))
                }
            }
            .font(.system(.callout, design: .monospaced))
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            HStack(spacing: 8) {
                Image(systemName: "arrow.turn.down.right").foregroundStyle(Color.accentColor)
                Text("MG6W4CH/A").font(.system(.headline, design: .monospaced))
                Text("填写这一段").font(.caption).foregroundStyle(.secondary)
            }
        }
        .padding(18)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("网址示意：从 apple.com.cn 的具体配置链接中提取 mg6w4ch/a，填写 MG6W4CH/A。")
    }

    private var deviceIllustration: some View {
        VStack(spacing: 0) {
            HStack {
                Image(systemName: "chevron.left").foregroundStyle(.secondary)
                Spacer()
                Text("关于本机").fontWeight(.semibold)
                Spacer()
                Text("示意").font(.caption2).foregroundStyle(.secondary)
            }.padding(16)
            Divider()
            HStack {
                Text("机型名称")
                Spacer()
                Text("iPhone").foregroundStyle(.secondary)
            }.padding(16)
            HStack {
                Text("型号号码")
                Spacer()
                Text("MG6W4CH/A").font(.system(.body, design: .monospaced).weight(.semibold))
                Image(systemName: "arrow.left")
            }
            .foregroundStyle(Color.accentColor)
            .padding(16)
            .background(Color.accentColor.opacity(0.1))
        }
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("关于本机示意图：型号号码一行显示 MG6W4CH/A，复制这一栏的部件号。")
    }

    private func step(_ number: Int, _ title: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Text("\(number)").font(.caption.weight(.semibold))
                .frame(width: 24, height: 24)
                .background(.quaternary, in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.callout.weight(.semibold))
                Text(text).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
