//
//  StoreInventoryView.swift
//  AppleStoreInventoryTracker
//
//  Created by Chenjun Ren on 2023/10/17.
//

import SwiftUI

struct StoreInventoryView: View {
    
    let store: StoreInventoryInfo
    
    var body: some View {
        HStack {
            AsyncImage(url: .init(string: store.storeImageUrl)) { image in
                image
                    .resizable()
                    .scaledToFill()
            } placeholder: {
                Image(systemName: "photo")
                    .font(.system(size: 50))
                    .foregroundStyle(.secondary.opacity(0.5))
            }
            .frame(width: 100, height: 100 * 621/828)
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            
            Spacer()
            
            VStack(alignment: .trailing, spacing: 8) {
                Text(store.storeName)
                    .font(.title3)
                    .bold()
                
                Text(store.isProductAvailable ? "今天可取货" : "暂无供应")
                    .foregroundStyle(store.isProductAvailable ? .green : .secondary)
                    .font(.title3)
            }
        }
        .padding()
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(.separator, lineWidth: 2)
        )
    }
}

#Preview {
    VStack {
        StoreInventoryView(
            store: .init(
                storeName: "上海环贸 iapm",
                storeImageUrl: "https://rtlimages.apple.com/cmc/dieter/store/4_3/R401.png?resize=828:*&output-format=jpg",
                productName: "15 英寸 MacBook Air (M2 芯片机型) - 午夜色",
                isProductAvailable: true
            )
        )
    }
    .frame(width: 500, height: 400)
}
