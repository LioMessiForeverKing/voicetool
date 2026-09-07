import Observation
import ServiceManagement

/// "Open at login", backed by `SMAppService.mainApp`.
///
/// Deliberately **not** a `Settings` property, even though it reads like one in the UI.
/// Every other preference is a value this app owns in `UserDefaults`; this one is owned by
/// the system, and two things routinely change it behind the app's back:
///
/// - The user can switch the item off in System Settings ▸ General ▸ Login Items while the
///   app isn't even running.
/// - macOS can park a fresh registration in `.requiresApproval` until the user allows it,
///   so `register()` returning without throwing does **not** mean the item is live.
///
/// A mirrored `Bool` in `UserDefaults` goes stale the moment either happens, and the switch
/// then confidently shows the opposite of the truth. `SMAppService.status` is queried on
/// every read instead, and is the only source of truth here.
@MainActor
@Observable
final class LaunchAtLogin {
    static let shared = LaunchAtLogin()

    /// Non-`nil` when the last change didn't take effect, including the approval case.
    ///
    /// Surfaced in Settings rather than only logged: a login item that failed to register
    /// behaves exactly like one that worked until the next reboot, which is the worst
    /// possible time to discover it.
    private(set) var problem: String?

    /// `status` is a system call, not stored state, so the observation graph cannot see it
    /// change. Bumping this after every mutation is what makes SwiftUI re-read it.
    private var revision = 0

    private init() {}

    var status: SMAppService.Status {
        _ = revision
        return SMAppService.mainApp.status
    }

    var isEnabled: Bool { status == .enabled }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            problem = nil
        } catch {
            Log.app.error("login item \(enabled ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            problem = error.localizedDescription
        }

        revision += 1

        // Checked after the bump: the interesting case is a register() still awaiting approval.
        if problem == nil, enabled, status != .enabled {
            problem = Self.describe(status)
        }
    }

    /// Human-readable reason the item isn't running, for the Settings note.
    private static func describe(_ status: SMAppService.Status) -> String? {
        switch status {
        case .enabled:
            return nil
        case .requiresApproval:
            return "Approve Murmur in System Settings ▸ General ▸ Login Items."
        case .notFound:
            // Registration resolves the running bundle, and macOS rejects a transient location.
            return "macOS can't register this copy. Run it from /Applications."
        case .notRegistered:
            return "The login item isn't registered."
        @unknown default:
            return "The login item is unavailable."
        }
    }
}
