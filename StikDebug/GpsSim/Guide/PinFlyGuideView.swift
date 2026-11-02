//
//  PinFlyGuideView.swift
//  StikDebug (GpsSim fork)
//
//  「使用教學」: an offline help area reachable from Settings (Apple HIG Onboarding: "make the
//  tutorial available in a help, account, or settings area"). A plain chapter list, each chapter a
//  page of short numbered one-action steps with an optional screenshot per step.
//  Pushed inside the Settings NavigationStack, so it needs no presenter of its own; the hook in
//  GpsSimSettingsView is one NavigationLink row.
//

import SwiftUI
import UIKit

// MARK: - Chapter list

struct PinFlyGuideListView: View {
    /// Settings passes its own dismiss-then-show so 「開啟使用引導」 behaves like the 使用引導 row.
    var openOnboarding: () -> Void = {}

    var body: some View {
        Form {
            Section {
                ForEach(Array(PinFlyGuideContent.chapters.enumerated()), id: \.element.id) { index, chapter in
                    NavigationLink {
                        PinFlyGuideChapterView(chapter: chapter, number: index + 1, openOnboarding: openOnboarding)
                    } label: {
                        HStack(spacing: 14) {
                            Image(systemName: chapter.symbol)
                                .font(.body.weight(.semibold))
                                .foregroundStyle(GpsTheme.mint)
                                .frame(width: 28)
                                .accessibilityHidden(true)
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(index + 1). \(chapter.title)")
                                    .font(.body.weight(.semibold))
                                Text(chapter.summary)
                                    .font(.footnote)
                                    .foregroundStyle(GpsTheme.sub)
                            }
                            .fixedSize(horizontal: false, vertical: true)
                        }
                        .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("guide.chapter.\(chapter.id)")
                }
            } footer: {
                Text("內容存於 App 內，無網路時亦可閱讀。")
            }
        }
        .navigationTitle("使用教學")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - One chapter

struct PinFlyGuideChapterView: View {
    let chapter: PinFlyGuideChapter
    let number: Int
    var openOnboarding: () -> Void = {}

    @Environment(\.openURL) private var openURL
    @State private var enlarged: PinFlyGuideImage?

    var body: some View {
        Form {
            Section {
                Text(chapter.lead)
                    .font(.body.weight(.semibold))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("guide.lead")
            }
            ForEach(Array(chapter.sections.enumerated()), id: \.offset) { sectionIndex, section in
                Section {
                    ForEach(Array(section.steps.enumerated()), id: \.offset) { stepIndex, step in
                        stepRow(step, number: stepIndex + 1,
                                id: "guide.step.\(chapter.id).\(sectionIndex + 1).\(stepIndex + 1)")
                    }
                } header: {
                    Text(section.title)
                } footer: {
                    if let note = section.note {
                        Text(note)
                    }
                }
            }
            if !chapter.actions.isEmpty {
                Section {
                    ForEach(chapter.actions, id: \.self) { action in
                        actionRow(action)
                    }
                }
            }
        }
        .navigationTitle(chapter.title)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $enlarged) { image in
            PinFlyGuideImageViewer(image: image)
                .preferredColorScheme(.dark)
        }
    }

    private func stepRow(_ step: PinFlyGuideStep, number: Int, id: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                Text("\(number)")
                    .font(.body.monospacedDigit().weight(.bold))
                    .foregroundStyle(GpsTheme.mint)
                    .accessibilityHidden(true)
                Text(step.text)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("第 \(number) 步，\(step.text)")
            .accessibilityIdentifier(id)
            if let image = step.image, let ui = UIImage(named: image.name) {
                PinFlyGuideThumbnail(image: image, uiImage: ui) { enlarged = image }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func actionRow(_ action: PinFlyGuideAction) -> some View {
        switch action {
        case .dailyRenewGuide:
            NavigationLink {
                GpsSimDailyRenewGuideView()
            } label: {
                Text(action.title).frame(minHeight: 44)
            }
            .accessibilityIdentifier(action.identifier)
        case .renewAccount:
            NavigationLink {
                GpsRenewAccountPage()
            } label: {
                Text(action.title).frame(minHeight: 44)
            }
            .accessibilityIdentifier(action.identifier)
        case .pcInstallGuide:
            NavigationLink {
                PinFlyGuideChapterView(chapter: PinFlyGuideContent.pcInstall,
                                       number: (PinFlyGuideContent.chapters.firstIndex(of: PinFlyGuideContent.pcInstall) ?? 1) + 1,
                                       openOnboarding: openOnboarding)
            } label: {
                Text(action.title).frame(minHeight: 44)
            }
            .accessibilityIdentifier(action.identifier)
        default:
            Button(action.title) { perform(action) }
                .frame(minHeight: 44)
                .accessibilityIdentifier(action.identifier)
        }
    }

    private func perform(_ action: PinFlyGuideAction) {
        switch action {
        case .systemSettings:
            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
        case .shortcutsApp:
            if let url = URL(string: "shortcuts://") { openURL(url) }
        case .localDevVPNStore:
            if let url = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044") { openURL(url) }
        case .onboarding:
            openOnboarding()
        case .dailyRenewGuide, .renewAccount, .pcInstallGuide:
            break   // NavigationLink rows, handled in actionRow
        }
    }
}

extension PinFlyGuideImage: Identifiable {
    var id: String { name }
}

// MARK: - Screenshot thumbnail and full-screen viewer

/// Shared drawing: the screenshot at its fitted size, the optional tap-target frame on top
/// (positioned in the image's own coordinate space, so it stays on target at any size), a hairline border.
struct PinFlyGuideShot: View {
    let image: PinFlyGuideImage
    let uiImage: UIImage

    var body: some View {
        Image(uiImage: uiImage)
            .resizable()
            .scaledToFit()
            .overlay {
                if let r = image.highlight {
                    GeometryReader { geo in
                        RoundedRectangle(cornerRadius: 8, style: .continuous)
                            .stroke(GpsTheme.yellow, lineWidth: 3)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous)
                                .fill(GpsTheme.yellow.opacity(0.12)))
                            .frame(width: geo.size.width * r.w + 8, height: geo.size.height * r.h + 8)
                            .position(x: geo.size.width * (r.x + r.w / 2), y: geo.size.height * (r.y + r.h / 2))
                    }
                    .accessibilityHidden(true)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(GpsTheme.idleBorder, lineWidth: 1))
    }
}

/// Phone screenshots are tall: cap the height so one step never fills the screen, keep the aspect.
/// Only shown when the asset exists (images are added after CI / real-phone capture).
struct PinFlyGuideThumbnail: View {
    let image: PinFlyGuideImage
    let uiImage: UIImage
    let onTap: () -> Void
    @ScaledMetric(relativeTo: .body) private var maxHeight: CGFloat = 420

    var body: some View {
        Button(action: onTap) {
            PinFlyGuideShot(image: image, uiImage: uiImage)
                .frame(maxWidth: .infinity, maxHeight: min(maxHeight, 560))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("截圖：\(image.caption)")
        .accessibilityHint("點兩下放大")
        .accessibilityIdentifier("guide.image.\(image.name)")
    }
}

struct PinFlyGuideImageViewer: View {
    let image: PinFlyGuideImage
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 12) {
                    if let ui = UIImage(named: image.name) {
                        PinFlyGuideShot(image: image, uiImage: ui)
                            .frame(maxWidth: .infinity)
                            .accessibilityElement(children: .ignore)
                            .accessibilityLabel("截圖：\(image.caption)")
                    }
                    Text(image.caption)
                        .font(.footnote)
                        .foregroundStyle(GpsTheme.sub)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(16)
            }
            .background(GpsTheme.background.ignoresSafeArea())
            .navigationTitle("截圖")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("關閉") { dismiss() }
                        .accessibilityIdentifier("guide.image.close")
                }
            }
        }
    }
}
