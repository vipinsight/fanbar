import AppKit
import Security
import Sparkle

/// Finding, announcing, and installing new releases through Sparkle.
///
/// FanBar is not in the App Store and can sit in the menu bar for weeks, so
/// Sparkle looks for a release every 12 hours (`SUScheduledCheckInterval`).
/// With "Install updates automatically" on, a found update downloads in the
/// background and installs straight away, unless the fan is under manual
/// control: restarting would drop the user's fan setting, so it waits in the
/// menu for them instead. With it off, a scheduled find is announced in the
/// menu rather than popping a window over whatever they are doing.
final class Updates: NSObject, SPUUpdaterDelegate, SPUStandardUserDriverDelegate {
    /// Release builds only. A local `build-app.sh` bundle must not replace
    /// itself with the GitHub download, nor badge itself with an update.
    let isEnabled = Updates.isSignedRelease

    /// Told the waiting version, or nil when there is none.
    var onAvailableChange: (String?) -> Void = { _ in }

    /// Whether installing and relaunching right now is fine.
    var canRestartNow: () -> Bool = { true }

    private(set) var availableVersion: String?
    private var installNow: (() -> Void)?
    private lazy var controller = SPUStandardUpdaterController(
        startingUpdater: isEnabled,
        updaterDelegate: self,
        userDriverDelegate: self
    )

    func start() {
        _ = controller
    }

    var installsAutomatically: Bool {
        get { controller.updater.automaticallyDownloadsUpdates }
        set { controller.updater.automaticallyDownloadsUpdates = newValue }
    }

    /// Whether the waiting update is already downloaded, so restarting installs it.
    var isReadyToInstall: Bool { installNow != nil }

    func checkForUpdates() {
        controller.checkForUpdates(nil)
    }

    /// Installs a downloaded update and relaunches; otherwise opens Sparkle's window for it.
    func installAvailableUpdate() {
        if let installNow { installNow() } else { checkForUpdates() }
    }

    private func setAvailable(_ version: String?) {
        DispatchQueue.main.async { [self] in
            guard availableVersion != version else { return }
            availableVersion = version
            onAvailableChange(version)
        }
    }

    // MARK: SPUUpdaterDelegate

    func updater(_ updater: SPUUpdater, didFindValidUpdate item: SUAppcastItem) {
        setAvailable(item.displayVersionString)
    }

    func updaterDidNotFindUpdate(_ updater: SPUUpdater) {
        installNow = nil
        setAvailable(nil)
    }

    // Sparkle stages an automatic download to install when the app quits.
    // Taking the block lets it happen now instead, the way Calendo restarts.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock: @escaping () -> Void) -> Bool {
        DispatchQueue.main.async { [self] in
            installNow = immediateInstallationBlock
            availableVersion = nil
            setAvailable(item.displayVersionString)
            if canRestartNow() { immediateInstallationBlock() }
        }
        return true
    }

    // MARK: SPUStandardUserDriverDelegate

    // A menu bar app has no Dock icon to bounce, so scheduled finds go in the menu.
    var supportsGentleScheduledUpdateReminders: Bool { true }

    func standardUserDriverShouldHandleShowingScheduledUpdate(_ update: SUAppcastItem, andInImmediateFocus immediateFocus: Bool) -> Bool {
        false
    }

    func standardUserDriverWillHandleShowingUpdate(_ handleShowingUpdate: Bool, forUpdate update: SUAppcastItem, state: SPUUserUpdateState) {
        setAvailable(update.displayVersionString)
    }

    // MARK: Release detection

    /// Developer ID builds carry a team identifier; ad-hoc local builds do not.
    private static var isSignedRelease: Bool {
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let info = info as? [String: Any] else { return false }
        return info[kSecCodeInfoTeamIdentifier as String] != nil
    }
}
