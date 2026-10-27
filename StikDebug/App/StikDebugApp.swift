//
//  StikDebugApp.swift
//  StikDebug
//
//  Created by Stephen on 3/26/25.
//

import SwiftUI

@main
struct StikDebugApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @State private var shouldAttemptTunnelReconnect = false

    init() {
        AppBootstrapper.configure()
        // PinFly: background download of the new 7-day profile (must be registered during launch;
        // skipped when this process was launched in the background, see registerAtLaunch).
        if !GpsRenewCenter.isDemo { RenewBackgroundDownload.registerAtLaunch() }
    }

    var body: some Scene {
        WindowGroup {
            MainTabView()
                .task {
                    await downloadMissingDeveloperDiskImageFiles()
                }
                .onChange(of: scenePhase) { _, newPhase in
                    handleScenePhaseChange(newPhase)
                }
        }
    }

    private func handleScenePhaseChange(_ newPhase: ScenePhase) {
        switch newPhase {
        case .background:
            shouldAttemptTunnelReconnect = true
        case .active:
            // Keeps one background-download request planned (no-op if this process did not register).
            if !GpsRenewCenter.isDemo { RenewBackgroundDownload.appBecameActive() }
            if shouldAttemptTunnelReconnect {
                shouldAttemptTunnelReconnect = false
                startTunnelInBackground(showErrorUI: false)
            }
        default:
            break
        }
    }

    private func downloadMissingDeveloperDiskImageFiles() async {
        do {
            try await DeveloperDiskImageService.shared.downloadMissingFiles()
            MountingProgress.shared.pubMount()
        } catch {
            await MainActor.run {
                showAlert(
                    title: "An Error has Occurred",
                    message: "[Download DDI Error]: \(error.localizedDescription)",
                    showOk: true
                )
            }
        }
    }
}
