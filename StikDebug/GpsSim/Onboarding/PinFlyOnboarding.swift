//
//  PinFlyOnboarding.swift
//  StikDebug (GpsSim fork)
//
//  First-run guide: six short steps (開發者模式 -> 配對檔 -> LocalDevVPN -> 登入 Apple -> 測試定位 -> 捷徑).
//  It owns no logic of its own: every action button jumps to a screen that already exists
//  (Settings > 配對檔, the Apple sign-in sheet, ...) and every status line only reads state the app
//  already has. Shown once automatically, re-openable from Settings > 使用引導.
//  Kept in its own file so the hooks in HomeView / SettingsView stay one line each.
//

import SwiftUI

// MARK: - Steps

enum PinFlyOnboardingStep: Int, CaseIterable {
    case developerMode, pairing, vpn, signIn, testLocation, shortcuts

    var title: String {
        switch self {
        case .developerMode: return "開發者模式"
        case .pairing: return "配對檔"
        case .vpn: return "LocalDevVPN"
        case .signIn: return "登入 Apple"
        case .testLocation: return "測試定位"
        case .shortcuts: return "捷徑"
        }
    }

    var detail: String {
        switch self {
        case .developerMode: return "請至「設定 › 隱私權與安全性 › 開發者模式」開啟，開啟後裝置會重新啟動。"
        case .pairing: return "配對檔用於連線此裝置，請依安裝教學以電腦產生後匯入。"
        case .vpn: return "PinFly 需經由 LocalDevVPN 連線裝置。請開啟 LocalDevVPN 並連線，再回到 PinFly。"
        case .signIn: return "登入後可自動續簽 7 天簽名，無需連接電腦。"
        case .testLocation: return "選擇地點並確認定位已變更。"
        case .shortcuts: return "於「捷徑」App 建立一次自動化，之後即可自動續簽。"
        }
    }

    var actionTitle: String {
        switch self {
        case .developerMode: return "開啟「設定」App"
        case .pairing: return "匯入配對檔"
        case .vpn: return "連線說明"
        case .signIn: return "登入"
        case .testLocation: return "回到地圖"
        case .shortcuts: return "打開捷徑 App"
        }
    }

    var identifier: String {
        switch self {
        case .developerMode: return "onboarding.devmode"
        case .pairing: return "onboarding.pairing"
        case .vpn: return "onboarding.vpn"
        case .signIn: return "onboarding.signin"
        case .testLocation: return "onboarding.test"
        case .shortcuts: return "onboarding.shortcuts"
        }
    }
}

/// What the guide can tell about a step. `unknown` is honest: iOS gives no way to read developer
/// mode, and "no VPN seen" is never reported as "VPN is off" (GpsSimNetwork.vpnSeen is a positive signal only).
enum PinFlyOnboardingStatus {
    case done, notYet, unknown

    var text: String {
        switch self {
        case .done: return "已完成"
        case .notYet: return "尚未完成"
        case .unknown: return "無法自動檢查"
        }
    }
    var symbol: String {
        switch self {
        case .done: return "checkmark.circle.fill"
        case .notYet: return "circle.dashed"
        case .unknown: return "questionmark.circle"
        }
    }
    var color: Color {
        switch self {
        case .done: return GpsTheme.mint
        case .notYet: return GpsTheme.orange
        case .unknown: return GpsTheme.sub
        }
    }
}

/// Where an action button sends the person; the host (home screen) performs it after the sheet closes.
enum PinFlyOnboardingJump {
    case settings(GpsSettingsTarget)
    case signIn
    case none
}

// MARK: - Presenter (lets Settings re-open the guide without touching the home view)

@MainActor
final class PinFlyOnboardingPresenter: ObservableObject {
    static let shared = PinFlyOnboardingPresenter()
    @Published var isPresented = false
    func show() { isPresented = true }
}

// MARK: - Host modifier (the single hook in GpsSimHomeView)

private struct PinFlyOnboardingHost: ViewModifier {
    @ObservedObject private var presenter = PinFlyOnboardingPresenter.shared
    @AppStorage("pinfly.onboarding.done") private var shownOnce = false
    let openSettings: (GpsSettingsTarget) -> Void
    let openSignIn: () -> Void

    /// Not under CI / UI tests: a first-launch sheet would cover the buttons the scenario scripts tap.
    /// CI runs on the iOS simulator without launch arguments, so the simulator check is the main guard.
    private var autoShowAllowed: Bool {
        #if targetEnvironment(simulator)
        return false
        #else
        let info = ProcessInfo.processInfo
        if info.arguments.contains("-GpsSimDemo") { return false }
        if info.environment["XCTestConfigurationFilePath"] != nil { return false }
        if MockRenewBackend.isEnabled { return false }
        return true
        #endif
    }

    func body(content: Content) -> some View {
        content
            .sheet(isPresented: $presenter.isPresented) {
                PinFlyOnboardingView { jump in
                    presenter.isPresented = false
                    // Let the guide finish dismissing before the next sheet is presented.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {
                        switch jump {
                        case .settings(let target): openSettings(target)
                        case .signIn: openSignIn()
                        case .none: break
                        }
                    }
                }
                // Marked as seen only once the guide is really on screen; closing it never makes it nag again.
                .onAppear { shownOnce = true }
                .preferredColorScheme(.dark)
            }
            .task {
                guard !shownOnce, autoShowAllowed else { return }
                // A sheet that is already open swallows the request silently, so retry until the guide really appeared.
                for _ in 0..<20 {
                    try? await Task.sleep(nanoseconds: 3_000_000_000)
                    if shownOnce { break }
                    presenter.show()
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    if !shownOnce { presenter.isPresented = false }
                }
            }
    }
}

extension View {
    /// Hook for the home screen: presents the first-run guide and performs its jump actions.
    func pinFlyOnboarding(openSettings: @escaping (GpsSettingsTarget) -> Void,
                          openSignIn: @escaping () -> Void) -> some View {
        modifier(PinFlyOnboardingHost(openSettings: openSettings, openSignIn: openSignIn))
    }
}

// MARK: - The guide

struct PinFlyOnboardingView: View {
    let onJump: (PinFlyOnboardingJump) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @ObservedObject private var network = GpsSimNetwork.shared
    @ObservedObject private var tunnel = TunnelManager.shared
    @ObservedObject private var engine = GpsSimEngine.shared
    @ObservedObject private var renew = GpsRenewCenter.shared
    @State private var index = 0
    /// The pairing file is a plain file, not published state, so re-read it on a slow tick.
    @State private var pairingPresent = GpsSimEngine.pairingExists
    private let recheck = Timer.publish(every: 2, on: .main, in: .common).autoconnect()

    private let steps = PinFlyOnboardingStep.allCases
    private var step: PinFlyOnboardingStep { steps[index] }
    private var isLast: Bool { index == steps.count - 1 }

    private func status(of step: PinFlyOnboardingStep) -> PinFlyOnboardingStatus {
        switch step {
        case .developerMode, .shortcuts: return .unknown
        case .pairing: return pairingPresent ? .done : .notYet
        case .vpn: return (network.vpnSeen || tunnel.isConnected) ? .done : .notYet
        case .signIn: return renew.status.signedIn ? .done : .notYet
        case .testLocation: return engine.activeName != nil ? .done : .notYet
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    progress
                    card
                    buttons
                }
                .padding(20)
            }
            .background(GpsTheme.background.ignoresSafeArea())
            .navigationTitle("使用引導")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("關閉") { dismiss() }
                        .accessibilityIdentifier("onboarding.close")
                }
            }
        }
        .onReceive(recheck) { _ in pairingPresent = GpsSimEngine.pairingExists }
        .onReceive(NotificationCenter.default.publisher(for: .pairingFileImported)) { _ in
            pairingPresent = GpsSimEngine.pairingExists
        }
    }

    private var progress: some View {
        VStack(alignment: .leading, spacing: 6) {
            ProgressView(value: Double(index + 1), total: Double(steps.count))
                .tint(GpsTheme.mint)
                .accessibilityHidden(true)
            Text("第 \(index + 1) 步，共 \(steps.count) 步")
                .font(.footnote)
                .foregroundStyle(GpsTheme.sub)
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("onboarding.progress")
    }

    private var card: some View {
        let current = status(of: step)
        return VStack(alignment: .leading, spacing: 12) {
            Text(step.title).font(.title2.weight(.bold)).foregroundStyle(.white)
            Text(step.detail)
                .font(.body)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                Image(systemName: current.symbol).foregroundStyle(current.color).accessibilityHidden(true)
                Text(current.text).font(.subheadline).foregroundStyle(current.color)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("狀態：\(current.text)")
            .accessibilityIdentifier("onboarding.status")
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }

    private var buttons: some View {
        VStack(spacing: 10) {
            Button(step.actionTitle) { perform(step) }
                .buttonStyle(GpsFilledButtonStyle())
                .accessibilityLabel("\(step.title)：\(step.actionTitle)")
                .accessibilityIdentifier(step.identifier)
            HStack(spacing: 10) {
                if index > 0 {
                    Button("上一步") { index -= 1 }
                        .buttonStyle(GpsOutlineButtonStyle())
                        .accessibilityIdentifier("onboarding.back")
                }
                // Same button either way: 略過 while the step is open, 下一步 / 完成 once it is done.
                Button(skipTitle) { advance() }
                    .buttonStyle(GpsOutlineButtonStyle())
                    .accessibilityIdentifier("onboarding.skip")
            }
        }
    }

    private var skipTitle: String {
        if isLast { return "完成" }
        return status(of: step) == .done ? "下一步" : "略過"
    }

    private func advance() {
        if isLast { dismiss() } else { index += 1 }
    }

    private func perform(_ step: PinFlyOnboardingStep) {
        switch step {
        case .developerMode:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        case .pairing: onJump(.settings(.pairing))
        case .vpn: onJump(.settings(.connection))
        case .signIn: onJump(.signIn)
        case .testLocation: onJump(.none)
        case .shortcuts:
            if let url = URL(string: "shortcuts://") { openURL(url) }
        }
    }
}
