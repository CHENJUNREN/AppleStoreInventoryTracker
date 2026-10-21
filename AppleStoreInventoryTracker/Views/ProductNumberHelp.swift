import SwiftUI

/// Schematic examples keep the lookup instructions readable without remote assets.
struct ProductNumberHelp: View {
    @State private var method = Method.website

    private enum Method: String, CaseIterable, Identifiable {
        case website = "官网购买页"
        case device = "同款设备"
        var id: Self { self }

        var instruction: String {
            switch self {
            case .website: "选好颜色与容量，从完整网址中找到以下片段。"
            case .device: "在同款 iPhone / iPad 上打开“设置 › 通用 › 关于本机”。"
            }
        }

        var note: String {
            switch self {
            case .website: "网址中没有部件号？可从同款设备查找。"
            case .device: "若显示 Axxxx，轻点型号号码切换；请确认颜色、容量与销售地区一致。"
            }
        }

        var linkTitle: String { self == .website ? "打开 Apple 商店" : "Apple 官方说明" }
        var linkURL: URL {
            URL(string: self == .website ? "https://www.apple.com.cn/store" : "https://support.apple.com/zh-cn/106343")!
        }
    }

    var body: some View {
        SheetLayout(title: "查找产品型号") {
            VStack(alignment: .leading, spacing: 20) {
                Text("需要以 /A 结尾的部件号，不是序列号或 Axxxx。")
                    .font(.callout).foregroundStyle(.secondary)

                Picker("查找方式", selection: $method) {
                    ForEach(Method.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()

                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        Text(method.instruction)
                            .font(.callout)
                            .fixedSize(horizontal: false, vertical: true)
                        Group {
                            if method == .website { websiteIllustration }
                            else { deviceIllustration }
                        }
                        .frame(maxWidth: .infinity, minHeight: 132)
                        .padding(20)
                        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 16))

                        Text(method.note)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }


                HStack(spacing: 12) {
                    Link(destination: method.linkURL) {
                        Label(method.linkTitle, systemImage: "arrow.up.right.square")
                    }
                    .font(.callout)
                    .modifier(SheetPillStyle())
                    Spacer()
                }
                .controlSize(.regular)
            }
            .padding(24)

        }
        .frame(width: 520, height: 480)
    }

    private var websiteIllustration: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack {
                Image(systemName: "globe")
                Text("apple.com.cn")
                Spacer()
                Text("网址示意")
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            HStack(spacing: 0) {
                Text("…/").foregroundStyle(.secondary)
                Text("MG6W4CH/A")
                    .fontWeight(.semibold)
                    .foregroundStyle(Color.accentColor)
            }
            .font(.system(.title2, design: .monospaced))
            Text("只填写高亮部分，保留 /A。")
                .font(.caption).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("网址示意：提取 MG6W4CH/A，保留末尾的 /A，不需要完整网址。")
    }

    private var deviceIllustration: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack {
                Text("关于本机").fontWeight(.semibold)
                Spacer()
                Text("示意").foregroundStyle(.secondary)
            }
            .font(.caption)
            Divider()
            HStack {
                Text("型号号码")
                Spacer()
                Text("MG6W4CH/A")
                    .font(.system(.body, design: .monospaced).weight(.semibold))
                    .foregroundStyle(Color.accentColor)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("关于本机示意：复制型号号码一栏显示的部件号 MG6W4CH/A。")
    }
}
