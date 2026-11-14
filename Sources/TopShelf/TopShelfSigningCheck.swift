#if NUVIO_UPSTREAM_PLAYER
import Foundation

enum TopShelfSigningCheck: Equatable {
    case extensionMissing
    case appGroupUnavailable(expectedGroup: String, profileGroups: [String]?)
    case extensionProfileMismatch(group: String)

    static let installedIssue: Self? = {
        let appURL = Bundle.main.bundleURL
        let plugInsURL = appURL.appendingPathComponent("PlugIns", isDirectory: true)
        let plugIns = (try? FileManager.default.contentsOfDirectory(
            at: plugInsURL,
            includingPropertiesForKeys: nil
        )) ?? []
        let extensionURL = plugIns.first { url in
            guard url.pathExtension == "appex",
                  let extensionInfo = Bundle(url: url)?.infoDictionary?["NSExtension"] as? [String: Any] else {
                return false
            }
            return extensionInfo["NSExtensionPointIdentifier"] as? String == "com.apple.tv-top-shelf"
        }

        return diagnose(
            group: topShelfAppGroupID,
            appHasContainer: TopShelfFeedStore.isAvailable,
            appProfileGroups: topShelfProvisioningProfileGroupIdentifiers(at: appURL),
            hasExtension: extensionURL != nil,
            extensionProfileGroups: extensionURL.flatMap { topShelfProvisioningProfileGroupIdentifiers(at: $0) }
        )
    }()

    static func diagnose(
        group: String,
        appHasContainer: Bool,
        appProfileGroups: [String]?,
        hasExtension: Bool,
        extensionProfileGroups: [String]?
    ) -> Self? {
        guard hasExtension else { return .extensionMissing }
        guard appHasContainer else {
            return .appGroupUnavailable(expectedGroup: group, profileGroups: appProfileGroups)
        }
        if let extensionProfileGroups, !extensionProfileGroups.contains(group) {
            return .extensionProfileMismatch(group: group)
        }
        return nil
    }

    var message: String {
        switch self {
        case .extensionMissing:
            return String(localized: "This install is missing the Top Shelf extension. Reinstall with app extensions enabled.")
        case .appGroupUnavailable(_, let profileGroups?) where !profileGroups.isEmpty:
            let groups = profileGroups.formatted(.list(type: .and))
            return String(localized: "The app cannot open an App Group. Its provisioning profile allows \(groups). Sign the app and extension with the same App Group entitlement.")
        case .appGroupUnavailable(let expectedGroup, _):
            return String(localized: "The app cannot open the \(expectedGroup) App Group. Sign the app and extension with profiles and entitlements that include the same App Group.")
        case .extensionProfileMismatch(let group):
            return String(localized: "The Top Shelf extension’s provisioning profile is missing \(group). Sign the extension with a profile that includes that App Group.")
        }
    }
}
#endif
