//
//  GpsSimPadView.swift
//  StikDebug (GpsSim fork)
//
//  Root wrapper (iPhone and iPad) plus the iPad sheet sizing helper.
//

import SwiftUI

/// One GpsSimHomeView at a fixed spot in the tree. Since the map-first redesign (2026-10-15)
/// the map fills the whole iPad screen and the home view caps its own floating controls at 520 pt,
/// so this wrapper no longer narrows anything. The engine and store are singletons (`.shared`).
struct GpsSimRootView: View {
    var body: some View {
        GpsSimHomeView()
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
