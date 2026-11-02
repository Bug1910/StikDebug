//
//  AppIdentity.swift
//  StikDebug (PinFly fork)
//
//  The app's own identifiers, read at run time instead of being written into the code.
//  The bundle id is a build setting (PINFLY_BUNDLE_ID): the public build is com.pinfly.app and the
//  author's own phone build keeps com.stik.stikdebug. Info.plist and the entitlements expand
//  $(PRODUCT_BUNDLE_IDENTIFIER) at build time, so reading Info.plist here always matches what was built,
//  even when a sideloading tool later adds a team suffix to Bundle.main.bundleIdentifier.
//

import Foundation

enum AppIdentity {
    /// Bundle id as built (no team suffix), from Info.plist key PinFlyBaseBundleID.
    static let baseBundleID: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "PinFlyBaseBundleID") as? String,
           !value.isEmpty, !value.hasPrefix("$(") {
            return value
        }
        return Bundle.main.bundleIdentifier ?? "com.pinfly.app"
    }()

    /// App Group: same string as StikDebug.entitlements (group.$(PRODUCT_BUNDLE_IDENTIFIER)).
    static let appGroup: String = {
        if let value = Bundle.main.object(forInfoDictionaryKey: "PinFlyAppGroup") as? String,
           !value.isEmpty, !value.hasPrefix("$(") {
            return value
        }
        return "group." + baseBundleID
    }()

    /// First URL scheme in Info.plist (public build: pinfly; author's build: stikdebug).
    static let urlScheme: String = {
        let types = Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]]
        let schemes = types?.first?["CFBundleURLSchemes"] as? [String]
        return schemes?.first(where: { !$0.isEmpty && !$0.hasPrefix("$(") }) ?? "pinfly"
    }()

    /// A permitted BGTaskScheduler id ending with `suffix`, read from Info.plist so the two always match
    /// (registering an id that is not listed there raises an exception).
    static func backgroundTaskID(endingWith suffix: String) -> String {
        let listed = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]
        return listed?.first(where: { $0.hasSuffix(suffix) }) ?? baseBundleID + suffix
    }

    /// Prefix for DispatchQueue labels (labels are only for debugging).
    static func queueLabel(_ name: String) -> String {
        baseBundleID + "." + name
    }
}
