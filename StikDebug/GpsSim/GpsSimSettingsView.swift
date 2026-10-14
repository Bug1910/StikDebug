//
//  GpsSimSettingsView.swift
//  StikDebug (GpsSim fork)
//
//  Settings sheet: default radius, drift, pairing/places import, and the only
//  way into the original StikDebug screens ("進階 (StikDebug)").
//

import SwiftUI

struct GpsSimSettingsView: View {
    /// Places import is presented by the home screen (one fileImporter per view level).
    let onImportPlaces: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(GpsGeo.defaultRadiusKey) private var defaultRadius: Double = 25
    @AppStorage(GpsGeo.driftKey) private var driftEnabled = true
    @State private var showPairingImporter = false
    @State private var pairingMessage: String?
    @State private var showAdvanced = false
    @State private var confirmPairingReplace = false
    @ObservedObject private var store = GpsPlaceStore.shared

    private var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let b = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        return "GpsSim fork · 以 StikDebug \(v)（\(b)）為基底"
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack {
                        Text("預設半徑 \(Int(defaultRadius)) 公尺").monospacedDigit()
                        Spacer()
                        Stepper("預設半徑", value: $defaultRadius, in: 5...1000, step: 5).labelsHidden()
                    }
                    Slider(value: $defaultRadius, in: 5...1000, step: 5)
                        .accessibilityLabel("預設半徑")
                } header: {
                    Text("落點")
                } footer: {
                    Text("沒有自訂半徑的地點都用這個值。")
                }

                Section {
                    Toggle("原地微飄（像真手機晃幾公尺）", isOn: $driftEnabled)
                        .frame(minHeight: 44)
                } footer: {
                    Text("像真手機的 GPS 一樣在落點附近輕微飄動，不會離落點超過 4 公尺。")
                }

                Section {
                    Button("匯入地點檔（會取代目前 \(store.placeCount) 個地點）") { onImportPlaces() }
                        .frame(minHeight: 44)
                        .accessibilityHint("選一個 places.json 檔，取代現有地點")
                    if store.hasImportBackup {
                        Button("已匯入 \(store.placeCount) 個｜還原舊的") { store.restoreImportBackup() }
                            .frame(minHeight: 44)
                            .accessibilityLabel("還原匯入前的舊地點")
                    }
                    Button("匯入配對檔") { confirmPairingReplace = true }
                        .frame(minHeight: 44)
                    if let pairingMessage {
                        Text(pairingMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("檔案")
                } footer: {
                    Text("電腦也可以直接把 places.json 放進本 App 的「文件」資料夾，回到 App 或下拉清單就會重新讀取。")
                }

                Section {
                    Button("進階 (StikDebug)") { showAdvanced = true }
                        .frame(minHeight: 44)
                } footer: {
                    Text("原本 StikDebug 的畫面（JIT、裝置資訊、Settings 等）。")
                }

                Section {
                    Text(versionText)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .listRowBackground(Color.clear)
                }
            }
            .navigationTitle("設定")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("完成") { dismiss() }
                }
            }
        }
        .alert("覆蓋現有配對檔？", isPresented: $confirmPairingReplace) {
            Button("選擇新的配對檔", role: .destructive) { showPairingImporter = true }
            Button("取消", role: .cancel) {}
        } message: {
            Text("新的配對檔會取代目前這份，匯入後需要重新連線。")
        }
        .fileImporter(
            isPresented: $showPairingImporter,
            allowedContentTypes: PairingFileStore.supportedContentTypes,
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                do {
                    try PairingFileStore.importFromPicker(url)
                    markTunnelDisconnected()
                    startTunnelInBackground(showErrorUI: false)
                    NotificationCenter.default.post(name: .pairingFileImported, object: nil)
                    pairingMessage = "配對檔已匯入。"
                } catch {
                    pairingMessage = "匯入失敗：\(error.localizedDescription)"
                }
            case .failure(let error):
                pairingMessage = "匯入失敗：\(error.localizedDescription)"
            }
        }
        .fullScreenCover(isPresented: $showAdvanced) {
            GpsSimAdvancedView()
        }
    }
}

/// The stock StikDebug tab bar, presented full screen with a way back.
struct GpsSimAdvancedView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selection: String = AppFeature.home.id

    var body: some View {
        TabView(selection: $selection) {
            ForEach(AppFeature.mainTabs) { feature in
                feature.destination
                    .tabItem { Label(feature.title, systemImage: feature.systemImage) }
                    .tag(feature.id)
            }
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            HStack {
                Button {
                    dismiss()
                } label: {
                    Label("回定位儀", systemImage: "chevron.left")
                        .font(.headline)
                        .frame(minHeight: 44)
                }
                Spacer()
            }
            .padding(.horizontal, 16)
            .background(.bar)
        }
    }
}
