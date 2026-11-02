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
    @Environment(\.openURL) private var openURL

    var body: some View {
        Section {
            // Own button instead of Apple's ShortcutsLink: that one prints the system's name for the app,
            // which came out as the upstream executable name ("StikDebug shortcuts").
            Button {
                if let url = URL(string: "shortcuts://") { openURL(url) }
            } label: {
                Label("PinFly 捷徑", systemImage: "square.2.layers.3d")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            }
            .accessibilityIdentifier("settings.shortcutsLink")
            NavigationLink {
                GpsSimDailyRenewGuideView()
            } label: {
                Text("每天自動續簽")
            }
        } header: {
            Text("捷徑")
        } footer: {
            Text("Apple 不允許 App 自行建立自動化，需在「捷徑」App 依步驟建立一次。")
        }
    }
}

struct GpsSimDailyRenewGuideView: View {
    @Environment(\.openURL) private var openURL

    private let steps: [String] = [
        "開啟「捷徑」App → 點選下方「自動化」→ 點選右上角「＋」",
        "點選「鬧鐘」→「被停止時」→ 選擇平日早上的鬧鐘 →「立即執行」",
        "加入動作「LocalDevVPN：Enable」",
        "加入動作「PinFly：到期前續簽 PinFly」，天數設為 3",
        "加入動作「如果」：結果 是 失敗",
        "在「如果」中加入「顯示通知」，內容選擇「原因」",
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
                Text("在「捷徑」App 建立自動化（約 2 分鐘）")
            } footer: {
                Text("建議以鬧鐘觸發。手機鎖定時可能執行失敗，屆時會收到通知，請開啟 PinFly 並點選「立即續簽」。")
            }
            Section {
                Button("開啟「捷徑」App") {
                    if let url = URL(string: "shortcuts://") { openURL(url) }
                }
            }
        }
        .navigationTitle("每天自動續簽")
        .navigationBarTitleDisplayMode(.inline)
    }
}
