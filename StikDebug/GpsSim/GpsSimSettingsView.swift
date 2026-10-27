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

/// Which part of Settings to jump to when a one-line home status is tapped.
enum GpsSettingsTarget: Equatable {
    case none
    /// 進階 › 連不上手機時（4G 步驟）
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
            ScrollViewReader { proxy in
            Form {
                if GpsSigning.expiration != nil {
                    // 立即續簽 and the days left; 描述檔 import/cleanup moved to 簽名 › 進階 (spec 1.11).
                    GpsSignSection(onSignIn: { showRenewSignIn = true },
                                   onAdvanced: { showRenewAdvanced = true })
                }
                GpsSimShortcutsSection()

                Section {
                    Toggle("原地微飄（像真手機晃幾公尺）", isOn: $driftEnabled)
                        .frame(minHeight: 44)
                } footer: {
                    Text("像真手機的 GPS 一樣在落點附近輕微飄動，不會離落點超過 4 公尺。")
                }

                Section {
                    Button {
                        withAnimation { advancedOpen.toggle() }
                    } label: {
                        HStack {
                            Text("進階（一般不用動）")
                            Spacer()
                            Image(systemName: advancedOpen ? "chevron.up" : "chevron.down")
                                .accessibilityHidden(true)
                        }
                        .frame(minHeight: 44)
                        .contentShape(Rectangle())
                    }
                    .accessibilityValue(advancedOpen ? "已展開" : "已收合")
                    .accessibilityHint("連不上的說明、地點檔、配對檔、原版 StikDebug 畫面")
                    .accessibilityIdentifier("settings.advanced")
                } footer: {
                    Text("多數時候用不到。")
                }

                if advancedOpen {
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PinFly 要透過 LocalDevVPN（裝 PinFly 時一起裝的 App）才能改定位。")
                        Text("有 Wi-Fi：打開 LocalDevVPN 按連線，回 PinFly 按「重試」。")
                        Text("只有 4G：照這 5 步")
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
                    Text("連不上手機時")
                }

                Section {
                    Button {
                        onMountDDI()
                    } label: {
                        Label("掛載 DDI", systemImage: "externaldrive.badge.plus")
                            .frame(minHeight: 44)
                    }
                    .disabled(mounting.coolisMounted)
                    .id(GpsSettingsTarget.ddi.anchorId ?? "")

                    .accessibilityHint("掛載開發者映像，模擬定位需要它")
                    .accessibilityIdentifier("settings.mountDDI")
                    if mounting.coolisMounted {
                        Text("DDI 已掛載。").font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("開發者映像（DDI）")
                } footer: {
                    Text("首頁顯示「DDI 還沒掛載」時按這裡，會回到首頁開始掛載（第一次先下載約數十 MB）。需要 LocalDevVPN 已連線。")
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
                    Text("地點存在這支手機裡，更新 PinFly 不會不見。匯出可存到「檔案」或傳到電腦備份。")
                }

                Section {
                    Button("匯入配對檔") { confirmPairingReplace = true }
                        .frame(minHeight: 44)
                        .id(GpsSettingsTarget.pairing.anchorId ?? "")

                    if let pairingMessage {
                        Text(pairingMessage).font(.footnote).foregroundStyle(.secondary)
                    }
                } header: {
                    Text("配對檔（連手機用的鑰匙）")
                } footer: {
                    Text("配對檔要用電腦上的 iloader 產生一次（約 5 分鐘）。")
                }

                Section {
                    Button("進階：原始除錯工具（一般不用）") { showAdvanced = true }
                        .frame(minHeight: 44)
                } footer: {
                    Text("原本 StikDebug 的畫面（JIT、裝置資訊、Settings 等）。")
                }
                }

                Section {
                    Button("重設驗證資料", role: .destructive) { confirmRenewReset = true }
                        .frame(minHeight: 44)
                    NavigationLink("開源授權") { GpsSimLicensesView() }
                        .frame(minHeight: 44)
                } footer: {
                    Text("重設會登出 Apple ID 並清掉 anisette 身分，下次續簽要重新登入並輸入驗證碼。")
                }
                .confirmationDialog("重設驗證資料？", isPresented: $confirmRenewReset, titleVisibility: .visible) {
                    Button("登出並重設", role: .destructive) { Task { await GpsRenewCenter.shared.resetAuthData() } }
                    Button("取消", role: .cancel) {}
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
                    Label("回PinFly", systemImage: "chevron.left")
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
