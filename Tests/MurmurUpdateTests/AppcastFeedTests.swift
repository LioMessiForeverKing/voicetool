import Foundation
import Testing

/// The update feed contract, checked against the two files that have to agree about it.
///
/// Every one of these failures is silent and permanent in the same way: the app keeps
/// launching, keeps transcribing, and simply never learns that a newer version exists. The
/// only person who can notice is someone comparing an installed copy against Releases by
/// hand, and nobody does that.
enum Feed {

    static var repoRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    static var infoPlist: [String: Any] {
        get throws {
            let data = try Data(contentsOf: repoRoot.appendingPathComponent("Resources/Info.plist"))
            let parsed = try PropertyListSerialization.propertyList(from: data, format: nil)
            return parsed as? [String: Any] ?? [:]
        }
    }

    static var releaseWorkflow: String {
        get throws {
            try String(
                contentsOf: repoRoot.appendingPathComponent(".github/workflows/release.yml"),
                encoding: .utf8
            )
        }
    }
}

@Suite("Update feed")
struct AppcastFeedTests {

    @Test("The feed URL is the redirect that survives a release, not a per-tag asset")
    func feedURLDoesNotMove() throws {
        let feed = try Feed.infoPlist["SUFeedURL"] as? String
        let url = try #require(feed.flatMap(URL.init(string:)), "SUFeedURL is missing or unparseable")

        #expect(url.scheme == "https", "Sparkle refuses a plaintext feed")
        #expect(url.path.contains("/releases/latest/download/"),
                "\(url.path) pins the feed to one release; installed copies would never update")
        #expect(!url.path.contains("/releases/download/"),
                "\(url.path) is a per-tag asset URL and changes every release")
    }

    @Test("The workflow publishes the asset the feed URL asks for")
    func appcastAssetNameMatches() throws {
        let feed = try #require(Feed.infoPlist["SUFeedURL"] as? String)
        let asset = try #require(URL(string: feed)?.lastPathComponent)

        #expect(asset.hasSuffix(".xml"), "the feed should point at an appcast, got \(asset)")
        #expect(try Feed.releaseWorkflow.contains(asset),
                "release.yml never mentions \(asset), so nothing publishes the feed")
    }

    @Test("The public update key is a whole Ed25519 key")
    func publicKeyIsWellFormed() throws {
        let encoded = try #require(Feed.infoPlist["SUPublicEDKey"] as? String,
                                   "SUPublicEDKey is missing; Sparkle rejects every update")
        let raw = try #require(Data(base64Encoded: encoded), "SUPublicEDKey is not base64")
        #expect(raw.count == 32, "an Ed25519 public key is 32 bytes, this one is \(raw.count)")
    }

    @Test("Nothing checks for updates until the user has been asked")
    func automaticChecksAreNotPresumed() throws {
        let plist = try Feed.infoPlist
        #expect(plist["SUEnableAutomaticChecks"] == nil,
                "Murmur is otherwise fully on-device; the first network call is the user's to allow")
    }
}
