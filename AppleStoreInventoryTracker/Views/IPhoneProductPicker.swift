import SwiftUI

struct IPhoneProductPicker: View {
    @Binding var product: IPhoneVariant?
    var service: IPhoneCatalogService = .shared
    @State private var catalog: IPhoneCatalog?
    @State private var selection = IPhoneSelection()
    @State private var loading = false
    @State private var message: String?
    @State private var image: NSImage?

    private var model: IPhoneModel? { catalog?.models.first { $0.id == selection.modelID } }
    private var colors: [IPhoneVariant] {
        var seen = Set<String>()
        return (model?.variants ?? []).filter { seen.insert($0.colorID).inserted }
    }
    private var capacities: [IPhoneVariant] {
        model?.variants.filter { $0.colorID == selection.colorID } ?? []
    }

    var body: some View {
        Section {
            if let catalog {
                Picker("机型", selection: Binding(get: { selection.modelID }, set: { selection.selectModel($0) })) {
                    Text("选择机型").tag("")
                    ForEach(catalog.models) { Text($0.name).tag($0.id) }
                }
                .pickerStyle(.menu)
                Picker("颜色", selection: Binding(get: { selection.colorID }, set: { selection.selectColor($0, in: catalog) })) {
                    Text("选择颜色").tag("")
                    ForEach(colors) { Text($0.color).tag($0.colorID) }
                }
                .pickerStyle(.menu)
                .disabled(model == nil)
                Picker("容量", selection: $selection.capacityID) {
                    Text("选择容量").tag("")
                    ForEach(capacities) { Text($0.capacity).tag($0.capacityID) }
                }
                .pickerStyle(.menu)
                .disabled(selection.colorID.isEmpty)

                if let product {
                    HStack(spacing: 12) {
                        Group {
                            if let image { Image(nsImage: image).resizable().scaledToFit() }
                            else { Image(systemName: "iphone").font(.title2).foregroundStyle(.secondary) }
                        }
                        .frame(width: 48, height: 56)
                        .accessibilityHidden(true)
                        Text(product.displayName).font(.callout).fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.vertical, 4)
                }
            } else if loading {
                HStack(spacing: 10) {
                    ProgressView().controlSize(.small)
                    Text("正在加载 iPhone…").foregroundStyle(.secondary)
                }
            } else {
                Text("暂未获取商品目录").foregroundStyle(.secondary)
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        } header: {
            HStack {
                Text("选择产品")
                Spacer()
                if loading, catalog != nil { ProgressView().controlSize(.mini) }
                Button {
                    Task { await load(forceRefresh: true) }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .buttonStyle(.plain)
                .disabled(loading)
                .help("刷新在售 iPhone")
                .accessibilityLabel("刷新在售 iPhone")
            }
        }
        .task { await load(forceRefresh: false) }
        .onChange(of: selection) { _, _ in product = selection.variant(in: catalog) }
        .task(id: product?.partNumber) {
            image = nil
            guard let product, let data = await ProductImageLoader.shared.imageData(for: product.partNumber, sourceURL: product.imageURL),
                  !Task.isCancelled else { return }
            image = NSImage(data: data)
        }
    }

    @MainActor
    private func load(forceRefresh: Bool) async {
        guard !loading else { return }
        loading = true
        message = nil
        defer { loading = false }
        if catalog == nil { catalog = await service.cachedCatalog() }
        do {
            let fresh = try await service.load(forceRefresh: forceRefresh)
            guard !Task.isCancelled else { return }
            catalog = fresh
            if !fresh.models.contains(where: { $0.id == selection.modelID }) {
                selection = IPhoneSelection()
            } else if !colors.contains(where: { $0.colorID == selection.colorID }) {
                selection.colorID = ""
                selection.capacityID = ""
            } else if selection.variant(in: fresh) == nil {
                selection.capacityID = ""
            }
            product = selection.variant(in: fresh)
        } catch {
            guard !Task.isCancelled else { return }
            message = catalog == nil ? "加载失败，请稍后刷新重试。" : "刷新失败，当前显示上次保存的商品目录。"
        }
    }
}
