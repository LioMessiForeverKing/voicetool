import Combine
import Observation
import Sparkle

/// "Check for Updates…", backed by Sparkle and the appcast named in `Info.plist`.
///
/// One controller for the process lifetime. Sparkle schedules its own background checks and
/// hands the download to a helper that has to outlive the check that started it, so a
/// controller made per click would be torn down mid-update.
///
/// **Automatic checking is not turned on here.** Murmur transcribes entirely on-device and
/// makes no other network request, so the first one it ever makes is the user's to allow:
/// Sparkle asks on second launch, and `SUEnableAutomaticChecks` is deliberately absent from
/// `Info.plist` so that prompt is reached rather than answered on the user's behalf.
@MainActor
@Observable
final class Updates {
    static let shared = Updates()

    /// False while a check is already running, so the menu item can't be fired twice.
    private(set) var canCheck = false

    @ObservationIgnored private let controller: SPUStandardUpdaterController
    @ObservationIgnored private var observation: AnyCancellable?

    private init() {
        controller = SPUStandardUpdaterController(
            startingUpdater: true,
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        observation = controller.updater.publisher(for: \.canCheckForUpdates)
            .sink { [weak self] enabled in
                MainActor.assumeIsolated { self?.canCheck = enabled }
            }
    }

    /// Starts Sparkle's scheduler.
    ///
    /// Nothing checks for updates until this is called. The controller is created lazily, so
    /// an app that never touches it also never schedules a background check — and the only
    /// symptom is an installed copy that quietly stays on the version it was downloaded as.
    static func start() {
        _ = shared
    }

    func check() {
        controller.updater.checkForUpdates()
    }
}
