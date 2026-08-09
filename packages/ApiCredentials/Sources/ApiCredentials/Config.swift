import Cocoa

public final class ApiEnvironment {
    public static var apiId:Int32 {
        return 9
    }
    public static var apiHash:String {
        return "3975f648bb682ee889f35483bc618d1c"
    }
    
    public static var bundleId: String {
        return "dev.kiteapp.Kite"
    }
    /// The bundle id this app shipped under before it was renamed to Kite. Kept so an
    /// existing install can move its accounts and caches into the new group container
    /// instead of coming up logged out.
    public static var legacyBundleId: String {
        return "dev.telegramwork.Telegram"
    }
    public static var intentsBundleId: String {
        return teamId + "." + bundleId + ".FocusIntents"
    }
    public static var teamId: String {
        return "6N38VWS5BX"
    }
    
    
    
    public static var containerURL: URL? {
        let appGroupName = ApiEnvironment.group
        let containerUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)?.appendingPathComponent(prefix)
        if let containerUrl = containerUrl {
            try? FileManager.default.createDirectory(at: containerUrl, withIntermediateDirectories: true, attributes: nil)
            return containerUrl
        }
        return nil
    }
    
    /// Moves an existing install's accounts and caches out of the pre-rename group container.
    /// The group id is derived from the bundle id, so renaming the app would otherwise point it
    /// at an empty container and log everyone out. Runs before `migrate()` and does nothing once
    /// the new container holds anything, so it only ever takes effect on the first launch after
    /// the rename.
    public static func migrateFromLegacyBundleId() {
        let manager = FileManager.default
        guard !UserDefaults.standard.bool(forKey: legacyMigrationKey) else {
            return
        }
        guard let legacyRoot = manager.containerURL(forSecurityApplicationGroupIdentifier: teamId + "." + legacyBundleId),
              let currentRoot = manager.containerURL(forSecurityApplicationGroupIdentifier: group),
              legacyRoot != currentRoot else {
            return
        }
        let legacyContents = (try? manager.contentsOfDirectory(atPath: legacyRoot.path)) ?? []
        guard !legacyContents.isEmpty else {
            return
        }
        /// Moving item by item, and never over something that already exists, means this does
        /// not depend on the new container being untouched. It is not: the per-source
        /// subdirectory is created, and given a metadata file by the OS, before this runs.
        for value in legacyContents where !value.hasPrefix(".") {
            let destination = currentRoot.appendingPathComponent(value)
            guard !manager.fileExists(atPath: destination.path) else {
                continue
            }
            try? manager.moveItem(at: legacyRoot.appendingPathComponent(value), to: destination)
        }
        UserDefaults.standard.set(true, forKey: legacyMigrationKey)
    }

    /// Set once the move above has been attempted, so a later launch cannot pull a stale
    /// container back over data the app has since written.
    private static var legacyMigrationKey: String {
        return "kite.migratedFromLegacyBundleId"
    }

    public static func migrate() {
        if let containerURL = containerURL, let legacy = legacyContainerURL, let sequence = FileManager.default.enumerator(atPath: legacy.path) {
            let contents = try? FileManager.default.contentsOfDirectory(at: containerURL, includingPropertiesForKeys: nil, options: [])
            if let contents = contents, !contents.isEmpty {
                return
            }
            for value in sequence {
                if let value = value as? String {
                    if !prefixList.contains(value) {
                        try? FileManager.default.moveItem(at: legacy.appendingPathComponent(value), to: containerURL.appendingPathComponent(value))
                    }
                }
            }
        }
    }
    
    public static var legacyContainerURL: URL? {
        let appGroupName = ApiEnvironment.group
        let containerUrl = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupName)
        return containerUrl
    }
    
    public static var group: String {
        return teamId + "." + bundleId
    }
    
    public static var appData: Data {
        let apiData = evaluateApiData() ?? ""
        let dict:[String: String] = ["bundleId": bundleId, "data": apiData]
        return try! JSONSerialization.data(withJSONObject: dict, options: [])
    }
    public static var language: String {
        return "macos"
    }
    
    public static var prefixList:[String] {
        return ["debug", "stable", "appstore", "beta"]
    }
    
    public static var resolvedDeviceName:[String : String]? {
        if let file = Bundle.main.path(forResource: "mac_devices", ofType: "txt") {
            if let string = try? String(contentsOf: .init(fileURLWithPath: file)) {
                let lines = string.components(separatedBy: "\n\n")
                
                var result:[String : String] = [:]
                for line in lines {
                    let resolved = line.components(separatedBy: "\n")
                    if resolved.count == 2 {
                        result[resolved[1]] = resolved[0]
                    }
                }
                
                return result
            }
        }
        return nil
    }
    
    public static var prefix: String {
        var prefix: String = ""
        switch Configuration.value(for: .source) {
        case "DEBUG":
            prefix = "debug"
        case "STABLE":
            prefix = "stable"
        case "APP_STORE":
            prefix = "appstore"
        default:
            prefix = "beta"
        }
        return prefix
    }
    
    public static var version: String {
        var suffix: String = ""
        
        suffix = Configuration.value(for: .source) ?? "DEBUG"
        let shortVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] ?? ""
        return "\(shortVersion) \(suffix)"
    }
    
    public static var premiumProductId: String {
        return "org.telegram.telegramPremium.monthly"
    }
}


