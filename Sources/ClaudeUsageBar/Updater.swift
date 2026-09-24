import AppKit
import CryptoKit
import Foundation

struct AppRelease: Sendable, Equatable {
    let version: String
    let zipURL: URL
    let checksumURL: URL?
    let pageURL: URL?
}

enum UpdateError: LocalizedError {
    case notConfigured
    case noAsset
    case checksumMismatch
    case badArchive
    case notWritable(String)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "Updates aren't configured for this build."
        case .noAsset: return "The latest release has no app download."
        case .checksumMismatch: return "Downloaded update failed its checksum; not installed."
        case .badArchive: return "Downloaded update didn't contain the app."
        case .notWritable(let path): return "Can't replace the app at \(path). Move it to ~/Applications or /Applications."
        }
    }
}

/// Self-update from GitHub Releases.
/// A release carries `ClaudeUsageBar-<version>.zip` and `ClaudeUsageBar-<version>.zip.sha256`.
enum Updater {
    /// "owner/repo", baked into Info.plist by build.sh. Missing for local builds without a remote.
    static var repository: String? {
        let value = Bundle.main.object(forInfoDictionaryKey: "UpdateRepository") as? String
        return value?.isEmpty == false ? value : nil
    }

    static var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0.0.0"
    }

    static func latestRelease() async throws -> AppRelease? {
        guard let repository else { throw UpdateError.notConfigured }
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("ClaudeUsageBar/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return try parseRelease(data)
    }

    static func parseRelease(_ data: Data) throws -> AppRelease? {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = json["tag_name"] as? String,
              json["draft"] as? Bool != true, json["prerelease"] as? Bool != true else { return nil }
        let assets = json["assets"] as? [[String: Any]] ?? []
        func asset(_ match: (String) -> Bool) -> URL? {
            assets.first { match($0["name"] as? String ?? "") }
                .flatMap { $0["browser_download_url"] as? String }
                .flatMap(URL.init(string:))
        }
        guard let zip = asset({ $0.hasPrefix("ClaudeUsageBar") && $0.hasSuffix(".zip") }) else { throw UpdateError.noAsset }
        return AppRelease(
            version: tag.hasPrefix("v") ? String(tag.dropFirst()) : tag,
            zipURL: zip,
            checksumURL: asset { $0.hasSuffix(".zip.sha256") },
            pageURL: (json["html_url"] as? String).flatMap(URL.init(string:))
        )
    }

    /// Numeric, dot-separated comparison: "1.10.0" > "1.9.2".
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// Downloads, verifies and stages the new app, then swaps it in after this process exits and relaunches.
    static func install(_ release: AppRelease) async throws {
        let destination = Bundle.main.bundleURL
        let parent = destination.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw UpdateError.notWritable(destination.path)
        }

        let (zip, _) = try await URLSession.shared.download(from: release.zipURL)
        if let checksumURL = release.checksumURL {
            let (sumData, _) = try await URLSession.shared.data(from: checksumURL)
            let expected = String(decoding: sumData, as: UTF8.self).split(separator: " ").first.map(String.init) ?? ""
            let actual = SHA256.hash(data: try Data(contentsOf: zip)).map { String(format: "%02x", $0) }.joined()
            guard expected.lowercased() == actual else { throw UpdateError.checksumMismatch }
        }

        let staging = FileManager.default.temporaryDirectory.appending(path: "ClaudeUsageBar-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, staging.path])
        let newApp = staging.appending(path: destination.lastPathComponent)
        guard let bundle = Bundle(url: newApp), bundle.bundleIdentifier == Bundle.main.bundleIdentifier else {
            throw UpdateError.badArchive
        }

        // Wait for us to quit, swap bundles, relaunch.
        let script = """
        while kill -0 \(ProcessInfo.processInfo.processIdentifier) 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old" && mv "$2" "$2.old" && mv "$1" "$2" && rm -rf "$2.old" "$3"
        open "$2"
        """
        let swapper = Process()
        swapper.executableURL = URL(fileURLWithPath: "/bin/sh")
        swapper.arguments = ["-c", script, "sh", newApp.path, destination.path, staging.path]
        try swapper.run()
        await MainActor.run { NSApp.terminate(nil) }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError.badArchive }
    }
}
