//
//  GpsSimSettingsView.swift
//  StikDebug (GpsSim fork)
//
//  Settings sheet: connection help, drift, places import/export, pairing file,
//  the only way into the original StikDebug screens ("進階 → 除錯工具"), and the version.
//  Place sizes are 小/中/大 on each place now, so the old default-radius slider is gone
//  (places without their own radius still use the stored default, unchanged).
//

import SwiftUI

/// Which part of Settings to jump to when a one-line home status is tapped.
enum GpsSettingsTarget: Equatable {
    case none
    /// 進階 › 無法連線時（行動網路步驟）
    case connection
    /// 進階 › 配對檔
    case pairing
    /// 進階 › 開發者映像（DDI）
    case ddi
    /// 簽名／續簽區（最上面）
    case renew

    fileprivate var needsAdvanced: Bool { self == .connection || self == .pairing || self == .ddi }
    var anchorId: String? {
        switch self {
        case .none: return nil
        case .connection: return "settings.section.connection"
        case .pairing: return "settings.section.pairing"
        case .ddi: return "settings.section.ddi"
        case .renew: return "settings.section.renew"
        }
    }
}

struct GpsSimSettingsView: View {
    /// Places import is presented by the home screen (one fileImporter per view level).
    /// Opens (and scrolls) to the part the home status line points at.
    var startTarget: GpsSettingsTarget = .none
    let onImportPlaces: () -> Void
    /// DDI mounting lives in the home view (it owns the error banner); Settings only triggers it.
    let onMountDDI: () -> Void
    @ObservedObject private var mounting = MountingProgress.shared

    @Environment(\.dismiss) private var dismiss
    @AppStorage(GpsGeo.driftKey) private var driftEnabled = true
    @State private var showPairingImporter = false
    @State private var pairingMessage: String?
    @State private var showAdvanced = false
    @State private var advancedOpen = false
    @State private var confirmPairingReplace = false
    @State private var shortcutMessage: String?
    /// Renewal sign-in sheet and advanced page, opened from the sign section (see GpsSignSection).
    @State private var showRenewSignIn = false
    @State private var showRenewAdvanced = false
    @State private var confirmRenewReset = false
    @ObservedObject private var store = GpsPlaceStore.shared

    /// 「v1.0.0（dcd13a2 · 2026-10-15）」, shown after the 「版本」 label in 關於. CI stamps GpsSimBuild
    /// (short sha · build date) into Info.plist; a local Xcode build without it shows the version only.
    private var versionText: String {
        let v = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        if let build = Bundle.main.infoDictionary?["GpsSimBuild"] as? String, !build.isEmpty {
            return "v\(v)（\(build)）"
        }
        return "v\(v)"
    }

    private var placesFileExists: Bool {
        FileManager.default.fileExists(atPath: GpsPlaceStore.fileURL.path)
    }

    var body: some View {
        NavigationStack {
            ScrollViewReader { proxy in
            Form {
                if GpsSigning.expiration != nil {
                    // 立即續簽 and the days left; 描述檔 import/cleanup moved to 簽名 › 進階 (spec 1.11).
                    GpsSignSection(onSignIn: { showRenewSignIn = true },
                                   onAdvanced: { showRenewAdvanced = true })
                }
                // Signing, then the shortcuts that renew it daily (same subject), then everyday settings,
                // then help; 進階 last (owner screenshots 041-045: help sat between signing and its shortcut).
                GpsSimShortcutsSection()

                Section {
                    Toggle("位置微飄", isOn: $driftEnabled)
                        .frame(minHeight: 44)
                } footer: {
                    Text("模擬實際 GPS 的輕微漂移，與落點的距離不超過 4 公尺。")
                }

                GpsItinerarySettingsSection()

                Section {
                    Button("使用引導") {
                        dismiss()
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { PinFlyOnboardingPresenter.shared.show() }
                    }
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("settings.onboarding")
                    NavigationLink {
                        PinFlyGuideListView(openOnboarding: {
                            dismiss()
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { PinFlyOnboardingPresenter.shared.show() }
                        })
                    } label: {
                        Text("使用教學").frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("settings.guide")
                } header: {
                    Text("說明")
                }

                Section {
                    Button {
                        withAnimation { advancedOpen.toggle() }
                    } label: {
                        HStack {
                            Text("進階")
                            Spacer()
                            Image(systemName: advancedOpen ? "chevron.up" : "chevron.down")
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityValue(advancedOpen ? "已展開" : "已收合")
                    .accessibilityHint("連線說明、地點檔、配對檔、除錯工具、驗證資料")
                    .accessibilityIdentifier("settings.advanced")
                }

                if advancedOpen {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PinFly 需經由 LocalDevVPN 連線，才能變更手機位置。")
                        Text("使用 Wi-Fi 時：開啟 LocalDevVPN 並連線，再回到 PinFly 點選「重試」。")
                        Text("僅使用行動網路時：依下列 5 個步驟操作")
                            .font(.subheadline.weight(.semibold))
                            .padding(.top, 4)
                        ForEach(Array(GpsSimNetwork.fourGStepList.enumerated()), id: \.offset) { index, step in
                            Text("\(index + 1). \(step)")
                        }
                    }
                    .padding(.vertical, 4)
                    .id(GpsSettingsTarget.connection.anchorId ?? "")
                    if let url = GpsSimNetwork.shortcutURL {
                        Button {
                            UIApplication.shared.open(url) { opened in
                                if !opened { shortcutMessage = "找不到捷徑「\(GpsSimNetwork.shortcutName)」" }
                            }
                        } label: {
                            Label("執行捷徑「\(GpsSimNetwork.shortcutName)」", systemImage: "bolt.fill")
                                .frame(minHeight: 44)
                        }
                        .accessibilityHint("開啟「捷徑」App 並執行")
                        .accessibilityIdentifier("settings.shortcut")
                    }
                    if let shortcutMessage {
                        Text(shortcutMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("無法連線時")
                }

                Section {
                    // State first, then the one action (HIG: say what is wrong, then how to fix it).
                    LabeledContent("狀態") {
                        Text(mounting.coolisMounted ? "已掛載" : (mounting.mountingThread != nil ? "掛載中…" : "未掛載"))
                            .foregroundStyle(mounting.coolisMounted ? GpsTheme.mint : .secondary)
                    }
                    .frame(minHeight: 44)
                    .id(GpsSettingsTarget.ddi.anchorId ?? "")
                    .accessibilityIdentifier("settings.ddiState")
                    if !mounting.coolisMounted {
                        Button {
                            onMountDDI()
                        } label: {
                            Label("掛載", systemImage: "externaldrive.badge.plus")
                                .frame(minHeight: 44)
                        }
                        .disabled(mounting.mountingThread != nil)
                        .accessibilityHint("回到首頁開始掛載，首頁上方會顯示進度")
                        .accessibilityIdentifier("settings.mountDDI")
                    }
                } header: {
                    Text("開發者映像（DDI）")
                } footer: {
                    Text("iOS 模擬位置所需的系統元件。已由電腦掛載時會自動偵測。在手機上掛載需 LocalDevVPN 已連線，第一次會下載約數十 MB。")
                }
                .onAppear { mounting.checkforMounted() }

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
                    .accessibilityHint("選取地點檔，取代現有地點")
                    .accessibilityIdentifier("settings.importPlaces")
                    if store.hasImportBackup {
                        Button("已匯入 \(store.placeCount) 個地點｜還原") { store.restoreImportBackup() }
                            .frame(minHeight: 44)
                            .accessibilityLabel("還原匯入前的地點")
                    }
                } header: {
                    Text("地點")
                } footer: {
                    Text("地點儲存於此手機，更新 PinFly 不會遺失。匯出後可存至「檔案」App 或傳送至電腦備份。")
                }

                Section {
                    Button("匯入配對檔") { confirmPairingReplace = true }
                        .frame(minHeight: 44)
                        .id(GpsSettingsTarget.pairing.anchorId ?? "")

                    if let pairingMessage {
                        Text(pairingMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("配對檔")
                } footer: {
                    Text("請依使用教學以電腦產生配對檔。")
                }

                Section {
                    Button("除錯工具") { showAdvanced = true }
                        .frame(minHeight: 44)
                } footer: {
                    Text("JIT、裝置資訊等。")
                }

                // Destructive, so it sits inside 進階 rather than next to 關於.
                Section {
                    Button("重設驗證資料", role: .destructive) { confirmRenewReset = true }
                        .frame(minHeight: 44)
                } header: {
                    Text("驗證資料")
                } footer: {
                    Text("重設會登出 Apple ID 並清除驗證資料，下次續簽需重新登入並輸入驗證碼。")
                }
                .confirmationDialog("重設驗證資料？", isPresented: $confirmRenewReset, titleVisibility: .visible) {
                    Button("登出並重設", role: .destructive) { Task { await GpsRenewCenter.shared.resetAuthData() } }
                    Button("取消", role: .cancel) {}
                }
                }

                Section {
                    LabeledContent("版本") {
                        Text(versionText)
                            .accessibilityIdentifier("settings.version")
                    }
                    .frame(minHeight: 44)
                    NavigationLink("開源授權") { GpsSimLicensesView() }
                        .frame(minHeight: 44)
                    if let url = URL(string: GpsSimLicensesView.pinFlySourceURL) {
                        Link("原始碼", destination: url)
                            .frame(minHeight: 44)
                    }
                } header: {
                    Text("關於")
                }
            }
            .onAppear {
                guard startTarget != .none else { return }
                if startTarget.needsAdvanced { advancedOpen = true }
                // Wait a beat so the expanded 進階 sections exist before scrolling to one.
                if let anchor = startTarget.anchorId {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        withAnimation { proxy.scrollTo(anchor, anchor: .top) }
                    }
                }
            }
            }
            .navigationTitle("設定")
            .navigationDestination(isPresented: $showRenewAdvanced) {
                GpsRenewAdvancedPage()
            }
            .sheet(isPresented: $showRenewSignIn) {
                GpsRenewSignInSheet(origin: .renewAfter).preferredColorScheme(.dark)
            }
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
            Text("新的配對檔會取代目前的配對檔，匯入後需重新連線。")
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
        .task {
            await GpsProfileRenew.refreshFromPhone()
            GpsRenewCenter.shared.bumpSign()
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
                    Label("返回 PinFly", systemImage: "chevron.left")
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
