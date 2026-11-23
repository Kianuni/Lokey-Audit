import CoreFoundation
import Darwin
import Foundation

#if canImport(UIKit)
import UIKit
#endif
#if canImport(CoreHaptics)
import CoreHaptics
#endif

/// Lightweight status heartbeat written by `LokeyKeyboard.appex` into the shared App Group container
/// so `Lokey` Host App can distinguish "App Group active & Full Access granted" from
/// "Keyboard running offline without Full Access".
public struct LokeyKeyboardHeartbeat: Codable, Sendable, Equatable {
    public var hasFullAccess: Bool
    public var appGroupID: String?
    public var bundleVersion: String
    public var updatedAtEpoch: Double

    public init(
        hasFullAccess: Bool,
        appGroupID: String?,
        bundleVersion: String,
        updatedAtEpoch: Double = Date().timeIntervalSince1970
    ) {
        self.hasFullAccess = hasFullAccess
        self.appGroupID = appGroupID
        self.bundleVersion = bundleVersion
        self.updatedAtEpoch = updatedAtEpoch
    }
}

public struct LokeyHostGeometrySnapshot: Codable, Sendable, Equatable {
    public var isHostActive: Bool
    public var didSwitchInputModeInSession: Bool
    public var hostTopPadding: Double
    public var keyboardFrameHeight: Double
    public var initialPreSwitchHeight: Double
    public var screenWidth: Double
    public var screenHeight: Double
    public var updatedAtUptime: Double

    public init(
        isHostActive: Bool,
        didSwitchInputModeInSession: Bool,
        hostTopPadding: Double,
        keyboardFrameHeight: Double,
        initialPreSwitchHeight: Double = 0,
        screenWidth: Double = 0,
        screenHeight: Double = 0,
        updatedAtUptime: Double = ProcessInfo.processInfo.systemUptime
    ) {
        self.isHostActive = isHostActive
        self.didSwitchInputModeInSession = didSwitchInputModeInSession
        self.hostTopPadding = hostTopPadding
        self.keyboardFrameHeight = keyboardFrameHeight
        self.initialPreSwitchHeight = initialPreSwitchHeight
        self.screenWidth = screenWidth
        self.screenHeight = screenHeight
        self.updatedAtUptime = updatedAtUptime
    }

    /// Deterministically reconciles iOS 26's `+17.0pt` rounded Liquid Glass top padding against UIKit's actual
    /// `visibleHeight` (`screenBounds.maxY - keyboardFrameEnd.minY`):
    /// - Engages `17.0pt` when iOS physically inflates the container by `+11..+21pt` above unpadded height
    ///   (strictly below Emoji's `+22.5pt` Max / `+41.0pt` Pro height delta, so Emoji never false-triggers).
    /// - Self-heals immediately to `0.0pt` on ANY frame notification (`willShow`, `willChangeFrame`, `didChangeFrame`, `didShow`)
    ///   when iOS presents `LokeyKeyboard` with `0.0pt` top padding (`-22.5..-9.5pt` below standard height, e.g. `331.0pt` vs `348.0pt`),
    ///   while ignoring narrower system keyboards without predictive bars (`303pt`, `-45pt`).
    public static func evaluateHostTopPadding(
        visibleHeight: Double,
        currentAppliedPadding: Double,
        screenWidth: Double,
        screenHeight: Double,
        hasHomeIndicator: Bool,
        calibratedDockHeight: inout Double?,
        isEmojiActive: Bool
    ) -> Double {
        guard screenWidth > 0,
              screenWidth < screenHeight,
              screenWidth <= 500.0,
              visibleHeight >= 220.0 else {
            return 0.0
        }
        let standardInputH: Double = isEmojiActive ? 295.0 : (screenWidth >= 414.0 ? 272.5 : 254.0)
        let defaultDockH: Double = hasHomeIndicator ? 75.5 : 0.0
        let dockH: Double
        if let cal = calibratedDockHeight,
           (hasHomeIndicator ? (66.0...85.0).contains(cal) : (0.0...14.0).contains(cal)) {
            dockH = cal
        } else {
            dockH = defaultDockH
        }
        let expectedFullH = standardInputH + dockH
        let delta = visibleHeight - expectedFullH

        if !isEmojiActive && currentAppliedPadding <= 0.01 && abs(delta) <= 4.5 {
            calibratedDockHeight = visibleHeight - standardInputH
            return 0.0
        }
        if !isEmojiActive && currentAppliedPadding > 0.01 && delta >= -22.5 && delta <= -9.5 {
            return 0.0
        }
        if !isEmojiActive && currentAppliedPadding <= 0.01 && delta >= 11.0 && delta <= 21.0 {
            return 17.0
        }
        return currentAppliedPadding
    }
}

/// Process-external boot-scoped session state tracking whether `InputUI.app` has instantiated a built-in
/// `UIKeyboardLayoutStar` keyboard during the current OS boot (`additionalTopPaddingForRoundedKeyboard == 17.0pt`).
public struct LokeyInputUISessionState: Codable, Sendable, Equatable {
    public var didActivateSystemKeyboardLayout: Bool
    public var updatedAtUptime: Double
    public var updatedAtEpoch: Double?
    public var bootEpoch: Double?
    public var installEpoch: Double?
    public var bundleBuildVersion: String?
    public var lastColdResetEpoch: Double?

    public init(
        didActivateSystemKeyboardLayout: Bool,
        updatedAtUptime: Double = ProcessInfo.processInfo.systemUptime,
        updatedAtEpoch: Double? = Date().timeIntervalSince1970,
        bootEpoch: Double? = nil,
        installEpoch: Double? = nil,
        bundleBuildVersion: String? = nil,
        lastColdResetEpoch: Double? = nil
    ) {
        self.didActivateSystemKeyboardLayout = didActivateSystemKeyboardLayout
        self.updatedAtUptime = updatedAtUptime
        self.updatedAtEpoch = updatedAtEpoch
        self.bootEpoch = bootEpoch
        self.installEpoch = installEpoch
        self.bundleBuildVersion = bundleBuildVersion
        self.lastColdResetEpoch = lastColdResetEpoch
    }
}

public struct LokeyAppGroupBridgeStatus: Sendable, Equatable {
    public var hostGroups: [String]
    public var extensionGroups: [String]
    public var resolvedGroupID: String?
    public var hasEntitlementMismatch: Bool
    public var extensionHeartbeat: LokeyKeyboardHeartbeat?

    public init(
        hostGroups: [String],
        extensionGroups: [String],
        resolvedGroupID: String?,
        hasEntitlementMismatch: Bool,
        extensionHeartbeat: LokeyKeyboardHeartbeat?
    ) {
        self.hostGroups = hostGroups
        self.extensionGroups = extensionGroups
        self.resolvedGroupID = resolvedGroupID
        self.hasEntitlementMismatch = hasEntitlementMismatch
        self.extensionHeartbeat = extensionHeartbeat
    }
}

/// Resolves the standard `App Group` container shared between `Lokey` (Host App) and `LokeyKeyboard` (Extension).
public enum LokeyAppGroup {
    public static let defaultIdentifier = "group.com.kianuni.lokey"

    private static let cacheLock = NSLock()
    private static var didResolveContainer = false
    private static var cachedContainer: (id: String, url: URL)?
    private static var cachedLokeySupportDir: URL?
    private static var cachedCandidateIdentifiers: [String]?
    private static var cachedAccessibleContainers: [(id: String, groupURL: URL, lokeyDir: URL)]?
    private static var _overrideCandidateIdentifiersForTesting: [String]?

    internal static var overrideCandidateIdentifiersForTesting: [String]? {
        get {
            cacheLock.lock()
            defer { cacheLock.unlock() }
            return _overrideCandidateIdentifiersForTesting
        }
        set {
            cacheLock.lock()
            _overrideCandidateIdentifiersForTesting = newValue
            didResolveContainer = false
            cachedContainer = nil
            cachedLokeySupportDir = nil
            cachedCandidateIdentifiers = nil
            cachedAccessibleContainers = nil
            cacheLock.unlock()
        }
    }

    internal static func resetCacheForTesting() {
        cacheLock.lock()
        didResolveContainer = false
        cachedContainer = nil
        cachedLokeySupportDir = nil
        cachedCandidateIdentifiers = nil
        cachedAccessibleContainers = nil
        cacheLock.unlock()
    }

    private static let heartbeatFilename = "lokey_keyboard_heartbeat.json"
    private static let heartbeatDefaultsKey = "com.kianuni.lokey.keyboard_heartbeat.v1"
    private static let extensionActivatedKey = "com.kianuni.lokey.extension_activated.v1"
    private static let hostGeometryFilename = "lokey_host_geometry.json"
    private static let hostGeometryDefaultsKey = "com.kianuni.lokey.host_geometry.v1"
    private static let extensionVisibilityFilename = "lokey_extension_visibility.json"
    private static let extensionVisibilityDefaultsKey = "com.kianuni.lokey.extension_visibility.v1"
    private static let inputUISessionFilename = "lokey_inputui_session.json"
    private static let inputUISessionDefaultsKey = "lokey.inputui.session.v1"

    /// Parses `com.apple.security.application-groups` from CMS-signed provisioning data via standard Foundation APIs.
    internal static func extractAppGroupsFromProvisionData(_ data: Data) -> [String] {
        guard !data.isEmpty,
              let startRange = data.range(of: Data("<plist".utf8)),
              let endRange = data.range(of: Data("</plist>".utf8), in: startRange.lowerBound..<data.endIndex) else {
            return []
        }
        let plistData = data[startRange.lowerBound..<endRange.upperBound]
        guard let plist = try? PropertyListSerialization.propertyList(from: plistData, options: [], format: nil) as? [String: Any],
              let entitlements = plist["Entitlements"] as? [String: Any],
              let groups = entitlements["com.apple.security.application-groups"] as? [String] else {
            return []
        }
        return groups.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }

    private static func readProvisionGroups(at bundleURL: URL) -> [String] {
        let profileURL = bundleURL.appendingPathComponent("embedded.mobileprovision")
        guard let data = try? Data(contentsOf: profileURL) else { return [] }
        return extractAppGroupsFromProvisionData(data)
    }

    private static func siblingBundleURL(from currentBundleURL: URL) -> URL? {
        if currentBundleURL.pathExtension == "appex" {
            return currentBundleURL.deletingLastPathComponent().deletingLastPathComponent()
        }
        if currentBundleURL.pathExtension == "app" {
            return currentBundleURL.appendingPathComponent("PlugIns/LokeyKeyboard.appex", isDirectory: true)
        }
        return nil
    }

    /// Ordered candidate App Group IDs (`LokeyAppGroupID` Info.plist key, `defaultIdentifier`, and provisioning fallbacks for re-signing).
    public static var candidateIdentifiers: [String] {
        cacheLock.lock()
        if let override = _overrideCandidateIdentifiersForTesting, !override.isEmpty {
            cacheLock.unlock()
            return override
        }
        if let cached = cachedCandidateIdentifiers {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        var ordered: [String] = []
        func appendUnique(_ id: String?) {
            guard let id else { return }
            let trimmed = id.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty && !ordered.contains(trimmed) {
                ordered.append(trimmed)
            }
        }
        appendUnique(Bundle.main.object(forInfoDictionaryKey: "LokeyAppGroupID") as? String)
        appendUnique(defaultIdentifier)

        let currentURL = Bundle.main.bundleURL
        let currentProvisionGroups = readProvisionGroups(at: currentURL)
        let siblingProvisionGroups = siblingBundleURL(from: currentURL).map { readProvisionGroups(at: $0) } ?? []
        if !currentProvisionGroups.isEmpty {
            let siblingSet = Set(siblingProvisionGroups)
            for gid in currentProvisionGroups where siblingSet.contains(gid) {
                appendUnique(gid)
            }
            for gid in currentProvisionGroups {
                appendUnique(gid)
            }
        }
        for gid in siblingProvisionGroups {
            appendUnique(gid)
        }

        if let rawBundleID = Bundle.main.bundleIdentifier?.trimmingCharacters(in: .whitespacesAndNewlines),
           !rawBundleID.isEmpty {
            let baseID: String
            if rawBundleID.hasSuffix(".keyboard") {
                baseID = String(rawBundleID.dropLast(".keyboard".count))
            } else if rawBundleID.hasSuffix(".tests") {
                baseID = String(rawBundleID.dropLast(".tests".count))
            } else {
                baseID = rawBundleID
            }
            if !baseID.isEmpty && baseID != "com.kianuni.lokey" {
                appendUnique("group.\(baseID)")
            }
        }

        cacheLock.lock()
        cachedCandidateIdentifiers = ordered
        cacheLock.unlock()
        return ordered
    }

    /// Verifies that the App Group container is genuinely mounted AND writable in the current sandbox
    /// (critical inside `LokeyKeyboard.appex`, where `containerURL` may be non-nil even when `Allow Full Access` is OFF and `mkdir` fails with `EPERM`).
    private static func writableLokeyDirectory(in groupURL: URL) -> URL? {
        let fm = FileManager.default
        let dir = groupURL
            .appendingPathComponent("Library", isDirectory: true)
            .appendingPathComponent("Application Support", isDirectory: true)
            .appendingPathComponent("Lokey", isDirectory: true)
        do {
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            guard fm.isWritableFile(atPath: dir.path) else {
                return nil
            }
            return dir
        } catch {
            return nil
        }
    }

    /// Returns all genuinely writable App Group containers for this process in priority order.
    public static func accessibleContainers() -> [(id: String, groupURL: URL, lokeyDir: URL)] {
        cacheLock.lock()
        if let cached = cachedAccessibleContainers, !cached.isEmpty {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let fm = FileManager.default
        var results: [(id: String, groupURL: URL, lokeyDir: URL)] = []
        for id in candidateIdentifiers {
            guard let url = fm.containerURL(forSecurityApplicationGroupIdentifier: id),
                  let dir = writableLokeyDirectory(in: url) else {
                continue
            }
            results.append((id: id, groupURL: url, lokeyDir: dir))
        }
        if !results.isEmpty {
            cacheLock.lock()
            cachedAccessibleContainers = results
            if !didResolveContainer, let first = results.first {
                didResolveContainer = true
                cachedContainer = (first.id, first.groupURL)
                cachedLokeySupportDir = first.lokeyDir
            }
            cacheLock.unlock()
        }
        return results
    }

    /// Resets cached resolution so toggling `Allow Full Access` in Settings is picked up immediately on next keyboard appearance.
    public static func invalidateCacheIfUnresolved() {
        cacheLock.lock()
        if let dir = cachedLokeySupportDir, !FileManager.default.isWritableFile(atPath: dir.path) {
            didResolveContainer = false
            cachedContainer = nil
            cachedLokeySupportDir = nil
            cachedAccessibleContainers = nil
        } else if let firstDir = cachedAccessibleContainers?.first?.lokeyDir,
                  !FileManager.default.isWritableFile(atPath: firstDir.path) {
            cachedAccessibleContainers = nil
        }
        cacheLock.unlock()
    }

    /// Returns `(groupID, containerURL)` for the first provisioned AND writable App Group accessible to this process, or `nil`.
    public static func resolvedContainer() -> (id: String, url: URL)? {
        cacheLock.lock()
        if didResolveContainer, let cached = cachedContainer {
            cacheLock.unlock()
            return cached
        }
        cacheLock.unlock()

        let fm = FileManager.default
        var found: (id: String, url: URL)?
        var foundLokeyDir: URL?
        for id in candidateIdentifiers {
            if let url = fm.containerURL(forSecurityApplicationGroupIdentifier: id),
               let dir = writableLokeyDirectory(in: url) {
                found = (id, url)
                foundLokeyDir = dir
                break
            }
        }

        cacheLock.lock()
        // Only freeze positive writable hits; if Full Access was off at launch (`EPERM`) and later enabled, allow seamless retry!
        if let found, let foundLokeyDir {
            didResolveContainer = true
            cachedContainer = found
            cachedLokeySupportDir = foundLokeyDir
        }
        cacheLock.unlock()
        return found
    }

    private static func resolvedAppGroupLokeyDir() -> URL? {
        cacheLock.lock()
        if let dir = cachedLokeySupportDir {
            cacheLock.unlock()
            return dir
        }
        cacheLock.unlock()

        guard let (_, groupURL) = resolvedContainer(),
              let dir = writableLokeyDirectory(in: groupURL) else {
            return nil
        }

        cacheLock.lock()
        cachedLokeySupportDir = dir
        cacheLock.unlock()
        return dir
    }

    /// Process-private local `Application Support/LokeyLocal` directory (always writable even when `Allow Full Access` is OFF).
    public static func localPrivateSupportDirectoryURL() -> URL {
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let localDir = baseDir.appendingPathComponent("LokeyLocal", isDirectory: true)
        try? FileManager.default.createDirectory(at: localDir, withIntermediateDirectories: true)
        return localDir
    }

    public static func sharedSupportDirectoryURL() -> URL {
        if let dir = resolvedAppGroupLokeyDir() {
            return dir
        }
        let baseDir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.temporaryDirectory
        let lokeyDir = baseDir.appendingPathComponent("Lokey", isDirectory: true)
        try? FileManager.default.createDirectory(at: lokeyDir, withIntermediateDirectories: true)
        return lokeyDir
    }

    public static func sharedLexiconsDirectoryURL(createIfNeeded: Bool = true) -> URL {
        let dir = sharedSupportDirectoryURL().appendingPathComponent("Lexicons", isDirectory: true)
        if createIfNeeded {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    /// Writes a tiny heartbeat from `LokeyKeyboard.appex` into the shared App Group whenever `hasFullAccess` allows container writes.
    public static func writeExtensionHeartbeat(hasFullAccess: Bool, bundleVersion: String) {
        invalidateCacheIfUnresolved()
        guard let (gid, _) = resolvedContainer(),
              let dir = resolvedAppGroupLokeyDir() else {
            return
        }
        let hb = LokeyKeyboardHeartbeat(
            hasFullAccess: hasFullAccess,
            appGroupID: gid,
            bundleVersion: bundleVersion
        )
        guard let data = try? JSONEncoder().encode(hb) else { return }
        let fileURL = dir.appendingPathComponent(heartbeatFilename)
        let wroteFile = (try? data.write(to: fileURL, options: .atomic)) != nil
        if let suite = UserDefaults(suiteName: gid) {
            suite.set(true, forKey: extensionActivatedKey)
            if !wroteFile {
                suite.set(data, forKey: heartbeatDefaultsKey)
            }
        }
    }

    /// Returns `true` when `LokeyKeyboard.appex` has recorded a heartbeat, visibility state, or activation marker in the App Group.
    public static func hasExtensionActivationMarker() -> Bool {
        if readExtensionHeartbeat() != nil || readExtensionVisibility() != nil {
            return true
        }
        for item in accessibleContainers() {
            if let suite = UserDefaults(suiteName: item.id), suite.bool(forKey: extensionActivatedKey) {
                return true
            }
        }
        return sharedDefaults().bool(forKey: extensionActivatedKey)
    }

    /// Reads the latest `LokeyKeyboardHeartbeat` across any accessible App Group container.
    public static func readExtensionHeartbeat() -> LokeyKeyboardHeartbeat? {
        var newest: LokeyKeyboardHeartbeat?
        for item in accessibleContainers() {
            let fileURL = item.lokeyDir.appendingPathComponent(heartbeatFilename)
            var didReadFile = false
            if let data = try? Data(contentsOf: fileURL),
               let hb = try? JSONDecoder().decode(LokeyKeyboardHeartbeat.self, from: data) {
                didReadFile = true
                if newest == nil || hb.updatedAtEpoch > (newest?.updatedAtEpoch ?? 0) {
                    newest = hb
                }
            }
            if !didReadFile,
               let suite = UserDefaults(suiteName: item.id),
               let data = suite.data(forKey: heartbeatDefaultsKey),
               let hb = try? JSONDecoder().decode(LokeyKeyboardHeartbeat.self, from: data) {
                if newest == nil || hb.updatedAtEpoch > (newest?.updatedAtEpoch ?? 0) {
                    newest = hb
                }
            }
        }
        return newest
    }

    /// Audits App Group availability (`group.com.kianuni.lokey`) and extension heartbeat status.
    public static func inspectBridgeStatus() -> LokeyAppGroupBridgeStatus {
        let configured = candidateIdentifiers
        let resolvedID = resolvedContainer()?.id
        let extHB = readExtensionHeartbeat()
        let hasMismatch = (resolvedID != nil && extHB?.appGroupID != nil && extHB?.appGroupID != resolvedID)
        return LokeyAppGroupBridgeStatus(
            hostGroups: configured,
            extensionGroups: configured,
            resolvedGroupID: resolvedID,
            hasEntitlementMismatch: hasMismatch,
            extensionHeartbeat: extHB
        )
    }

    /// Direct file-backed JSON preferences path inside the shared App Group container (immune to `cfprefsd` caching).
    public static func sharedSettingsFileURL() -> URL? {
        resolvedAppGroupLokeyDir()?.appendingPathComponent("lokey_settings.json")
    }

    /// Ultra-fast (`~3 µs`) POSIX `stat` modification timestamp check on `lokey_settings.json`.
    public static func sharedSettingsModificationTime() -> TimeInterval {
        guard let url = sharedSettingsFileURL() else { return 0 }
        var st = stat()
        let ok = url.path.withCString { cPath in
            stat(cPath, &st) == 0
        }
        guard ok else { return 0 }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) * 1e-9
    }

    /// Direct file-backed JSON path for personal 26-key adaptive touch calibration (`< 2.5 KB`).
    public static func sharedTouchCalibrationFileURL() -> URL? {
        resolvedAppGroupLokeyDir()?.appendingPathComponent("lokey_touch_calibration.json")
    }

    public static func sharedTouchCalibrationModificationTime() -> TimeInterval {
        guard let url = sharedTouchCalibrationFileURL() else { return 0 }
        var st = stat()
        let ok = url.path.withCString { cPath in
            stat(cPath, &st) == 0
        }
        guard ok else { return 0 }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) * 1e-9
    }

    public static func sharedDefaults() -> UserDefaults {
        if let (id, _) = resolvedContainer(), let suite = UserDefaults(suiteName: id) {
            return suite
        }
        return .standard
    }

    public static func sharedDatabaseURL() -> URL {
        sharedSupportDirectoryURL().appendingPathComponent("user_lexicon.sqlite3")
    }

    public static func sharedDiagnosticLogFileURL() -> URL {
        sharedSupportDirectoryURL().appendingPathComponent("lokey_touch_diagnostics.json")
    }

    public static func sharedDiagnosticLogModificationTime() -> TimeInterval {
        let url = sharedDiagnosticLogFileURL()
        var st = stat()
        let ok = url.path.withCString { cPath in
            stat(cPath, &st) == 0
        }
        guard ok else { return 0 }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) * 1e-9
    }

    public static func sharedSelectionFeedbackFileURL() -> URL {
        sharedSupportDirectoryURL().appendingPathComponent("lokey_selection_feedback.json")
    }

    public static func sharedSelectionFeedbackModificationTime() -> TimeInterval {
        let url = sharedSelectionFeedbackFileURL()
        var st = stat()
        let ok = url.path.withCString { cPath in
            stat(cPath, &st) == 0
        }
        guard ok else { return 0 }
        return Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) * 1e-9
    }

    /// Writes live host keyboard container geometry from `Lokey` Host App so `LokeyKeyboard` compensates
    /// iOS 26's `+17.0pt` Liquid Glass rounded top padding (`additionalTopPaddingForRoundedKeyboard`) after `🌐` input-mode switches.
    public static func writeHostGeometry(_ snapshot: LokeyHostGeometrySnapshot, notifyIPC: Bool = true) {
        invalidateCacheIfUnresolved()
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        let containers = accessibleContainers()
        if !containers.isEmpty {
            for item in containers {
                let fileURL = item.lokeyDir.appendingPathComponent(hostGeometryFilename)
                let wroteFile = (try? data.write(to: fileURL, options: .atomic)) != nil
                if !wroteFile, let suite = UserDefaults(suiteName: item.id) {
                    suite.set(data, forKey: hostGeometryDefaultsKey)
                }
            }
        } else if let dir = resolvedAppGroupLokeyDir() {
            try? data.write(to: dir.appendingPathComponent(hostGeometryFilename), options: .atomic)
        }
        if notifyIPC {
            LokeyIPC.postHostGeometryChanged()
        }
    }

    /// Reads the latest `LokeyHostGeometrySnapshot` across accessible App Group containers.
    public static func readHostGeometry() -> LokeyHostGeometrySnapshot? {
        var newest: LokeyHostGeometrySnapshot?
        for item in accessibleContainers() {
            let fileURL = item.lokeyDir.appendingPathComponent(hostGeometryFilename)
            var didReadFile = false
            if let data = try? Data(contentsOf: fileURL),
               let snap = try? JSONDecoder().decode(LokeyHostGeometrySnapshot.self, from: data) {
                didReadFile = true
                if newest == nil || snap.updatedAtUptime > (newest?.updatedAtUptime ?? -1) {
                    newest = snap
                }
            }
            if !didReadFile,
               let suite = UserDefaults(suiteName: item.id),
               let data = suite.data(forKey: hostGeometryDefaultsKey),
               let snap = try? JSONDecoder().decode(LokeyHostGeometrySnapshot.self, from: data) {
                if newest == nil || snap.updatedAtUptime > (newest?.updatedAtUptime ?? -1) {
                    newest = snap
                }
            }
        }
        return newest
    }

    public struct ExtensionVisibilityState: Codable, Sendable, Equatable {
        public var isVisible: Bool
        public var updatedAtUptime: Double
        public var isEmojiActive: Bool?
        public var appliedTopPadding: Double?
        public var requestedHeight: Double?

        public init(
            isVisible: Bool,
            updatedAtUptime: Double = ProcessInfo.processInfo.systemUptime,
            isEmojiActive: Bool? = nil,
            appliedTopPadding: Double? = nil,
            requestedHeight: Double? = nil
        ) {
            self.isVisible = isVisible
            self.updatedAtUptime = updatedAtUptime
            self.isEmojiActive = isEmojiActive
            self.appliedTopPadding = appliedTopPadding
            self.requestedHeight = requestedHeight
        }
    }

    public static func writeExtensionVisibility(
        isVisible: Bool,
        isEmojiActive: Bool? = nil,
        appliedTopPadding: Double? = nil,
        requestedHeight: Double? = nil
    ) {
        invalidateCacheIfUnresolved()
        let state = ExtensionVisibilityState(
            isVisible: isVisible,
            isEmojiActive: isEmojiActive,
            appliedTopPadding: appliedTopPadding,
            requestedHeight: requestedHeight
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        let containers = accessibleContainers()
        if !containers.isEmpty {
            for item in containers {
                let fileURL = item.lokeyDir.appendingPathComponent(extensionVisibilityFilename)
                let wroteFile = (try? data.write(to: fileURL, options: .atomic)) != nil
                if !wroteFile, let suite = UserDefaults(suiteName: item.id) {
                    suite.set(data, forKey: extensionVisibilityDefaultsKey)
                }
            }
        } else if let dir = resolvedAppGroupLokeyDir() {
            try? data.write(to: dir.appendingPathComponent(extensionVisibilityFilename), options: .atomic)
        }
    }

    public static func readExtensionVisibility() -> ExtensionVisibilityState? {
        var newest: ExtensionVisibilityState?
        for item in accessibleContainers() {
            let fileURL = item.lokeyDir.appendingPathComponent(extensionVisibilityFilename)
            var didReadFile = false
            if let data = try? Data(contentsOf: fileURL),
               let st = try? JSONDecoder().decode(ExtensionVisibilityState.self, from: data) {
                didReadFile = true
                if newest == nil || st.updatedAtUptime > (newest?.updatedAtUptime ?? -1) {
                    newest = st
                }
            }
            if !didReadFile,
               let suite = UserDefaults(suiteName: item.id),
               let data = suite.data(forKey: extensionVisibilityDefaultsKey),
               let st = try? JSONDecoder().decode(ExtensionVisibilityState.self, from: data) {
                if newest == nil || st.updatedAtUptime > (newest?.updatedAtUptime ?? -1) {
                    newest = st
                }
            }
        }
        return newest
    }

    private static let cachedInstallEpochLock = NSLock()
    private static var _cachedInstallEpoch: Double?
    private static let cachedBootEpochLock = NSLock()
    private static var _cachedBootEpoch: Double?

    /// Kernel boot wall-clock timestamp (`sysctlbyname("kern.boottime")`), immune to `systemUptime`
    /// deep-sleep suspension drift (`CLOCK_UPTIME_RAW` pauses while asleep whereas `Date()` advances).
    public static func currentKernelBootEpoch() -> Double? {
        cachedBootEpochLock.lock()
        if let hit = _cachedBootEpoch {
            cachedBootEpochLock.unlock()
            return hit
        }
        cachedBootEpochLock.unlock()

        var tv = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &tv, &size, nil, 0) == 0, tv.tv_sec > 0 else {
            return nil
        }
        let boot = Double(tv.tv_sec) + Double(tv.tv_usec) * 1e-6
        cachedBootEpochLock.lock()
        _cachedBootEpoch = boot
        cachedBootEpochLock.unlock()
        return boot
    }

    public static func currentBundleBuildVersion() -> String {
        (Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String) ?? ""
    }

    /// Canonical installation timestamp (`max(st_mtime, st_ctime)`) of `LokeyKeyboard` so both `Lokey.app`
    /// and `LokeyKeyboard.appex` compute the identical epoch and automatically invalidate stale
    /// `InputUI.app` session state across IPA reinstalls/upgrades without requiring a kernel reboot.
    public static func currentBundleInstallEpoch(executableURL: URL? = nil) -> Double {
        if executableURL == nil {
            cachedInstallEpochLock.lock()
            if let hit = _cachedInstallEpoch {
                cachedInstallEpochLock.unlock()
                return hit
            }
            cachedInstallEpochLock.unlock()
        }

        let targetURL: URL?
        if let executableURL {
            targetURL = executableURL
        } else if Bundle.main.bundleURL.pathExtension == "appex" {
            targetURL = Bundle.main.executableURL
        } else {
            let embeddedExtExec = Bundle.main.bundleURL
                .appendingPathComponent("PlugIns", isDirectory: true)
                .appendingPathComponent("LokeyKeyboard.appex", isDirectory: true)
                .appendingPathComponent("LokeyKeyboard")
            targetURL = FileManager.default.fileExists(atPath: embeddedExtExec.path)
                ? embeddedExtExec
                : Bundle.main.executableURL
        }

        var result: Double = 0.0
        if let targetURL {
            var st = stat()
            let ok = targetURL.path.withCString { stat($0, &st) == 0 }
            if ok {
                let mtime = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) * 1e-9
                let ctime = Double(st.st_ctimespec.tv_sec) + Double(st.st_ctimespec.tv_nsec) * 1e-9
                result = max(mtime, ctime)
            }
        }
        if executableURL == nil {
            cachedInstallEpochLock.lock()
            _cachedInstallEpoch = result
            cachedInstallEpochLock.unlock()
        }
        return result
    }

    /// Deterministically resolves whether `InputUI.app` has activated a built-in `UIKeyboardLayoutStar`
    /// (`+17.0pt` rounded top padding) using kernel boot time (`kern.boottime`), host cold-reset epoch,
    /// persisted session state, and external switch epoch.
    public static func resolveSystemKeyboardLayoutActivated(
        hasEnabledSystemKeyboard: Bool,
        inProcessActivated: Bool,
        savedSession: LokeyInputUISessionState?,
        systemSwitchEpoch: Double?,
        nowEpoch: Double = Date().timeIntervalSince1970,
        nowUptime: Double = ProcessInfo.processInfo.systemUptime,
        kernelBootEpoch: Double? = LokeyAppGroup.currentKernelBootEpoch()
    ) -> (activated: Bool, shouldPersistActivation: Bool) {
        guard hasEnabledSystemKeyboard else {
            return (false, false)
        }
        let bootEpoch: Double
        if let kb = kernelBootEpoch, kb > 0.0, kb <= nowEpoch + 5.0 {
            bootEpoch = kb
        } else {
            bootEpoch = nowEpoch - nowUptime
        }
        var baselineEpoch = bootEpoch + 1.0
        if let coldReset = savedSession?.lastColdResetEpoch, coldReset > 0.0 {
            baselineEpoch = max(baselineEpoch, coldReset + 0.5)
        }
        if let switchEpoch = systemSwitchEpoch,
           switchEpoch > baselineEpoch,
           switchEpoch <= nowEpoch + 5.0 {
            return (true, savedSession?.didActivateSystemKeyboardLayout != true)
        }
        if let saved = savedSession {
            return (saved.didActivateSystemKeyboardLayout, false)
        }
        return (inProcessActivated, false)
    }

    /// Persists whether `InputUI.app` has activated a system keyboard layout (`+17.0pt` rounded top padding)
    /// scoped by current OS boot (`kern.boottime` + monotonic uptime).
    /// Writes to accessible App Group containers AND extension/app-local `UserDefaults.standard` so state
    /// persists even when `Allow Full Access` is disabled and survives `Lokey` IPA updates on the same OS boot.
    public static func writeInputUISessionState(
        didActivateSystemKeyboardLayout: Bool,
        nowUptime: Double = ProcessInfo.processInfo.systemUptime,
        nowEpoch: Double = Date().timeIntervalSince1970,
        bootEpoch: Double? = nil,
        installEpoch: Double? = nil,
        bundleBuildVersion: String? = nil,
        markColdReset: Bool = false
    ) {
        invalidateCacheIfUnresolved()
        let resolvedBoot = bootEpoch ?? currentKernelBootEpoch()
        let resolvedInstall = installEpoch ?? currentBundleInstallEpoch()
        let resolvedBuild = bundleBuildVersion ?? currentBundleBuildVersion()
        let preservedColdReset: Double?
        if didActivateSystemKeyboardLayout {
            preservedColdReset = nil
        } else if markColdReset {
            preservedColdReset = nowEpoch
        } else {
            preservedColdReset = readInputUISessionState(
                nowUptime: nowUptime,
                expectedBootEpoch: resolvedBoot
            )?.lastColdResetEpoch
        }

        let state = LokeyInputUISessionState(
            didActivateSystemKeyboardLayout: didActivateSystemKeyboardLayout,
            updatedAtUptime: nowUptime,
            updatedAtEpoch: nowEpoch,
            bootEpoch: resolvedBoot,
            installEpoch: resolvedInstall,
            bundleBuildVersion: resolvedBuild,
            lastColdResetEpoch: preservedColdReset
        )
        guard let data = try? JSONEncoder().encode(state) else { return }
        UserDefaults.standard.set(data, forKey: inputUISessionDefaultsKey)
        let containers = accessibleContainers()
        if !containers.isEmpty {
            for item in containers {
                let fileURL = item.lokeyDir.appendingPathComponent(inputUISessionFilename)
                let wroteFile = (try? data.write(to: fileURL, options: .atomic)) != nil
                if !wroteFile, let suite = UserDefaults(suiteName: item.id) {
                    suite.set(data, forKey: inputUISessionDefaultsKey)
                }
            }
        } else if let dir = resolvedAppGroupLokeyDir() {
            try? data.write(to: dir.appendingPathComponent(inputUISessionFilename), options: .atomic)
        }
    }

    /// Reads the OS-boot-scoped `InputUI.app` layout activation state across App Group containers
    /// and local `UserDefaults.standard`, rejecting snapshots from earlier OS boots while retaining
    /// valid same-boot `InputUI.app` state across `Lokey` IPA upgrades/reinstalls.
    public static func readInputUISessionState(
        nowUptime: Double = ProcessInfo.processInfo.systemUptime,
        expectedBootEpoch: Double? = LokeyAppGroup.currentKernelBootEpoch()
    ) -> LokeyInputUISessionState? {
        var newest: LokeyInputUISessionState?
        func consider(_ candidate: LokeyInputUISessionState) {
            guard candidate.updatedAtUptime >= 0.0,
                  candidate.updatedAtUptime <= nowUptime + 1.0 else {
                return
            }
            if let expectedBootEpoch, expectedBootEpoch > 0.0,
               let savedBoot = candidate.bootEpoch, savedBoot > 0.0 {
                guard abs(savedBoot - expectedBootEpoch) <= 10.0 else {
                    return
                }
            }
            if newest == nil || candidate.updatedAtUptime > (newest?.updatedAtUptime ?? -1) {
                newest = candidate
            }
        }
        for item in accessibleContainers() {
            let fileURL = item.lokeyDir.appendingPathComponent(inputUISessionFilename)
            var didReadFile = false
            if let data = try? Data(contentsOf: fileURL),
               let st = try? JSONDecoder().decode(LokeyInputUISessionState.self, from: data) {
                didReadFile = true
                consider(st)
            }
            if !didReadFile,
               let suite = UserDefaults(suiteName: item.id),
               let data = suite.data(forKey: inputUISessionDefaultsKey),
               let st = try? JSONDecoder().decode(LokeyInputUISessionState.self, from: data) {
                consider(st)
            }
        }
        if let localData = UserDefaults.standard.data(forKey: inputUISessionDefaultsKey),
           let st = try? JSONDecoder().decode(LokeyInputUISessionState.self, from: localData) {
            consider(st)
        }
        return newest
    }
}

/// Zero-network local Darwin notification bridge so preference & lexicon edits in `Lokey` Host App
/// take effect immediately inside a resident `LokeyKeyboard` extension process.
public enum LokeyIPC {
    public static let settingsDidChangeNotification = Notification.Name("com.kianuni.lokey.local.settingsDidChange")
    public static let lexiconDidChangeNotification = Notification.Name("com.kianuni.lokey.local.lexiconDidChange")
    public static let baseLexiconDidChangeNotification = Notification.Name("com.kianuni.lokey.local.baseLexiconDidChange")
    public static let diagnosticLogDidChangeNotification = Notification.Name("com.kianuni.lokey.local.diagnosticLogDidChange")
    public static let diagnosticLogDidClearNotification = Notification.Name("com.kianuni.lokey.local.diagnosticLogDidClear")
    public static let selectionFeedbackDidChangeNotification = Notification.Name("com.kianuni.lokey.local.selectionFeedbackDidChange")
    public static let selectionFeedbackDidClearNotification = Notification.Name("com.kianuni.lokey.local.selectionFeedbackDidClear")
    public static let hostGeometryDidChangeNotification = Notification.Name("com.kianuni.lokey.local.hostGeometryDidChange")

    private static let darwinSettingsName = "com.kianuni.lokey.darwin.settingsChanged" as CFString
    private static let darwinLexiconName = "com.kianuni.lokey.darwin.lexiconChanged" as CFString
    private static let darwinBaseLexiconName = "com.kianuni.lokey.darwin.baseLexiconChanged" as CFString
    private static let darwinDiagnosticLogName = "com.kianuni.lokey.darwin.diagnosticLogChanged" as CFString
    private static let darwinDiagnosticLogClearedName = "com.kianuni.lokey.darwin.diagnosticLogCleared" as CFString
    private static let darwinSelectionFeedbackName = "com.kianuni.lokey.darwin.selectionFeedbackChanged" as CFString
    private static let darwinSelectionFeedbackClearedName = "com.kianuni.lokey.darwin.selectionFeedbackCleared" as CFString
    private static let darwinHostGeometryName = "com.kianuni.lokey.darwin.hostGeometryChanged" as CFString
    private static var didRegisterObservers = false
    private static let lock = NSLock()
    private static var _settingsGeneration: UInt64 = 0

    public static var settingsGeneration: UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return _settingsGeneration
    }

    fileprivate static func bumpSettingsGeneration() {
        lock.lock()
        _settingsGeneration &+= 1
        lock.unlock()
    }

    public static func startObservingIfNeeded() {
        lock.lock()
        defer { lock.unlock() }
        guard !didRegisterObservers else { return }
        didRegisterObservers = true

        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                LokeyIPC.bumpSettingsGeneration()
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: LokeyIPC.settingsDidChangeNotification, object: nil)
                }
            },
            darwinSettingsName,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: LokeyIPC.lexiconDidChangeNotification, object: nil)
                }
            },
            darwinLexiconName,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: LokeyIPC.diagnosticLogDidChangeNotification, object: nil)
                }
            },
            darwinDiagnosticLogName,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: LokeyIPC.diagnosticLogDidClearNotification, object: nil)
                }
            },
            darwinDiagnosticLogClearedName,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: LokeyIPC.hostGeometryDidChangeNotification, object: nil)
                }
            },
            darwinHostGeometryName,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: LokeyIPC.baseLexiconDidChangeNotification, object: nil)
                }
            },
            darwinBaseLexiconName,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: LokeyIPC.selectionFeedbackDidChangeNotification, object: nil)
                }
            },
            darwinSelectionFeedbackName,
            nil,
            .deliverImmediately
        )
        CFNotificationCenterAddObserver(
            center,
            nil,
            { _, _, _, _, _ in
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: LokeyIPC.selectionFeedbackDidClearNotification, object: nil)
                }
            },
            darwinSelectionFeedbackClearedName,
            nil,
            .deliverImmediately
        )
    }

    public static func postSettingsChanged() {
        bumpSettingsGeneration()
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(darwinSettingsName), nil, nil, true)
    }

    public static func postLexiconChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(darwinLexiconName), nil, nil, true)
    }

    public static func postBaseLexiconChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(darwinBaseLexiconName), nil, nil, true)
    }

    public static func postDiagnosticLogChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(darwinDiagnosticLogName), nil, nil, true)
    }

    public static func postDiagnosticLogCleared() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(darwinDiagnosticLogClearedName), nil, nil, true)
    }

    public static func postSelectionFeedbackChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(darwinSelectionFeedbackName), nil, nil, true)
    }

    public static func postSelectionFeedbackCleared() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(darwinSelectionFeedbackClearedName), nil, nil, true)
    }

    public static func postHostGeometryChanged() {
        let center = CFNotificationCenterGetDarwinNotifyCenter()
        CFNotificationCenterPostNotification(center, CFNotificationName(darwinHostGeometryName), nil, nil, true)
    }
}

/// Fuzzy Pinyin equivalence pairs configurable by the user inside the Lokey Host App.
public struct FuzzyPinyinOptions: OptionSet, Codable, Sendable, Equatable {
    public let rawValue: UInt16

    public init(rawValue: UInt16) {
        self.rawValue = rawValue
    }

    public static let z_zh   = FuzzyPinyinOptions(rawValue: 1 << 0)
    public static let c_ch   = FuzzyPinyinOptions(rawValue: 1 << 1)
    public static let s_sh   = FuzzyPinyinOptions(rawValue: 1 << 2)
    public static let n_l    = FuzzyPinyinOptions(rawValue: 1 << 3)
    public static let f_h    = FuzzyPinyinOptions(rawValue: 1 << 4)
    public static let r_l    = FuzzyPinyinOptions(rawValue: 1 << 5)
    public static let an_ang = FuzzyPinyinOptions(rawValue: 1 << 6)
    public static let en_eng = FuzzyPinyinOptions(rawValue: 1 << 7)
    public static let in_ing = FuzzyPinyinOptions(rawValue: 1 << 8)

    public static let allCases: [(FuzzyPinyinOptions, String)] = [
        (.z_zh, "z = zh"),
        (.c_ch, "c = ch"),
        (.s_sh, "s = sh"),
        (.n_l, "n = l"),
        (.f_h, "f = h"),
        (.r_l, "r = l"),
        (.an_ang, "an = ang"),
        (.en_eng, "en = eng"),
        (.in_ing, "in = ing"),
    ]

    public var enabledCount: Int {
        Self.allCases.reduce(0) { $0 + (contains($1.0) ? 1 : 0) }
    }
}

public enum HapticStrength: Int, Codable, CaseIterable, Sendable {
    case off = 0
    case light = 1
    case crisp = 2

    public var title: String {
        switch self {
        case .off: return "关闭"
        case .light: return "轻柔"
        case .crisp: return "清脆"
        }
    }
}

public enum ChineseScriptMode: Int, Codable, CaseIterable, Sendable {
    case simplified = 0
    case traditionalTW = 1
    case traditionalHK = 2

    public var title: String {
        switch self {
        case .simplified: return "简体中文"
        case .traditionalTW: return "繁體（台灣正體）"
        case .traditionalHK: return "繁體（香港標準）"
        }
    }
}

public enum PinyinScheme: String, Codable, CaseIterable, Sendable, Hashable {
    case quanpin
    case xiaohe
    case ziranma

    public var title: String {
        switch self {
        case .quanpin: return "全拼（26 键）"
        case .xiaohe: return "小鹤双拼"
        case .ziranma: return "自然码双拼"
        }
    }

    public var spaceWatermark: String {
        switch self {
        case .quanpin: return "拼"
        case .xiaohe: return "鹤"
        case .ziranma: return "自"
        }
    }
}

/// Shared preferences persisted in the `App Group` container (both direct atomic JSON file + `UserDefaults`).
public struct LokeySettings: Codable, Equatable, Sendable {
    public var hapticStrength: HapticStrength {
        didSet {
            switch hapticStrength {
            case .off:
                if hapticFeedbackIntensity != 0.0 {
                    hapticFeedbackIntensity = 0.0
                }
            case .light:
                if hapticFeedbackIntensity == 0.0 || hapticFeedbackIntensity > 0.70 {
                    hapticFeedbackIntensity = 0.65
                }
            case .crisp:
                if hapticFeedbackIntensity <= 0.70 {
                    hapticFeedbackIntensity = 1.0
                }
            }
        }
    }

    public var hapticFeedbackIntensity: Double {
        didSet {
            let clamped = min(1.0, max(0.0, hapticFeedbackIntensity))
            if hapticFeedbackIntensity != clamped {
                hapticFeedbackIntensity = clamped
            }
            if clamped == 0.0 {
                hapticStrength = .off
            } else if clamped <= 0.70 {
                hapticStrength = .light
            } else {
                hapticStrength = .crisp
            }
        }
    }

    public var isKeyClickSoundEnabled: Bool
    public var showPeriodBesideSpace: Bool
    public var enableSpatialCorrection: Bool
    public var enableAdaptiveTouchCalibration: Bool
    public var enableEmojiCandidates: Bool
    public var enableDiagnosticLogging: Bool
    public var enableSelectionFeedbackLogging: Bool
    public var fuzzyOptions: FuzzyPinyinOptions
    public var chineseScriptMode: ChineseScriptMode
    public var enableComposingSpaceTrackpad: Bool
    public var pinyinScheme: PinyinScheme
    public var enableTopRowNumberSwipe: Bool

    public init(
        hapticStrength: HapticStrength? = nil,
        hapticFeedbackIntensity: Double = 0.65,
        isKeyClickSoundEnabled: Bool = true,
        showPeriodBesideSpace: Bool = false,
        enableSpatialCorrection: Bool = true,
        enableAdaptiveTouchCalibration: Bool = true,
        enableEmojiCandidates: Bool = true,
        enableDiagnosticLogging: Bool = false,
        enableSelectionFeedbackLogging: Bool = false,
        fuzzyOptions: FuzzyPinyinOptions = [],
        chineseScriptMode: ChineseScriptMode = .simplified,
        enableComposingSpaceTrackpad: Bool = false,
        pinyinScheme: PinyinScheme = .quanpin,
        enableTopRowNumberSwipe: Bool = false
    ) {
        let clamped = min(1.0, max(0.0, hapticFeedbackIntensity))
        self.hapticFeedbackIntensity = clamped
        if let explicitStrength = hapticStrength {
            self.hapticStrength = explicitStrength
            if explicitStrength == .off && hapticFeedbackIntensity == 0.65 {
                self.hapticFeedbackIntensity = 0.0
            } else if explicitStrength == .crisp && hapticFeedbackIntensity == 0.65 {
                self.hapticFeedbackIntensity = 1.0
            }
        } else {
            if clamped == 0.0 {
                self.hapticStrength = .off
            } else if clamped <= 0.70 {
                self.hapticStrength = .light
            } else {
                self.hapticStrength = .crisp
            }
        }
        self.isKeyClickSoundEnabled = isKeyClickSoundEnabled
        self.showPeriodBesideSpace = showPeriodBesideSpace
        self.enableSpatialCorrection = enableSpatialCorrection
        self.enableAdaptiveTouchCalibration = enableAdaptiveTouchCalibration
        self.enableEmojiCandidates = enableEmojiCandidates
        self.enableDiagnosticLogging = enableDiagnosticLogging
        self.enableSelectionFeedbackLogging = enableSelectionFeedbackLogging
        self.fuzzyOptions = fuzzyOptions
        self.chineseScriptMode = chineseScriptMode
        self.enableComposingSpaceTrackpad = enableComposingSpaceTrackpad
        self.pinyinScheme = pinyinScheme
        self.enableTopRowNumberSwipe = enableTopRowNumberSwipe
    }

    private enum CodingKeys: String, CodingKey {
        case hapticStrength
        case hapticFeedbackIntensity
        case isKeyClickSoundEnabled
        case showPeriodBesideSpace
        case enableSpatialCorrection
        case enableAdaptiveTouchCalibration
        case enableEmojiCandidates
        case enableDiagnosticLogging
        case enableSelectionFeedbackLogging
        case labLoggingOptInV2
        case fuzzyOptions
        case chineseScriptMode
        case enableComposingSpaceTrackpad
        case pinyinScheme
        case enableTopRowNumberSwipe
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let legacyStrength = try container.decodeIfPresent(HapticStrength.self, forKey: .hapticStrength)

        if let intensity = try container.decodeIfPresent(Double.self, forKey: .hapticFeedbackIntensity) {
            let clamped = min(1.0, max(0.0, intensity))
            self.hapticFeedbackIntensity = clamped
            if let str = legacyStrength {
                self.hapticStrength = str
            } else {
                if clamped == 0.0 {
                    self.hapticStrength = .off
                } else if clamped <= 0.70 {
                    self.hapticStrength = .light
                } else {
                    self.hapticStrength = .crisp
                }
            }
        } else if let legacy = legacyStrength {
            self.hapticStrength = legacy
            switch legacy {
            case .off:
                self.hapticFeedbackIntensity = 0.0
            case .light:
                self.hapticFeedbackIntensity = 0.65
            case .crisp:
                self.hapticFeedbackIntensity = 1.0
            }
        } else {
            self.hapticStrength = .light
            self.hapticFeedbackIntensity = 0.65
        }

        self.isKeyClickSoundEnabled = try container.decodeIfPresent(Bool.self, forKey: .isKeyClickSoundEnabled) ?? true
        self.showPeriodBesideSpace = try container.decodeIfPresent(Bool.self, forKey: .showPeriodBesideSpace) ?? false
        self.enableSpatialCorrection = try container.decodeIfPresent(Bool.self, forKey: .enableSpatialCorrection) ?? true
        self.enableAdaptiveTouchCalibration = try container.decodeIfPresent(Bool.self, forKey: .enableAdaptiveTouchCalibration) ?? true
        self.enableEmojiCandidates = try container.decodeIfPresent(Bool.self, forKey: .enableEmojiCandidates) ?? true
        // Both optional lab logging toggles default to OFF unless explicitly opted in via `labLoggingOptInV2`.
        // Older persisted configs without `labLoggingOptInV2` migrate cleanly to OFF.
        let hasOptInSchema = (try container.decodeIfPresent(Bool.self, forKey: .labLoggingOptInV2)) ?? false
        if hasOptInSchema {
            self.enableDiagnosticLogging = try container.decodeIfPresent(Bool.self, forKey: .enableDiagnosticLogging) ?? false
            self.enableSelectionFeedbackLogging = try container.decodeIfPresent(Bool.self, forKey: .enableSelectionFeedbackLogging) ?? false
        } else {
            self.enableDiagnosticLogging = false
            self.enableSelectionFeedbackLogging = false
        }
        self.fuzzyOptions = try container.decodeIfPresent(FuzzyPinyinOptions.self, forKey: .fuzzyOptions) ?? []
        self.chineseScriptMode = try container.decodeIfPresent(ChineseScriptMode.self, forKey: .chineseScriptMode) ?? .simplified
        self.enableComposingSpaceTrackpad = try container.decodeIfPresent(Bool.self, forKey: .enableComposingSpaceTrackpad) ?? false
        self.pinyinScheme = try container.decodeIfPresent(PinyinScheme.self, forKey: .pinyinScheme) ?? .quanpin
        self.enableTopRowNumberSwipe = try container.decodeIfPresent(Bool.self, forKey: .enableTopRowNumberSwipe) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(hapticStrength, forKey: .hapticStrength)
        try container.encode(hapticFeedbackIntensity, forKey: .hapticFeedbackIntensity)
        try container.encode(isKeyClickSoundEnabled, forKey: .isKeyClickSoundEnabled)
        try container.encode(showPeriodBesideSpace, forKey: .showPeriodBesideSpace)
        try container.encode(enableSpatialCorrection, forKey: .enableSpatialCorrection)
        try container.encode(enableAdaptiveTouchCalibration, forKey: .enableAdaptiveTouchCalibration)
        try container.encode(enableEmojiCandidates, forKey: .enableEmojiCandidates)
        try container.encode(true, forKey: .labLoggingOptInV2)
        try container.encode(enableDiagnosticLogging, forKey: .enableDiagnosticLogging)
        try container.encode(enableSelectionFeedbackLogging, forKey: .enableSelectionFeedbackLogging)
        try container.encode(fuzzyOptions, forKey: .fuzzyOptions)
        try container.encode(chineseScriptMode, forKey: .chineseScriptMode)
        try container.encode(enableComposingSpaceTrackpad, forKey: .enableComposingSpaceTrackpad)
        try container.encode(pinyinScheme, forKey: .pinyinScheme)
        try container.encode(enableTopRowNumberSwipe, forKey: .enableTopRowNumberSwipe)
    }

    private static let storageKey = "com.kianuni.lokey.settings.v1"
    private static let sharedCacheLock = NSLock()
    private static var cachedSharedSettings: LokeySettings?
    private static var cachedSharedMTime: TimeInterval = -1
    private static var cachedSharedGeneration: UInt64 = .max

    public static func load(from defaults: UserDefaults? = nil) -> LokeySettings {
        if defaults == nil {
            let mtime = LokeyAppGroup.sharedSettingsModificationTime()
            let gen = LokeyIPC.settingsGeneration
            if mtime > 0 {
                sharedCacheLock.lock()
                if let hit = cachedSharedSettings,
                   cachedSharedMTime == mtime,
                   cachedSharedGeneration == gen {
                    sharedCacheLock.unlock()
                    return hit
                }
                sharedCacheLock.unlock()
            }
            if let fileURL = LokeyAppGroup.sharedSettingsFileURL(),
               let fileData = try? Data(contentsOf: fileURL),
               let decoded = try? JSONDecoder().decode(LokeySettings.self, from: fileData) {
                let refreshedMTime = mtime > 0 ? mtime : LokeyAppGroup.sharedSettingsModificationTime()
                sharedCacheLock.lock()
                cachedSharedSettings = decoded
                cachedSharedMTime = refreshedMTime
                cachedSharedGeneration = gen
                sharedCacheLock.unlock()
                return decoded
            }
        }
        let store = defaults ?? LokeyAppGroup.sharedDefaults()
        guard let data = store.data(forKey: storageKey),
              let decoded = try? JSONDecoder().decode(LokeySettings.self, from: data) else {
            return LokeySettings()
        }
        return decoded
    }

    public func save(to defaults: UserDefaults? = nil, broadcast: Bool = true) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        if defaults == nil, let fileURL = LokeyAppGroup.sharedSettingsFileURL() {
            try? data.write(to: fileURL, options: .atomic)
        }
        let store = defaults ?? LokeyAppGroup.sharedDefaults()
        store.set(data, forKey: Self.storageKey)
        if broadcast && defaults == nil {
            LokeyIPC.postSettingsChanged()
        }
        if defaults == nil {
            let newMTime = LokeyAppGroup.sharedSettingsModificationTime()
            let newGen = LokeyIPC.settingsGeneration
            Self.sharedCacheLock.lock()
            Self.cachedSharedSettings = self
            Self.cachedSharedMTime = newMTime
            Self.cachedSharedGeneration = newGen
            Self.sharedCacheLock.unlock()
        }
    }
}

/// Persistent offline MRU Emoji store for the `常用` (`🕒`) category on `EmojiKeyboardView`.
/// Always maintains a full 32-item (`4 rows × 8 columns`) initial screen without blank slots.
public enum LokeyRecentEmojis {
    public static let maxCount = 32
    private static let storageKey = "com.kianuni.lokey.recent_emojis.v2"
    private static let cacheLock = NSLock()
    private static var cachedSharedList: [String]? = nil
    private static let persistQueue = DispatchQueue(label: "com.kianuni.lokey.recentEmojisIO", qos: .utility)

    /// Column-major (`4 rows × 8 columns`) default popular emojis calibrated to Native iOS 26.
    public static let defaultSeed: [String] = [
        "😂", "❤️", "😍", "😒",
        "👌", "☺️", "😊", "😘",
        "😭", "😩", "💕", "😔",
        "😏", "😁", "😳", "👍",
        "✌️", "😉", "😌", "💁",
        "🙈", "😎", "🎶", "👀",
        "😑", "😴", "😄", "😜",
        "😋", "👏", "🔥", "🎉"
    ]

    public static func load(from defaults: UserDefaults? = nil) -> [String] {
        if defaults == nil {
            cacheLock.lock()
            if let hit = cachedSharedList {
                cacheLock.unlock()
                return hit
            }
            cacheLock.unlock()
        }
        let store = defaults ?? LokeyAppGroup.sharedDefaults()
        let saved = store.stringArray(forKey: storageKey) ?? []
        var merged: [String] = []
        merged.reserveCapacity(maxCount)
        var seen = Set<String>()
        for e in saved where !e.isEmpty && seen.insert(e).inserted {
            merged.append(e)
            if merged.count == maxCount { break }
        }
        if merged.count < maxCount {
            for e in defaultSeed where seen.insert(e).inserted {
                merged.append(e)
                if merged.count == maxCount { break }
            }
        }
        if defaults == nil {
            cacheLock.lock()
            cachedSharedList = merged
            cacheLock.unlock()
        }
        return merged
    }

    public static func recordUsage(_ emoji: String, in defaults: UserDefaults? = nil) {
        guard !emoji.isEmpty else { return }
        var current = load(from: defaults)
        current.removeAll { $0 == emoji }
        current.insert(emoji, at: 0)
        if current.count > maxCount {
            current.removeSubrange(maxCount..<current.count)
        }
        if let defaults {
            defaults.set(current, forKey: storageKey)
        } else {
            cacheLock.lock()
            cachedSharedList = current
            cacheLock.unlock()
            let snapshot = current
            persistQueue.async {
                LokeyAppGroup.sharedDefaults().set(snapshot, forKey: storageKey)
            }
        }
    }
}

#if canImport(UIKit)
/// Stepless 0%–100% hardware haptic synthesizer shared by `Lokey` (live slider preview) and `LokeyKeyboard`.
/// Uses `CoreHaptics` (`CHHapticEngine` with `playsHapticsOnly = true`) for wide linear-resonant-actuator dynamic range
/// (from feather-light `1%` up to reinforced full-momentum mechanical thock at `100%`), with automatic `UIImpactFeedbackGenerator` fallback.
public final class LokeyHapticEngine {
    public static let shared = LokeyHapticEngine()

    private let hapticQueue = DispatchQueue(label: "com.kianuni.lokey.haptics", qos: .userInitiated)
    private let cooldownLock = NSLock()
    private var _coreHapticsCooldownUntilUptime: TimeInterval = 0

    private var coreHapticsCooldownUntilUptime: TimeInterval {
        get {
            cooldownLock.lock()
            let val = _coreHapticsCooldownUntilUptime
            cooldownLock.unlock()
            return val
        }
        set {
            cooldownLock.lock()
            _coreHapticsCooldownUntilUptime = newValue
            cooldownLock.unlock()
        }
    }

    #if canImport(CoreHaptics)
    private var engine: CHHapticEngine?
    private var isEngineRunning = false
    private var engineGeneration: UInt64 = 0
    private var isSuspended = false
    private var cachedPlayers: [Int: CHHapticPatternPlayer] = [:]
    private let supportsCoreHaptics: Bool
    #endif

    private lazy var softGenerator = UIImpactFeedbackGenerator(style: .soft)
    private lazy var lightGenerator = UIImpactFeedbackGenerator(style: .light)
    private lazy var mediumGenerator = UIImpactFeedbackGenerator(style: .medium)
    private lazy var heavyGenerator = UIImpactFeedbackGenerator(style: .heavy)
    private lazy var rigidGenerator = UIImpactFeedbackGenerator(style: .rigid)
    private var lastFallbackPrepareUptime: [Int: TimeInterval] = [:]

    private var lastPreviewTime: TimeInterval = 0
    private var lastPreviewIntensity: Double = -1

    private init() {
        #if canImport(CoreHaptics)
        self.supportsCoreHaptics = CHHapticEngine.capabilitiesForHardware().supportsHaptics
        #endif
    }

    public func prepare(forIntensity rawIntensity: Double = 0.65) {
        let t = min(1.0, max(0.0, rawIntensity))
        guard t > 0.004 else { return }

        #if canImport(CoreHaptics)
        if supportsCoreHaptics && ProcessInfo.processInfo.systemUptime >= coreHapticsCooldownUntilUptime {
            hapticQueue.async { [weak self] in
                guard let self else { return }
                self.isSuspended = false
                self.ensureCoreHapticsRunningOnQueue()
                if !self.isEngineRunning {
                    DispatchQueue.main.async { [weak self] in
                        self?.prepareFallbackTierIfNeeded(normalizedIntensity: t, force: false)
                    }
                }
            }
            return
        }
        #endif
        prepareFallbackTierIfNeeded(normalizedIntensity: t, force: false)
    }

    public func suspend() {
        #if canImport(CoreHaptics)
        if supportsCoreHaptics {
            coreHapticsCooldownUntilUptime = 0
            hapticQueue.async { [weak self] in
                guard let self else { return }
                self.isSuspended = true
                self.engineGeneration &+= 1
                self.cachedPlayers.removeAll(keepingCapacity: true)
                let oldEngine = self.engine
                self.engine = nil
                self.isEngineRunning = false
                self.retireEngineOnQueue(oldEngine)
            }
        }
        #endif
    }

    /// Resets CoreHaptics state across foldable display transitions so a migrated
    /// extension instance recreates its haptic session cleanly on the destination display without stalling.
    public func resetForDisplayTransition() {
        #if canImport(CoreHaptics)
        coreHapticsCooldownUntilUptime = 0
        hapticQueue.async { [weak self] in
            guard let self else { return }
            self.engineGeneration &+= 1
            self.cachedPlayers.removeAll(keepingCapacity: true)
            let oldEngine = self.engine
            self.engine = nil
            self.isEngineRunning = false
            self.retireEngineOnQueue(oldEngine)
        }
        #endif
    }

    /// Plays a key-tap haptic strictly proportional to `intensity` in `0.0 ... 1.0`.
    /// Dispatches CoreHaptics IPC off the main UI thread so `touchesBegan` returns in `< 0.01 ms`.
    public func playTap(intensity rawIntensity: Double, avoidCoreHapticsColdStart: Bool = false) {
        let t = min(1.0, max(0.0, rawIntensity))
        guard t > 0.004 else { return }

        #if canImport(CoreHaptics)
        if supportsCoreHaptics && ProcessInfo.processInfo.systemUptime >= coreHapticsCooldownUntilUptime {
            hapticQueue.async { [weak self] in
                guard let self else { return }
                if avoidCoreHapticsColdStart {
                    guard !self.isSuspended, self.isEngineRunning, self.engine != nil else {
                        DispatchQueue.main.async { [weak self] in
                            self?.playFallbackImpact(normalizedIntensity: t)
                        }
                        return
                    }
                    if !self.playCoreHapticTapOnQueue(normalizedIntensity: t, allowColdStart: false) {
                        DispatchQueue.main.async { [weak self] in
                            self?.playFallbackImpact(normalizedIntensity: t)
                        }
                    }
                    return
                }
                self.isSuspended = false
                if !self.playCoreHapticTapOnQueue(normalizedIntensity: t, allowColdStart: true) {
                    DispatchQueue.main.async { [weak self] in
                        self?.playFallbackImpact(normalizedIntensity: t)
                    }
                }
            }
            return
        }
        #endif

        DispatchQueue.main.async { [weak self] in self?.playFallbackImpact(normalizedIntensity: t) }
    }

    /// Throttled live preview while the user drags the haptic slider in `Lokey` Host App.
    public func playSliderPreview(intensity: Double, force: Bool = false) {
        let t = min(1.0, max(0.0, intensity))
        guard t > 0.004 else {
            lastPreviewIntensity = 0
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        if !force {
            guard (now - lastPreviewTime) >= 0.055,
                  abs(t - lastPreviewIntensity) >= 0.02 else {
                return
            }
        }
        lastPreviewTime = now
        lastPreviewIntensity = t
        playTap(intensity: t)
    }

    #if canImport(CoreHaptics)
    private func retireEngineOnQueue(_ oldEngine: CHHapticEngine?) {
        guard let oldEngine else { return }
        oldEngine.stoppedHandler = { _ in }
        oldEngine.resetHandler = {}
        oldEngine.stop { _ in
            // Strongly retain the retiring engine until CoreHaptics completes its async XPC stop.
            _ = oldEngine
        }
    }

    private func ensureCoreHapticsRunningOnQueue() {
        guard !isSuspended else { return }
        let now = ProcessInfo.processInfo.systemUptime
        if now < coreHapticsCooldownUntilUptime {
            return
        }
        if engine == nil {
            do {
                let eng = try CHHapticEngine()
                eng.playsHapticsOnly = true
                // Keep engine warm while keyboard is visible to eliminate 20-45ms cold-start XPC stalls!
                eng.isAutoShutdownEnabled = false
                engineGeneration &+= 1
                let expectedGen = engineGeneration
                eng.stoppedHandler = { [weak self, weak eng] _ in
                    self?.hapticQueue.async {
                        guard let self,
                              let eng,
                              self.engine === eng,
                              self.engineGeneration == expectedGen else { return }
                        self.isEngineRunning = false
                        self.cachedPlayers.removeAll(keepingCapacity: true)
                        self.engine = nil
                    }
                }
                eng.resetHandler = { [weak self, weak eng] in
                    self?.hapticQueue.async {
                        guard let self,
                              let eng,
                              self.engine === eng,
                              self.engineGeneration == expectedGen,
                              !self.isSuspended else { return }
                        self.isEngineRunning = false
                        self.cachedPlayers.removeAll(keepingCapacity: true)
                        do {
                            try eng.start()
                            self.isEngineRunning = true
                        } catch {
                            self.isEngineRunning = false
                            self.engine = nil
                            self.retireEngineOnQueue(eng)
                        }
                    }
                }
                self.engine = eng
            } catch {
                self.engine = nil
                self.isEngineRunning = false
                self.coreHapticsCooldownUntilUptime = now + 12.0
                return
            }
        }
        if !isEngineRunning, let eng = engine {
            do {
                try eng.start()
                isEngineRunning = true
            } catch {
                isEngineRunning = false
                self.engine = nil
                retireEngineOnQueue(eng)
                coreHapticsCooldownUntilUptime = now + 12.0
            }
        }
    }

    private func playCoreHapticTapOnQueue(normalizedIntensity t: Double, allowColdStart: Bool = true) -> Bool {
        guard !isSuspended else { return false }
        if allowColdStart {
            ensureCoreHapticsRunningOnQueue()
        }
        guard !isSuspended, isEngineRunning, let eng = engine else { return false }

        let bucket = max(1, min(50, Int((t * 50.0).rounded())))
        if let existingPlayer = cachedPlayers[bucket] {
            do {
                try existingPlayer.start(atTime: CHHapticTimeImmediate)
                return true
            } catch {
                cachedPlayers.removeValue(forKey: bucket)
            }
        }

        let q = Double(bucket) / 50.0
        let transientIntensity = Float(0.15 + 0.85 * pow(q, 0.72))
        let transientSharpness = Float(0.15 + 0.80 * q)

        var events: [CHHapticEvent] = [
            CHHapticEvent(
                eventType: .hapticTransient,
                parameters: [
                    CHHapticEventParameter(parameterID: .hapticIntensity, value: transientIntensity),
                    CHHapticEventParameter(parameterID: .hapticSharpness, value: transientSharpness),
                ],
                relativeTime: 0
            )
        ]

        if q > 0.55 {
            let u = (q - 0.55) / 0.45
            let bodyIntensity = Float(0.28 + 0.72 * u)
            let bodySharpness = Float(0.32 + 0.48 * u)
            let bodyDuration: TimeInterval = 0.010 + 0.014 * u
            events.append(
                CHHapticEvent(
                    eventType: .hapticContinuous,
                    parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: bodyIntensity),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: bodySharpness),
                    ],
                    relativeTime: 0.002,
                    duration: bodyDuration
                )
            )
        }

        do {
            let pattern = try CHHapticPattern(events: events, parameters: [])
            let player = try eng.makePlayer(with: pattern)
            if cachedPlayers.count >= 16, cachedPlayers[bucket] == nil, let evictedKey = cachedPlayers.keys.first {
                cachedPlayers.removeValue(forKey: evictedKey)
            }
            cachedPlayers[bucket] = player
            try player.start(atTime: CHHapticTimeImmediate)
            return true
        } catch {
            let oldEngine = engine
            engine = nil
            isEngineRunning = false
            cachedPlayers.removeAll(keepingCapacity: true)
            retireEngineOnQueue(oldEngine)
            coreHapticsCooldownUntilUptime = ProcessInfo.processInfo.systemUptime + 12.0
            return false
        }
    }
    #endif

    private func fallbackTierAndGenerator(for t: Double) -> (tier: Int, generator: UIImpactFeedbackGenerator, intensity: CGFloat) {
        if t <= 0.25 {
            return (0, softGenerator, CGFloat(max(0.20, t / 0.25)))
        } else if t <= 0.50 {
            return (1, lightGenerator, CGFloat(0.35 + 0.65 * ((t - 0.25) / 0.25)))
        } else if t <= 0.72 {
            return (2, mediumGenerator, CGFloat(0.45 + 0.55 * ((t - 0.50) / 0.22)))
        } else if t <= 0.88 {
            return (3, heavyGenerator, CGFloat(0.60 + 0.40 * ((t - 0.72) / 0.16)))
        } else {
            return (4, rigidGenerator, CGFloat(0.78 + 0.22 * ((t - 0.88) / 0.12)))
        }
    }

    private func prepareFallbackTierIfNeeded(normalizedIntensity t: Double, force: Bool) {
        let (tier, generator, _) = fallbackTierAndGenerator(for: t)
        let now = ProcessInfo.processInfo.systemUptime
        if !force, let last = lastFallbackPrepareUptime[tier], now >= last, (now - last) < 0.25 {
            return
        }
        lastFallbackPrepareUptime[tier] = now
        generator.prepare()
    }

    private func playFallbackImpact(normalizedIntensity t: Double) {
        let (_, generator, u) = fallbackTierAndGenerator(for: t)
        generator.impactOccurred(intensity: u)
        prepareFallbackTierIfNeeded(normalizedIntensity: t, force: false)
    }
}
#endif
