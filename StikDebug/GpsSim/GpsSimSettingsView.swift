//
//  GpsSimSettingsView.swift
//  StikDebug (GpsSim fork)
//
//  Settings sheet: connection help, drift, places import/export, pairing file,
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
    @State private var shortcutMessage: String?
    @State private var showProfileImporter = false
    @State private var profileMessage: String?
    @State private var profileBusy = false
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

    private func runProfileImport(_ result: Result<[URL], Error>) {
        profileBusy = true
        profileMessage = "處理中…"
        Task {
            defer { profileBusy = false }
            do {
                guard let url = try result.get().first else { return }
                let data = try GpsProfileRenew.readPicked(url)
                let expiry = try await GpsProfileRenew.install(data)
                profileMessage = "已換新描述檔，簽名到 \(GpsProfileRenew.expiryText(expiry))"
            } catch {
                profileMessage = "沒有換：\(error.localizedDescription)"
            }
        }
    }

    private func runProfileCleanup() {
        profileBusy = true
        Task {
            defer { profileBusy = false }
            do {
                let count = try await GpsProfileRenew.removeOwnExpired()
                profileMessage = count == 0 ? "沒有過期的舊描述檔。" : "已清掉 \(count) 個過期的舊描述檔。"
            } catch {
                profileMessage = "清除失敗：\(error.localizedDescription)"
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                if GpsSigning.expiration != nil {
                    Section {
                        // Re-reads the days left every minute while the sheet stays open.
                        TimelineView(.periodic(from: .now, by: 60)) { context in
                            Text(GpsSigning.settingsText(now: context.date) ?? "")
                                .foregroundStyle(GpsSigning.isExpired(now: context.date) ? GpsTheme.red : Color.primary)
                                .frame(minHeight: 44, alignment: .leading)
                                .accessibilityIdentifier("settings.signExpiry")
                        }
                        Button {
                            showProfileImporter = true
                        } label: {
                            Label("匯入描述檔（不用重裝）", systemImage: "doc.badge.plus").frame(minHeight: 44)
                        }
                        .disabled(profileBusy)
                        .accessibilityIdentifier("settings.importProfile")
                        // Separate view level: two fileImporters on one view only honor the last one.
                        .background {
                            Color.clear.fileImporter(isPresented: $showProfileImporter,
                                                     allowedContentTypes: GpsProfileRenew.fileTypes,
                                                     allowsMultipleSelection: false) { result in
                                runProfileImport(result)
                            }
                        }
                        Button("清掉過期的舊描述檔（只清定位儀自己的）") { runProfileCleanup() }
                            .disabled(profileBusy)
                            .frame(minHeight: 44)
                        if let profileMessage {
                            Text(profileMessage).font(.footnote).foregroundStyle(.secondary)
                        }
                    } header: {
                        Text("簽名")
                    } footer: {
                        Text("免費 Apple ID 的簽名每 7 天到期；到期前打開 SideStore 按 Refresh All，或接電腦按「定位儀續簽」。")
                    }
                }
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("有 Wi-Fi 時：打開 LocalDevVPN，回定位儀按「重試」。")
                        Text("只有 4G 時：開 LocalDevVPN → 開飛航 → 開 Wi-Fi → 回定位儀點地點 → 關飛航（假定位會保留）。")
                    }
                    .padding(.vertical, 4)
                    if let url = GpsSimNetwork.shortcutURL {
                        Button {
                            UIApplication.shared.open(url) { opened in
                                if !opened { shortcutMessage = "找不到捷徑「\(GpsSimNetwork.shortcutName)」" }
                            }
                        } label: {
                            Label("用捷徑「\(GpsSimNetwork.shortcutName)」一鍵完成", systemImage: "bolt.fill")
                                .frame(minHeight: 44)
                        }
                        .accessibilityHint("打開「捷徑」App 執行")
                        .accessibilityIdentifier("settings.shortcut")
                    }
                    if let shortcutMessage {
                        Text(shortcutMessage).font(.footnote).foregroundStyle(.secondary)
                    }
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
