import Foundation

/// Carries settings and data across the rename from "Murmur YouTube" to "Murmur".
///
/// The rename changed the bundle identifier, and two things are keyed to it that the user
/// would otherwise silently lose:
///
/// - **Preferences.** `UserDefaults.standard` is scoped to the bundle ID, so under the new
///   identifier every setting reads as unset — the push-to-talk key, the engine choice, the
///   cleanup toggles all revert to defaults with no indication why.
/// - **Data.** The dictionary and the run log live in a directory named after the app, so
///   the new build would look in an empty folder and present itself as a fresh install.
///
/// TCC is the one thing that genuinely cannot be carried over: the Accessibility grant is
/// bound to the bundle identifier by the OS, and there is no API to transfer it. That grant
/// has to be given once more, and the release notes say so rather than leaving it to be
/// discovered.
///
/// Runs at most once. Safe to call from several places — the first caller does the work and
/// the rest are a no-op — because the order in which SwiftUI touches `Settings`,
/// `DictionaryStore` and `RunLog` at launch is not something to depend on.
enum LegacyMigration {
    private static let legacyBundleID = "ai.pivotstudio.murmur-youtube"
    private static let legacyDirectoryName = "MurmurYouTube"
    private static let currentDirectoryName = "Murmur"
    private static let marker = "didMigrateFromMurmurYouTube"

    /// `static let` is lazy and runs exactly once, which is the whole guarantee here.
    private static let performed: Void = perform()

    static func runIfNeeded() {
        _ = performed
    }

    private static func perform() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: marker) else { return }
        defaults.set(true, forKey: marker)

        migrateSupportDirectory()
        migrateDefaults()
    }

    /// Moves `~/Library/Application Support/MurmurYouTube` to `.../Murmur`.
    ///
    /// A move rather than a copy, so there is exactly one live copy of the dictionary and the
    /// run log. Skipped entirely if the new directory already exists — that means the app has
    /// already run under the new name, and overwriting it would destroy newer data to restore
    /// older data.
    private static func migrateSupportDirectory() {
        let manager = FileManager.default
        guard let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            return
        }

        let old = base.appendingPathComponent(legacyDirectoryName, isDirectory: true)
        let new = base.appendingPathComponent(currentDirectoryName, isDirectory: true)

        guard manager.fileExists(atPath: old.path), !manager.fileExists(atPath: new.path) else {
            return
        }

        do {
            try manager.moveItem(at: old, to: new)
            Log.app.info("migrated data directory from \(legacyDirectoryName, privacy: .public)")
        } catch {
            Log.app.error("data migration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Copies the old domain's values into the new one.
    ///
    /// Only fills keys that aren't already set, so a preference chosen under the new name is
    /// never overwritten by a stale one. The old domain is left in place: it is a few bytes,
    /// and keeping it means a botched migration can be inspected rather than being gone.
    private static func migrateDefaults() {
        let defaults = UserDefaults.standard
        guard let legacy = defaults.persistentDomain(forName: legacyBundleID), !legacy.isEmpty else {
            return
        }

        var carried = 0
        for (key, value) in legacy where defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            carried += 1
        }

        if carried > 0 {
            Log.app.info("migrated \(carried, privacy: .public) preference(s) from the old bundle ID")
        }
    }
}
