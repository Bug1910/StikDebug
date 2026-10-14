//
//  GpsSimSettingsView.swift
//  StikDebug (GpsSim fork)
//
//  Settings sheet: connection help, drift, places import/export, pairing file, language,
//  the only way into the original StikDebug screens ("進階 (StikDebug)"), and the version.
//  Place sizes are 小/中/大 on each place now, so the old default-radius slider is gone
//  (places without their own radius still use the stored default, unchanged).
//

import SwiftUI

struct GpsSimSettingsView: View {
    /// Places import is presented by the home screen (one fileImporter per view level).
    let onImportPlaces: () -> Void

    @Environment(\.dismiss) private var dismiss
    @AppStorage(GpsGeo.driftKey) private var driftEnabled = true
    @State private var showPairingImporter = false
    @State private var pairingMessage: String?
    @State private var showAdvanced = false
    @State private var confirmPairingReplace = false
    @ObservedObject private var store = GpsPlaceStore.shared

    /// 「版本 v1.0.0（dcd13a2 · 2026-10-15）」. CI stamps GpsSimBuild (short sha · build date)
    /// into Info.plist; a local Xcode build without it shows the version only.
    private var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        if let build = Bundle.main.infoDictionary?["GpsSimBuild"] as? String, !build.isEmpty {
            return String(localized: "版本 v\(v)（\(build)）")
        }
        return String(localized: "版本 v\(v)")
    }

    private var placesFileExists: Bool {
        FileManager.default.fileExists(atPath: GpsPlaceStore.fileURL.path)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("1. 手機連上 Wi-Fi（沒有 Wi-Fi 可試飛航模式，未確認）")
                        Text("2. 打開 LocalDevVPN")
                        Text("3. 回定位儀按「重試」")
                    }
                    .padding(.vertical, 4)
                } header: {
                    Text("連不上？")
                }

                Section {
                    if placesFileExists, store.placeCount > 0 {
                        ShareLink(item: GpsPlaceStore.fileURL) {
                            Label("匯出地點（\(store.placeCount) 個）", systemImage: "square.and.arrow.up")
                                .frame(minHeight: 44)
                        }
                        .accessibilityIdentifier("settings.exportPlaces")
                    }
                    Button {
                        onImportPlaces()
                    } label: {
                        Label("匯入地點檔（取代目前 \(store.placeCount) 個）", systemImage: "square.and.arrow.down")
                            .frame(minHeight: 44)
                    }
                    .accessibilityHint("選一個 places.json 檔，取代現有地點")
                    .accessibilityIdentifier("settings.importPlaces")
                    if store.hasImportBackup {
                        Button("已匯入 \(store.placeCount) 個｜還原舊的") { store.restoreImportBackup() }
                            .frame(minHeight: 44)
                            .accessibilityLabel("還原匯入前的舊地點")
                    }
                } header: {
                    Text("地點")
                } footer: {
                    Text("地點存在本機的 places.json，更新 App 不會清掉。匯出可存到「檔案」或傳到電腦備份。")
                }

                Section {
                    Toggle("原地微飄（像真手機晃幾公尺）", isOn: $driftEnabled)
                        .frame(minHeight: 44)
                } footer: {
                    Text("像真手機的 GPS 一樣在落點附近輕微飄動，不會離落點超過 4 公尺。")
                }

                Section {
                    Button("匯入配對檔") { confirmPairingReplace = true }
                        .frame(minHeight: 44)
                    if let pairingMessage {
                        Text(pairingMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("配對檔")
                }

                Section {
                    Button {
                        if let url = URL(string: UIApplication.openSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    } label: {
                        Label("語言", systemImage: "globe")
                            .frame(minHeight: 44)
                    }
                    .accessibilityHint("打開 iOS 設定裡本 App 的頁面")
                    .accessibilityIdentifier("settings.language")
                } footer: {
                    Text("在 iOS 設定的「語言」選繁體中文或 English。")
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
                        .accessibilityIdentifier("settings.version")
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
                    pairingMessage = String(localized: "配對檔已匯入。")
                } catch {
                    pairingMessage = String(localized: "匯入失敗：\(error.localizedDescription)")
                }
            case .failure(let error):
                pairingMessage = String(localized: "匯入失敗：\(error.localizedDescription)")
            }
        }
        .fullScreenCover(isPresented: $showAdvanced) {
            GpsSimAdvancedView()
        }
        .gpsSimPadSheetSizing()
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
