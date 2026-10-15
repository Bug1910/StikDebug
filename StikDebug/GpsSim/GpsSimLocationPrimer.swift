//
//  GpsSimLocationPrimer.swift
//  StikDebug
//
//  The one line shown before iOS asks for location the first time (status .notDetermined).
//  Drawn in the app's own bottom-card style, never like the centred system alert, so it
//  can't be mistaken for the real request.
//
//  Apple HIG "Privacy > Pre-alert screens": only one button, titled like 「繼續」 (never
//  "Allow"), and no way to close it without seeing the system alert. The choice itself
//  (允許 / 不允許) stays in the system alert; the app works either way.
//

import SwiftUI
import UIKit

enum GpsLocationPrimer {
    static let text = "為了在鎖螢幕或切到別的 App 時讓定位模擬不中斷，下一步系統會詢問定位權限。"

    /// Shows the card; `completion(true)` runs after 繼續 closes it. With no window to show it
    /// on, `completion(false)` runs at once so the caller is never left waiting.
    static func present(completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            // No window, or a sheet still opening/closing (UIKit then refuses a new
            // presentation silently): skip, and the next simulation start asks again.
            guard let top = topViewController(), !top.isBeingDismissed, !top.isBeingPresented else {
                completion(false)
                return
            }
            // Weak, so the card's own closure does not keep the controller alive.
            weak var host: UIViewController?
            let view = GpsLocationPrimerView {
                host?.dismiss(animated: true) { completion(true) }
            }
            let controller = UIHostingController(rootView: view)
            controller.view.backgroundColor = .clear
            controller.modalPresentationStyle = .overFullScreen
            controller.modalTransitionStyle = .crossDissolve
            controller.isModalInPresentation = true
            host = controller
            top.present(controller, animated: true)
            if controller.presentingViewController == nil { completion(false) }
        }
    }

    private static func topViewController() -> UIViewController? {
        var top = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController
        while let presented = top?.presentedViewController { top = presented }
        return top
    }
}

struct GpsLocationPrimerView: View {
    let onContinue: () -> Void
    /// A quick double tap must not ask twice.
    @State private var tapped = false

    var body: some View {
        ZStack(alignment: .bottom) {
            // Dims the map; tapping it does nothing (the HIG asks for no way out but 繼續).
            Color.black.opacity(0.55)
                .ignoresSafeArea()
                .accessibilityHidden(true)
            card
                .frame(maxWidth: 520)
                .padding(.horizontal, 12)
                .padding(.bottom, 12)
        }
        .preferredColorScheme(.dark)
    }

    private var message: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: "location.fill")
                .font(.body.weight(.semibold))
                .foregroundStyle(GpsTheme.mint)
                .accessibilityHidden(true)
            Text(GpsLocationPrimer.text)
                .font(.body)
                .foregroundStyle(.white)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .accessibilityIdentifier("primer.text")
        }
    }

    private var card: some View {
        VStack(alignment: .leading, spacing: 16) {
            // At the largest accessibility sizes the line can outgrow an iPhone SE; then it
            // scrolls while the button stays pinned and reachable.
            ViewThatFits(in: .vertical) {
                message
                ScrollView { message }
                    .scrollBounceBehavior(.basedOnSize)
            }

            Button {
                guard !tapped else { return }
                tapped = true
                onContinue()
            } label: {
                Text("繼續")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(GpsTheme.background)
                    .frame(maxWidth: .infinity, minHeight: 50)
                    .background(GpsTheme.mint, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .contentShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .accessibilityHint("打開系統的定位權限詢問")
            .accessibilityIdentifier("btn.primerContinue")
        }
        .padding(18)
        .background(GpsTheme.card, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(GpsTheme.line, lineWidth: 1))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("primer")
    }
}
