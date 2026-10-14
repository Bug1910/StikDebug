//
//  GpsSimPadView.swift
//  StikDebug (GpsSim fork)
//
//  The iPad wrapper around the phone screen. On a regular-width screen the phone layout used to
//  stretch to ~1000 pt (pencils at the far edge, a giant card button). This keeps the same screen
//  but holds it in a centred column so every control stays within thumb/eye reach. Real split view
//  (sidebar + full-height map) needs access changes inside GpsSimHomeView; see the hand-off notes.
//

import SwiftUI

/// iPad: constrain the phone UI to a readable column. Phone (compact): untouched.
struct GpsSimRootView: View {
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        if sizeClass == .regular {
            GpsSimPadView()
        } else {
            GpsSimHomeView()
        }
    }
}

struct GpsSimPadView: View {
    /// 560 keeps the candidate card under its 480 pt cap plus margins and the list readable.
    private static let columnWidth: CGFloat = 560

    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            GpsSimHomeView()
                .frame(maxWidth: Self.columnWidth)
                .frame(maxWidth: .infinity)
        }
    }
}

extension View {
    /// Sheets on iPad must not be clipped at ~690 pt; on iPhone this changes nothing.
    @ViewBuilder
    func gpsSimPadSheetSizing() -> some View {
        if #available(iOS 18.0, *) {
            self.presentationSizing(.form).presentationDetents([.large])
        } else {
            self.presentationDetents([.large])
        }
    }
}
