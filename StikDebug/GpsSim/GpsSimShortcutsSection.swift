//
//  GpsSimShortcutsSection.swift
//  StikDebug (GpsSim fork) - experimental renew copy
//
//  Settings 「捷徑」 section (spec 2.5), ready to drop into the settings Form under 「連不上？」:
//      GpsSimShortcutsSection()
//  Wired into GpsSimSettingsView right under 「連不上？」.
//  Apple offers no API for an app to create a personal automation, so 「每天自動續簽」 is a step list.
//

import AppIntents
import SwiftUI

struct GpsSimShortcutsSection: View {
    var body: some View {
        Section {
            // Apple's own button: opens the Shortcuts app on this app's page of actions.
            ShortcutsLink()
                .shortcutsLinkStyle(.automatic)
                .frame(maxWidth: .infinity, alignment: .leading)
            NavigationLink {
                GpsSimDailyRenewGuideView()
            } label: {
                Text("每天自動續簽（要自己建一次）")
            }
        } header: {
            Text("捷徑")
        } footer: {
            Text("Apple 不允許 App 自己建立自動化，要在「捷徑」App 照步驟建一次。")
        }
    }
}

struct GpsSimDailyRenewGuideView: View {
    @Environment(\.openURL) private var openURL

    private let steps: [String] = [
        "打開「捷徑」→ 下方「自動化」→ 右上「＋」",
        "選「鬧鐘」→「被停止時」→ 選你平日早上的鬧鐘 →「立即執行」",
        "加動作「LocalDevVPN：Enable」",
        "加動作「PinFly：續簽PinFly」（只在剩 3 天內才續簽）",
        "加動作「如果」：結果 是 失敗",
        "在「如果」裡加「顯示通知」：內容選「原因」",
    ]

    var body: some View {
        Form {
            Section {
                ForEach(Array(steps.enumerated()), id: \.offset) { index, step in
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        Text("\(index + 1)")
                            .font(.body.monospacedDigit().weight(.semibold))
                            .foregroundStyle(.secondary)
                            .accessibilityHidden(true)
                        Text(step)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("第 \(index + 1) 步，\(step)")
                }
            } header: {
                Text("在「捷徑」App 建一個自動化（約 2 分鐘）")
            } footer: {
                Text("鬧鐘觸發最穩（10/22 實測）。手機鎖著時 iOS 可能不讓動作跑完，失敗時會收到通知，打開PinFly按「立即續簽」即可。")
            }
            Section {
                Button("打開「捷徑」App") {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                }
            }
        }
        .navigationTitle("每天自動續簽")
        .navigationBarTitleDisplayMode(.inline)
    }
}
