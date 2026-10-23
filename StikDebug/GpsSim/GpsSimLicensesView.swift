//
//  GpsSimLicensesView.swift
//  StikDebug (GpsSim fork) - experimental renew copy
//
//  "開源授權" page: the open-source parts this build ships, with their licenses and source links.
//

import SwiftUI

struct GpsSimLicensesView: View {
    struct Item: Identifiable {
        let name: String
        let license: String
        let url: String
        let note: String
        var id: String { name }
    }

    static let items: [Item] = [
        Item(name: "StikDebug", license: "AGPL-3.0", url: "https://github.com/StikDebug/StikDebug",
             note: "PinFly是從它修改來的。"),
        Item(name: "SideSign (commit 752d1ef)", license: "GPL-3.0", url: "https://github.com/SideStore/SideSign",
             note: "登入 Apple ID、下載描述檔（續簽用）。"),
        Item(name: "AnisetteKit (db8b410)", license: "AGPL-3.0", url: "https://github.com/mahee96/AnisetteKit",
             note: "向 anisette 伺服器取得 Mac 身分資料。"),
        Item(name: "GSACryptoKit (eae2590)", license: "AGPL-3.0", url: "https://github.com/mahee96/GSACryptoKit",
             note: "Apple 登入用的加密運算。"),
        Item(name: "CodeSignKit (d0c6771)", license: "AGPL-3.0", url: "https://github.com/mahee96/CodeSignKit",
             note: "憑證與描述檔解析。"),
        Item(name: "libdeflate (da6c7da)", license: "MIT", url: "https://github.com/SideStore/libdeflate",
             note: "壓縮。"),
        Item(name: "swift-crypto 4.3.1 / swift-asn1 1.6.0", license: "Apache-2.0", url: "https://github.com/apple/swift-crypto",
             note: "加密與 ASN.1 解析。"),
        Item(name: "Unicorn (AnisetteKit 內附)", license: "GPL-2.0", url: "https://github.com/unicorn-engine/unicorn",
             note: "AnisetteKit 連結的 CPU 模擬器。"),
    ]

    var body: some View {
        List {
            Section {
                ForEach(Self.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.name).font(.headline)
                            Spacer()
                            Text(item.license).font(.subheadline.monospaced()).foregroundStyle(.secondary)
                        }
                        Text(item.note).font(.footnote).foregroundStyle(.secondary)
                        if let url = URL(string: item.url) {
                            Link(item.url, destination: url).font(.footnote)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } footer: {
                Text("這個版本含上列開源元件，原始碼可在各連結取得。PinFly本身依 AGPL-3.0 釋出。")
            }
        }
        .navigationTitle("開源授權")
        .navigationBarTitleDisplayMode(.inline)
    }
}
