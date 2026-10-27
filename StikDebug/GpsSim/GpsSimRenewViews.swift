//
//  GpsSimRenewViews.swift
//  StikDebug (GpsSim fork)
//
//  The screens for renewing the 7-day signature on the phone (design spec section 1):
//  the settings 「簽名」 section, the 「Apple 帳號與續簽」 and 「進階」 pages, the 3-step sign-in
//  sheet, the 4-step progress list, the failure card, and the home reminder card.
//  They only talk to GpsRenewCenter; none of them knows how the renewal is done.
//

import SwiftUI
import UIKit

// MARK: - Shared pieces

/// Where the signature stands right now (spec 1.4 table).
struct GpsSignState {
    enum Level { case ok, soon, today, expired }

    let expiry: Date
    let now: Date

    var days: Int { Int((expiry.timeIntervalSince(now) / 86_400).rounded(.down)) }
    var hours: Int { Int((expiry.timeIntervalSince(now) / 3_600).rounded(.down)) }

    var level: Level {
        if expiry <= now { return .expired }
        if hours < 24 { return .today }
        return days <= 2 ? .soon : .ok
    }

    /// 「剩 6 天」/「剩 5 小時」/「剩不到 1 小時」.
    var remaining: String {
        if days >= 1 { return "剩 \(days) 天" }
        return hours >= 1 ? "剩 \(hours) 小時" : "剩不到 1 小時"
    }

    func headline(signedIn: Bool) -> String {
        if level == .expired { return "簽名已過期" }
        if !signedIn { return "\(remaining)（尚未登入 Apple，不能自動續簽）" }
        switch level {
        case .today: return "\(remaining)，今天要續簽"
        case .soon: return "\(remaining)，該續簽了"
        default: return remaining
        }
    }

    /// Mint 剩 >2 天, yellow 1-2 days, yellow triangle under a day, red octagon expired.
    @ViewBuilder var indicator: some View {
        switch level {
        case .ok: Image(systemName: "circle.fill").foregroundStyle(GpsTheme.mint)
        case .soon: Image(systemName: "circle.fill").foregroundStyle(GpsTheme.yellow)
        case .today: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(GpsTheme.yellow)
        case .expired: Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(GpsTheme.red)
        }
    }

    /// Prominent (filled mint) once 2 days or less are left; plain before that so it does not shout.
    var prominentButton: Bool { level != .ok }
}

/// Mint fill, dark text (onAccent on mint 13.56:1). Taller than 50 pt and wraps at large sizes.
struct GpsFilledButtonStyle: ButtonStyle {
    var fill: Color = GpsTheme.mint

    func makeBody(configuration: Configuration) -> some View {
        GpsFilledButtonBody(configuration: configuration, fill: fill)
    }
}

private struct GpsFilledButtonBody: View {
    let configuration: ButtonStyleConfiguration
    let fill: Color
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.headline)
            // Disabled = card fill + grey text + thin border (designer spec), not just a dimmed mint.
            .foregroundStyle(isEnabled ? GpsTheme.onAccent : GpsTheme.sub)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, minHeight: 50)
            .background((isEnabled ? fill : GpsTheme.card).opacity(configuration.isPressed ? 0.8 : 1),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(GpsTheme.idleBorder, lineWidth: isEnabled ? 0 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

/// Outline button for the less important choice (稍後、取消續簽).
struct GpsOutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        GpsOutlineButtonBody(configuration: configuration)
    }
}

private struct GpsOutlineButtonBody: View {
    let configuration: ButtonStyleConfiguration
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(isEnabled ? Color.white : GpsTheme.sub)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 14)
            .padding(.vertical, 4)
            .frame(minWidth: 44, minHeight: 44)
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : 0),
                        in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(isEnabled ? GpsTheme.idleBorder : Color.white.opacity(0.1), lineWidth: 1))
            .contentShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

extension GpsRenewCenter {
    /// One place that decides what a failure's button does, for every screen.
    func perform(_ action: RenewAction, openSignIn: () -> Void, openAdvanced: () -> Void) {
        switch action {
        case .retry, .install:
            dismissFailure()
            if !renewNow() { openSignIn() }
        case .signInAgain, .signInAndRenew, .reenterCode:
            dismissFailure()
            openSignIn()
        case .acknowledge:
            dismissFailure()
        case .changeServer:
            dismissFailure()
            openAdvanced()
        }
    }
}

/// 「上次續簽：10/22 17:46 成功」 or 「…沒成功（驗證伺服器太慢）」, in grey either way.
@MainActor
private func lastRenewLine(_ renew: GpsRenewCenter) -> String? {
    if let r = renew.lastRecord {
        let when = GpsRenewCopy.dateTime(r.at)
        if r.succeeded {
            // The expiry is already the line above: no second date here.
            return "上次續簽：\(when) 成功"
        }
        return "上次續簽：\(when) 沒成功（\(r.reason ?? "原因不明")）"
    }
    if let last = renew.status.lastSuccess { return "上次續簽：\(GpsRenewCopy.dateTime(last)) 成功" }
    return nil
}

// MARK: - Progress (spec 1.7)

/// Four numbered rows with a running clock. Steps 1-3 can be cancelled; step 4 cannot.
struct GpsRenewProgressView: View {
    @ObservedObject private var renew = GpsRenewCenter.shared

    var body: some View {
        if case .running(let step, let start, let stepStart, let durations) = renew.phase {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    Text("續簽中　已 \(max(0, Int(context.date.timeIntervalSince(start)))) 秒")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .accessibilityIdentifier("renew.progress.title")
                    ForEach(RenewStep.allCases, id: \.self) { s in
                        row(s, current: step, durations: durations)
                    }
                    if step == .anisette, context.date.timeIntervalSince(stepStart) > 10 {
                        Text("驗證伺服器比較慢，最多等 30 秒。")
                            .font(.footnote)
                            .foregroundStyle(GpsTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    cancelButton
                }
                .padding(.vertical, 4)
            }
        }
    }

    private func row(_ s: RenewStep, current: RenewStep, durations: [RenewStep: Double]) -> some View {
        let done = s < current
        let active = s == current
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Group {
                if done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(GpsTheme.mint)
                } else if active {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "circle").foregroundStyle(GpsTheme.sub)
                }
            }
            .frame(minWidth: 22)
            Text("\(s.rawValue) \(s.title)")
                .font(.subheadline.weight(active ? .semibold : .regular))
                .foregroundStyle(done || active ? Color.white : GpsTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            if done, let d = durations[s] {
                Text(String(format: "%.1f 秒", d))
                    .font(.footnote.monospacedDigit())
                    .foregroundStyle(GpsTheme.sub)
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("第 \(s.rawValue) 步，\(s.title)，" + (done ? "已完成" : (active ? "進行中" : "還沒開始")))
    }

    private var cancelButton: some View {
        let canCancel = renew.canCancel
        return Button {
            renew.cancel()
        } label: {
            Text(canCancel ? "取消續簽" : (renew.currentStep == .install ? "正在裝，請稍候" : "續簽中，請稍候"))
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(GpsOutlineButtonStyle())
        .disabled(!canCancel)
        .accessibilityIdentifier("renew.cancel")
    }
}

// MARK: - Failure (spec 1.8)

struct GpsRenewFailureView: View {
    let text: RenewFailureText
    let onAction: (RenewAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "exclamationmark.octagon.fill").foregroundStyle(GpsTheme.red)
                    .accessibilityHidden(true)
                Text(text.title)
                    .font(.headline)
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(text.detail)
                .font(.subheadline)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            if let code = text.codeLine {
                Text(code)
                    .font(.footnote)
                    .foregroundStyle(GpsTheme.sub)
                    .textSelection(.enabled)
            }
            Button(text.primary.title) { onAction(text.primary) }
                .buttonStyle(GpsFilledButtonStyle())
                .accessibilityIdentifier("renew.failure.primary")
            if let second = text.secondary {
                Button(second.title) { onAction(second) }
                    .buttonStyle(GpsOutlineButtonStyle())
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.vertical, 4)
        .accessibilityIdentifier("renew.failure")
    }
}

// MARK: - Settings: 「簽名」 section (spec 1.4)

/// The first section of settings. Shown only when the signature date can be read (not on CI
/// without a demo), like before.
/// The sign-in sheet and the 進階 page are presented by the settings Form itself: a Form is a
/// lazy list, which ignores `.sheet` / `.navigationDestination` placed on a row or section.
struct GpsSignSection: View {
    let onSignIn: () -> Void
    let onAdvanced: () -> Void
    @ObservedObject private var renew = GpsRenewCenter.shared

    var body: some View {
        Section {
            Group {
                TimelineView(.periodic(from: .now, by: 60)) { context in
                    if let expiry = GpsSigning.expiration {
                        summary(GpsSignState(expiry: expiry, now: context.date))
                    }
                }
                .id(renew.signTick)
            }
            // Scroll target for the home status line (see GpsSettingsTarget.renew).
            .id(GpsSettingsTarget.renew.anchorId ?? "")

            if renew.isRunning {
                GpsRenewProgressView()
            } else if let f = renew.failure {
                GpsRenewFailureView(text: renew.failureText(f)) { action in
                    renew.perform(action, openSignIn: onSignIn, openAdvanced: onAdvanced)
                }
            }
            if let expiry = GpsSigning.expiration {
                GpsRenewButton(state: GpsSignState(expiry: expiry, now: Date()), onSignIn: onSignIn)
                    .id(renew.signTick)
            }
            NavigationLink {
                GpsRenewAccountPage()
            } label: {
                Text("Apple 帳號與續簽").frame(minHeight: 44)
            }
            .accessibilityIdentifier("settings.renewAccount")
        } header: {
            Text("簽名")
        } footer: {
            Text("免費 Apple ID 簽的 App 每 7 天到期，到期後\(GpsRenewCopy.appName)會打不開。續簽只換新的 7 天簽名，地點不會不見。")
        }
    }

    private func summary(_ state: GpsSignState) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                state.indicator.font(.subheadline).accessibilityHidden(true)
                Text(renew.status.pendingInstall ? "新簽名已下載，還沒裝上" : state.headline(signedIn: renew.status.signedIn))
                    .font(.title2.weight(.bold))
                    .foregroundStyle(state.level == .expired ? GpsTheme.dangerText : Color.white)
                    .lineLimit(nil)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("到 \(GpsRenewCopy.dateTime(state.expiry))")
                .font(.subheadline)
                .foregroundStyle(GpsTheme.sub)
            if renew.status.pendingInstall {
                Text("只有 4G：關行動數據 → 開 LocalDevVPN → 按「裝上新簽名」，裝好再開回行動數據。")
                    .font(.subheadline)
                    .foregroundStyle(GpsTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let line = lastRenewLine(renew) {
                Text(line)
                    .font(.footnote)
                    .foregroundStyle(GpsTheme.sub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.signExpiry")
    }
}

/// 立即續簽 / 登入並續簽 / 續簽中… with the style the time left calls for.
/// While a renewal runs the button is disabled and shows a spinner; when it ends the line below says
/// 「成功，到 MM/dd HH:mm」 (failures show their own card with the reason).
struct GpsRenewButton: View {
    let state: GpsSignState
    let onSignIn: () -> Void
    @ObservedObject private var renew = GpsRenewCenter.shared

    private var title: String {
        if renew.isRunning { return "續簽中…" }
        // A downloaded signature waits: this button installs it (no Apple, no sign-in).
        if renew.status.pendingInstall { return "裝上新簽名" }
        return renew.status.signedIn ? "立即續簽" : "登入並續簽"
    }

    private var label: some View {
        HStack(spacing: 8) {
            if renew.isRunning { ProgressView().controlSize(.small) }
            Text(title)
        }
    }

    /// A success from the last 10 seconds, nothing running and no failure card showing.
    private func recentSuccess(now: Date) -> String? {
        guard !renew.isRunning, renew.failure == nil, let last = renew.lastRecord, last.succeeded,
              now.timeIntervalSince(last.at) < 10 else { return nil }
        // No read-back date: fall back to what the installed profile says.
        return (last.expiry ?? GpsSigning.expiration).map { "已續簽，簽名到 \(GpsRenewCopy.dateTime($0))" } ?? "已續簽"
    }

    var body: some View {
        let action: () -> Void = {
            if !renew.renewNow() { onSignIn() }
        }
        VStack(alignment: .leading, spacing: 6) {
            if state.prominentButton {
                Button(action: action) { label }
                    .buttonStyle(GpsFilledButtonStyle())
                    .disabled(renew.isRunning)
                    .accessibilityIdentifier("renew.now")
            } else {
                // Plenty of time left: a normal Form button (system blue on the dark row, 4.66:1).
                Button(action: action) {
                    // contentShape: a borderless button in a Form only hits its glyphs otherwise,
                    // so the empty part of the 44 pt row would not respond.
                    label.frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .foregroundStyle(renew.isRunning ? GpsTheme.sub : Color.blue)
                .disabled(renew.isRunning)
                .accessibilityIdentifier("renew.now")
            }
            // Two ticks only: now, and 10 s after the last success (when the line goes away). No endless timer.
            TimelineView(.explicit([Date(), renew.lastRecord.map { $0.at.addingTimeInterval(10) } ?? Date()].sorted())) { context in
                if let text = recentSuccess(now: context.date) {
                    Label(text, systemImage: "checkmark.circle.fill")
                        .font(.subheadline)
                        .foregroundStyle(GpsTheme.mint)
                        .accessibilityIdentifier("renew.result")
                }
            }
        }
    }
}

// MARK: - 「Apple 帳號與續簽」 page (spec 1.10)

struct GpsRenewAccountPage: View {
    @ObservedObject private var renew = GpsRenewCenter.shared
    @State private var showSignIn = false
    @State private var signInOrigin: GpsRenewSignInSheet.Origin = .settings
    @State private var confirmSignOut = false
    @State private var showAdvanced = false

    var body: some View {
        Form {
            Section {
                if renew.status.signedIn {
                    Text(renew.status.appleID.map(GpsRenewCopy.masked) ?? renew.status.maskedAppleID ?? "已登入")
                        .frame(minHeight: 44, alignment: .leading)
                    Text(renew.status.lastSuccess.map { "已登入・最後成功 \(GpsRenewCopy.dateTime($0))" } ?? "已登入")
                        .font(.subheadline)
                        .foregroundStyle(GpsTheme.sub)
                } else {
                    Text("尚未登入").foregroundStyle(GpsTheme.sub)
                    // The only primary button on this page; the 續簽 section below just explains.
                    Button("登入 Apple") {
                        signInOrigin = .settings
                        showSignIn = true
                    }
                    .buttonStyle(GpsFilledButtonStyle())
                    .accessibilityIdentifier("renew.signIn")
                }
            } header: {
                Text("Apple 帳號")
            }

            Section {
                if let expiry = GpsSigning.expiration {
                    let state = GpsSignState(expiry: expiry, now: Date())
                    Text(state.level == .expired ? "簽名已過期" : "\(state.remaining)（到 \(GpsRenewCopy.dateTime(expiry))）")
                        .frame(minHeight: 44, alignment: .leading)
                    if renew.status.signedIn || renew.status.pendingInstall {
                        GpsRenewButton(state: state, onSignIn: {
                            signInOrigin = .renewAfter
                            showSignIn = true
                        })
                    } else {
                        Text("登入後才能在手機上續簽。")
                            .font(.subheadline)
                            .foregroundStyle(GpsTheme.sub)
                    }
                }
                if renew.isRunning {
                    GpsRenewProgressView()
                } else if let f = renew.failure {
                    GpsRenewFailureView(text: renew.failureText(f)) { action in
                        renew.perform(action, openSignIn: {
                            signInOrigin = .renewAfter
                            showSignIn = true
                        }, openAdvanced: { showAdvanced = true })
                    }
                }
                Toggle("自動續簽", isOn: $renew.autoRenew)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("renew.auto")
            } header: {
                Text("續簽")
            } footer: {
                Text("打開\(GpsRenewCopy.appName)時，如果簽名剩不到 3 天，會自動續簽（每 6 小時最多試一次）。如果 Apple 暫時不讓登入，會等 6 小時再試，不影響你的帳號。")
            }
            .id(renew.signTick)

            Section {
                if renew.history.isEmpty {
                    Text("還沒有紀錄").foregroundStyle(GpsTheme.sub)
                }
                ForEach(renew.history) { r in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(GpsRenewCopy.dateTime(r.at)).monospacedDigit()
                        Text(r.succeeded ? "成功" : "沒成功")
                            .foregroundStyle(r.succeeded ? GpsTheme.mint : GpsTheme.sub)
                        Text(r.succeeded ? (r.expiry.map { "到 \(GpsRenewCopy.dateTime($0))" } ?? "") : (r.reason ?? ""))
                            .foregroundStyle(GpsTheme.sub)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.subheadline)
                    .accessibilityElement(children: .combine)
                }
            } header: {
                Text("續簽紀錄（最近 5 筆）")
            }

            Section {
                NavigationLink {
                    GpsRenewAdvancedPage()
                } label: {
                    Text("進階（一般不用改）").frame(minHeight: 44)
                }
                .accessibilityIdentifier("renew.advanced")
            }

            if renew.status.signedIn {
                Section {
                    Button {
                        confirmSignOut = true
                    } label: {
                        Text("登出 Apple 帳號")
                            .foregroundStyle(renew.isRunning ? GpsTheme.sub : GpsTheme.dangerText)
                            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                    }
                    .disabled(renew.isRunning)
                    .accessibilityIdentifier("renew.signOut")
                } footer: {
                    Text("登出後要重新輸入密碼和驗證碼。")
                }
                // A wide gap keeps 登出 away from everything else (it was a one-tap corner button in SideStore).
                .listSectionSpacing(48)
            }
        }
        .navigationTitle("Apple 帳號與續簽")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(isPresented: $showAdvanced) {
            GpsRenewAdvancedPage()
        }
        .sheet(isPresented: $showSignIn) {
            GpsRenewSignInSheet(origin: signInOrigin).preferredColorScheme(.dark)
        }
        // HIG Alerts: rare and hard to undo, so this one asks; neither button is the default.
        .alert("登出 Apple 帳號？", isPresented: $confirmSignOut) {
            Button("取消", role: .cancel) {}
            Button("登出", role: .destructive) {
                Task { await renew.signOut() }
            }
        } message: {
            Text(signOutMessage)
        }
        .task { await renew.refreshStatus() }
    }

    private var signOutMessage: String {
        var text = "登出後要重新輸入密碼和驗證碼。Apple 最近常擋這類登入，可能好幾天登不回來；登不回來的話，簽名到期後\(GpsRenewCopy.appName)就打不開。"
        if let expiry = GpsSigning.expiration {
            text += "現在的簽名不受影響，到 \(GpsRenewCopy.dateTime(expiry)) 前照常能用。"
        }
        return text
    }
}

// MARK: - 「進階（一般不用改）」 page (spec 1.11)

struct GpsRenewAdvancedPage: View {
    @ObservedObject private var renew = GpsRenewCenter.shared
    @State private var servers: [RenewAnisetteServer] = []
    @State private var selectedID: String?
    @State private var speeds: [String: Double?] = [:]
    @State private var measuring = false
    @State private var confirmReset = false
    @State private var showProfileImporter = false
    @State private var profileMessage: String?
    @State private var profileBusy = false

    var body: some View {
        Form {
            Section {
                Text("這裡的設定只在續簽一直失敗時才需要動。")
                    .font(.subheadline)
                    .foregroundStyle(GpsTheme.sub)
            }

            Section {
                ForEach(servers) { server in
                    Button {
                        Task {
                            await renew.service.selectAnisetteServer(id: server.id)
                            selectedID = server.id
                        }
                    } label: {
                        serverRow(server)
                    }
                    .buttonStyle(.plain)
                    .disabled(renew.isRunning)
                }
                Button(measuring ? "測試中…" : "測試速度") { measure() }
                    .disabled(measuring)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("renew.measure")
                Button("還原成預設伺服器") {
                    guard let def = servers.first(where: \.isDefault) else { return }
                    Task {
                        await renew.service.selectAnisetteServer(id: def.id)
                        selectedID = def.id
                    }
                }
                .disabled(renew.isRunning || servers.first(where: \.isDefault)?.id == selectedID)
                .frame(minHeight: 44)
            } header: {
                Text("驗證伺服器（anisette）")
            } footer: {
                Text("驗證伺服器只負責產生「這台像 Mac」的驗證資料，不會收到 Apple ID 或密碼。超過 16 秒沒回應，續簽幾乎都會失敗。")
            }

            Section {
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
                Button("清掉過期的舊描述檔（只清\(GpsRenewCopy.appName)自己的）") { runProfileCleanup() }
                    .disabled(profileBusy)
                    .frame(minHeight: 44)
                if let profileMessage {
                    Text(profileMessage).font(.footnote).foregroundStyle(.secondary)
                }
            } header: {
                Text("描述檔（給電腦做好的檔案用）")
            }

            Section {
                Button {
                    confirmReset = true
                } label: {
                    Text("重設驗證資料（adi.pb）")
                        .foregroundStyle(renew.isRunning ? GpsTheme.sub : GpsTheme.dangerText)
                        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
                }
                .disabled(renew.isRunning)
                .accessibilityIdentifier("renew.resetAuth")
            } header: {
                Text("驗證資料")
            } footer: {
                Text("只在 Apple 一直要求重新驗證時才用。重設後要重新登入一次。")
            }
        }
        .navigationTitle("進階（一般不用改）")
        .navigationBarTitleDisplayMode(.inline)
        .alert("重設驗證資料？", isPresented: $confirmReset) {
            Button("取消", role: .cancel) {}
            Button("重設", role: .destructive) {
                Task { await renew.resetAuthData() }
            }
        } message: {
            Text("重設後要重新登入 Apple（密碼＋驗證碼）。Apple 最近常擋登入，可能好幾天登不回來。")
        }
        .task {
            servers = await renew.service.anisetteServers()
            selectedID = await renew.service.selectedAnisetteServerID()
        }
    }

    private func serverRow(_ server: RenewAnisetteServer) -> some View {
        let selected = server.id == selectedID
        return HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                .foregroundStyle(selected ? GpsTheme.mint : GpsTheme.sub)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.isDefault ? "\(server.name)　預設" : server.name)
                    .foregroundStyle(.white)
                Text(server.host).font(.footnote).foregroundStyle(GpsTheme.sub)
                if let speed = speeds[server.id] {
                    speedText(speed).font(.footnote)
                }
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 44)
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    /// <5 s mint 快, 5-15 s yellow 慢, >15 s or no answer red text.
    private func speedText(_ seconds: Double?) -> Text {
        guard let s = seconds else { return Text("沒有回應，續簽會失敗").foregroundColor(GpsTheme.dangerText) }
        let value = String(format: "%.1f 秒", s)
        if s < 5 { return Text("\(value)　快").foregroundColor(GpsTheme.mint) }
        if s <= 15 { return Text("\(value)　慢").foregroundColor(GpsTheme.yellow) }
        return Text("\(value)　太慢，續簽會失敗").foregroundColor(GpsTheme.dangerText)
    }

    private func measure() {
        measuring = true
        Task {
            speeds = await renew.service.measureAnisette()
            measuring = false
        }
    }

    private func runProfileImport(_ result: Result<[URL], Error>) {
        profileBusy = true
        profileMessage = "處理中…"
        Task {
            defer { profileBusy = false }
            do {
                guard let url = try result.get().first else { return }
                let data = try GpsProfileRenew.readPicked(url)
                let outcome = try await GpsProfileRenew.install(data)
                profileMessage = outcome.message
                renew.bumpSign()
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
}

// MARK: - Sign-in sheet (spec 1.9)

struct GpsRenewSignInSheet: View {
    enum Origin {
        /// From 「登入並續簽」 or a failure: renew straight away when signed in.
        case renewAfter
        /// From settings 「登入」: ask whether to renew now.
        case settings
    }
    private enum Stage { case intro, credentials, code, done }

    let origin: Origin
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var renew = GpsRenewCenter.shared
    @State private var stage: Stage = .intro
    @State private var appleID = ""
    @State private var password = ""
    @State private var code = ""
    @State private var busyStep: RenewStep?
    @State private var busyStart = Date()
    @State private var failure: RenewFailure?
    @State private var askNotifications = false
    @State private var work: Task<Void, Never>?
    @FocusState private var focus: Field?
    private enum Field { case id, password, code }

    private var stepTitle: String {
        switch stage {
        case .intro: return "登入 Apple（1／3）"
        case .credentials: return "登入 Apple（2／3）"
        case .code: return "登入 Apple（3／3）"
        case .done: return "已登入"
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    switch stage {
                    case .intro: intro
                    case .credentials: credentials
                    case .code: codeEntry
                    case .done: done
                    }
                    if let failure {
                        GpsRenewFailureView(text: renew.failureText(failure)) { handle($0) }
                    }
                }
                .padding(20)
                .frame(maxWidth: 560, alignment: .leading)
                .frame(maxWidth: .infinity)
            }
            .background(GpsTheme.background.ignoresSafeArea())
            .navigationTitle(stepTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if stage == .code {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("取消") { dismiss() }
                            .disabled(busyStep != nil)
                            .accessibilityIdentifier("signIn.cancel")
                    }
                }
            }
        }
        .tint(GpsTheme.mint)
        .interactiveDismissDisabled(busyStep != nil)
        .dynamicTypeSize(...GpsSimHomeView.maxTypeSize)
        .task {
            if appleID.isEmpty, let saved = renew.status.appleID { appleID = saved }
        }
        .onDisappear {
            work?.cancel()
            if stage != .done { renew.signInSheetClosed() }
        }
    }

    // 1/3
    private var intro: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("為什麼要登入").font(.headline).foregroundStyle(.white)
            Text("免費 Apple ID 簽的 App 只能用 7 天。登入一次之後，\(GpsRenewCopy.appName)可以自己換新的 7 天簽名，不用接電腦。")
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 8) {
                bullet("Apple ID 和密碼只存在這支手機的鑰匙圈（Keychain），只送給 Apple。")
                bullet("用你裝\(GpsRenewCopy.appName)時用的同一個 Apple ID。")
            }
            Button("下一步") {
                stage = .credentials
                focus = appleID.isEmpty ? .id : .password
            }
            .buttonStyle(GpsFilledButtonStyle())
            .accessibilityIdentifier("signIn.next")
            Button("取消") { dismiss() }
                .buttonStyle(GpsOutlineButtonStyle())
                .frame(maxWidth: .infinity)
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("・").foregroundStyle(GpsTheme.sub)
            Text(text).foregroundStyle(.white).fixedSize(horizontal: false, vertical: true)
        }
        .font(.subheadline)
    }

    // 2/3
    private var credentials: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("需要網路（Wi-Fi 或行動網路都可以）。登入後 Apple 會傳 6 位數驗證碼給你。")
                .font(.subheadline)
                .foregroundStyle(GpsTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            Text("Apple ID").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            TextField("name@example.com", text: $appleID)
                .textContentType(.username)
                .keyboardType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($focus, equals: .id)
                .submitLabel(.next)
                .onSubmit { focus = .password }
                .fieldStyle()
                .accessibilityIdentifier("signIn.appleID")
            Text("要用裝\(GpsRenewCopy.appName)時用的那個 Apple ID；別人幫你裝的請問他。")
                .font(.footnote)
                .foregroundStyle(GpsTheme.sub)
                .fixedSize(horizontal: false, vertical: true)
            Text("密碼").font(.subheadline.weight(.semibold)).foregroundStyle(.white)
            SecureField("密碼", text: $password)
                .textContentType(.password)
                .focused($focus, equals: .password)
                .submitLabel(.go)
                .onSubmit(signIn)
                .fieldStyle()
                .accessibilityIdentifier("signIn.password")
            if let step = busyStep {
                busyRows(current: step)
            } else {
                Button("登入", action: signIn)
                    .buttonStyle(GpsFilledButtonStyle())
                    .disabled(appleID.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                    .accessibilityIdentifier("signIn.submit")
            }
            Button("上一步") {
                stage = .intro
                failure = nil
            }
            .buttonStyle(GpsOutlineButtonStyle())
            .frame(maxWidth: .infinity)
            .disabled(busyStep != nil)
            .accessibilityIdentifier("signIn.credBack")
        }
    }

    /// 「連到驗證伺服器 → 登入 Apple」 with a clock, same look as the renewal steps.
    private func busyRows(current: RenewStep) -> some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(alignment: .leading, spacing: 8) {
                Text("登入中　已 \(max(0, Int(context.date.timeIntervalSince(busyStart)))) 秒")
                    .font(.headline).foregroundStyle(.white)
                ForEach([RenewStep.anisette, RenewStep.signIn], id: \.self) { s in
                    HStack(spacing: 10) {
                        if s < current {
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(GpsTheme.mint)
                        } else if s == current {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "circle").foregroundStyle(GpsTheme.sub)
                        }
                        Text(s.title).foregroundStyle(s <= current ? Color.white : GpsTheme.sub)
                    }
                    .font(.subheadline)
                }
                if current == .anisette, context.date.timeIntervalSince(busyStart) > 10 {
                    Text("驗證伺服器比較慢，最多等 30 秒。").font(.footnote).foregroundStyle(GpsTheme.sub)
                }
            }
        }
    }

    // 3/3
    private var codeEntry: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("輸入驗證碼").font(.headline).foregroundStyle(.white)
            Text("Apple 會把 6 位數驗證碼送到：這支 iPhone 上方跳出的「Apple ID 登入」提示，按「允許」就看到號碼；或你的其他 Apple 裝置。")
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
            TextField("6 位數驗證碼", text: $code)
                .textContentType(.oneTimeCode)
                .keyboardType(.numberPad)
                .font(.title.monospacedDigit())
                .multilineTextAlignment(.center)
                .focused($focus, equals: .code)
                .fieldStyle()
                .disabled(busyStep != nil)
                .onChange(of: code) { _, value in
                    let digits = String(value.filter(\.isNumber).prefix(6))
                    if digits != value { code = digits }
                    if digits.count == 6 { submitCode(digits) }
                }
                .accessibilityIdentifier("signIn.code")
            // Typing the 6th digit sends by itself; this button is for anyone who prefers to tap.
            Button {
                submitCode(code)
            } label: {
                HStack(spacing: 8) {
                    if busyStep != nil { ProgressView().controlSize(.small) }
                    Text(busyStep != nil ? "確認中…" : "送出驗證碼")
                }
            }
            .buttonStyle(GpsFilledButtonStyle())
            .disabled(code.count != 6 || busyStep != nil)
            .accessibilityIdentifier("signIn.sendCode")
            // No 「重新傳送驗證碼」 / 「改用簡訊」 links: the renew engine can do neither, and the
            // screenshot demo must look like the real thing (designer + main, round 1).
            Button("上一步") {
                renew.signInSheetClosed()
                failure = nil
                code = ""
                password = ""
                stage = .credentials
                focus = .password
            }
            .buttonStyle(GpsOutlineButtonStyle())
            .frame(maxWidth: .infinity)
            .disabled(busyStep != nil)
            .accessibilityIdentifier("signIn.back")
        }
        .onAppear { focus = .code }
    }

    private var done: some View {
        VStack(alignment: .leading, spacing: 14) {
            if askNotifications {
                // An ordinary card with no primary button: the page's one primary is 立即續簽 / 完成 below.
                VStack(alignment: .leading, spacing: 10) {
                    Text("簽名快到期時通知我（不會傳任何資料出去）")
                        .foregroundStyle(.white)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("開啟通知") {
                        Task {
                            _ = await GpsRenewReminders.requestPermission()
                            GpsRenewReminders.reschedule(expiry: GpsSigning.expiration)
                            askNotifications = false
                        }
                    }
                    .buttonStyle(GpsOutlineButtonStyle())
                    .frame(maxWidth: .infinity)
                    Button {
                        askNotifications = false
                    } label: {
                        Text("不用")
                            .font(.subheadline)
                            .foregroundStyle(GpsTheme.mint)
                            .frame(maxWidth: .infinity, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.borderless)
                }
                .padding(14)
                .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
            switch origin {
            case .renewAfter:
                Text(renew.isRunning ? "已登入。正在續簽…" : "已登入。")
                    .foregroundStyle(.white)
                    .fixedSize(horizontal: false, vertical: true)
                // A renewal that fails right after sign-in is explained here, on the finished page,
                // not left behind the sheet where only 「3／3」 would be seen.
                if let f = renew.failure {
                    GpsRenewFailureView(text: renew.failureText(f)) { action in
                        renew.perform(action, openSignIn: {
                            password = ""
                            code = ""
                            stage = .credentials
                        }, openAdvanced: { dismiss() })
                    }
                }
                Button("完成") { dismiss() }
                    .buttonStyle(GpsFilledButtonStyle())
            case .settings:
                Text("已登入。")
                    .foregroundStyle(.white)
                Button("立即續簽") {
                    renew.renewNow()
                    dismiss()
                }
                .buttonStyle(GpsFilledButtonStyle())
                .accessibilityIdentifier("signIn.renewNow")
                Button("稍後") { dismiss() }
                    .buttonStyle(GpsOutlineButtonStyle())
                    .frame(maxWidth: .infinity)
            }
        }
    }

    // MARK: Actions

    private func signIn() {
        let id = appleID.trimmingCharacters(in: .whitespaces)
        guard !id.isEmpty, !password.isEmpty, busyStep == nil else { return }
        failure = nil
        focus = nil
        busyStart = Date()
        busyStep = .anisette
        work = Task {
            do {
                let result = try await renew.service.signIn(appleID: id, password: password) { step in
                    Task { @MainActor in busyStep = step }
                }
                busyStep = nil
                password = ""
                switch result {
                case .needsCode: stage = .code
                case .signedIn: await finishSignIn()
                }
            } catch is CancellationError {
                busyStep = nil
            } catch {
                busyStep = nil
                failure = (error as? RenewFailure) ?? .other(code: String((error as NSError).code))
            }
        }
    }

    private func submitCode(_ digits: String) {
        guard busyStep == nil else { return }
        failure = nil
        busyStep = .signIn
        work = Task {
            do {
                try await renew.service.submit2FA(code: digits)
                // Stay busy (button disabled, field locked) until the next stage is showing, so a tap
                // in between cannot send the same code twice.
                await finishSignIn()
                busyStep = nil
                code = ""
            } catch is CancellationError {
                busyStep = nil
            } catch {
                busyStep = nil
                code = ""
                failure = (error as? RenewFailure) ?? .other(code: String((error as NSError).code))
                // The sign-in is over (nothing was saved): a code can no longer be entered, so leave 3/3.
                if failure == .keychain {
                    password = ""
                    stage = .credentials
                }
            }
        }
    }

    private func finishSignIn() async {
        await renew.signInFinished()
        askNotifications = await GpsRenewReminders.permissionUndetermined()
        stage = .done
        AccessibilityAnnouncer.announce("已登入")
        if origin == .renewAfter { renew.renewNow() }
    }

    private func handle(_ action: RenewAction) {
        switch action {
        case .retry:
            failure = nil
            if stage == .code { focus = .code } else { signIn() }
        case .signInAgain, .signInAndRenew:
            failure = nil
            password = ""
            code = ""
            stage = .credentials
            focus = .password
        case .reenterCode:
            failure = nil
            code = ""
            if renew.signInFlowOpen {
                focus = .code
            } else {
                // The sign-in was cancelled meanwhile: a code can no longer be accepted, start over.
                password = ""
                stage = .credentials
                focus = .password
            }
        default:
            failure = nil
        }
    }
}

private extension View {
    /// Input box on the dark sheet: card fill with a visible grey outline (idleBorder 3:1+).
    func fieldStyle() -> some View {
        self
            .padding(.horizontal, 14)
            .frame(minHeight: 48)
            .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).stroke(GpsTheme.idleBorder, lineWidth: 1))
            .foregroundStyle(.white)
    }
}

/// Picks the cancel look (outline) or the mint capsule for the banner's main button.
private struct AnyButtonStyle: PrimitiveButtonStyle {
    let outline: Bool
    let fullWidth: Bool

    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if outline {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(GpsOutlineButtonStyle())
        } else {
            Button(role: configuration.role, action: configuration.trigger) { configuration.label }
                .buttonStyle(GpsSmallFilledButtonStyle(fullWidth: fullWidth))
        }
    }
}

/// Mint capsule sized for the home card (44 pt tall).
private struct GpsSmallFilledButtonStyle: ButtonStyle {
    var fullWidth = false

    func makeBody(configuration: Configuration) -> some View {
        GpsSmallFilledBody(configuration: configuration, fullWidth: fullWidth)
    }
}

private struct GpsSmallFilledBody: View {
    let configuration: ButtonStyleConfiguration
    let fullWidth: Bool
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        configuration.label
            .font(.subheadline.weight(.bold))
            .foregroundStyle(isEnabled ? GpsTheme.onAccent : GpsTheme.sub)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 16)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: 44)
            .background((isEnabled ? GpsTheme.mint : GpsTheme.card).opacity(configuration.isPressed ? 0.8 : 1), in: Capsule())
            .overlay(Capsule().stroke(GpsTheme.idleBorder, lineWidth: isEnabled ? 0 : 1))
            .contentShape(Capsule())
    }
}
