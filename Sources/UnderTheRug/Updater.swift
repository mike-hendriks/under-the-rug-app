import AppKit
import CryptoKit

/// Keeps the app up to date from GitHub Releases.
///
/// It checks the latest release shortly after launch and every six hours. With automatic updates on (the
/// default) a newer version is downloaded, checked (SHA-256 from GitHub, bundle identifier, version, code
/// signature), and installed as soon as the rugs are at rest: a tiny helper script waits for the app to quit,
/// swaps the bundle and opens the new version, which lays the rugs back down without the drop animation.
/// Only release builds update themselves; a build without a version from CI never does.
final class Updater {
    struct Release: Decodable {
        struct Asset: Decodable {
            let name: String
            let browserDownloadURL: URL
            let digest: String?

            enum CodingKeys: String, CodingKey {
                case name, digest
                case browserDownloadURL = "browser_download_url"
            }
        }

        let tagName: String
        let htmlURL: URL
        let assets: [Asset]

        enum CodingKeys: String, CodingKey {
            case assets
            case tagName = "tag_name"
            case htmlURL = "html_url"
        }

        var version: String { tagName.hasPrefix("v") ? String(tagName.dropFirst()) : tagName }
        var zip: Asset? { assets.first { $0.name.hasPrefix("UnderTheRug-") && $0.name.hasSuffix(".zip") } }
    }

    enum State: Equatable {
        case idle
        case checking
        case available(String)
        case downloading(String)
        case failed(String)
    }

    static let repository = "mike-hendriks/under-the-rug-app"
    static let launchedAfterUpdate = CommandLine.arguments.contains("--after-update")

    private(set) var state: State = .idle
    private(set) var latest: Release?
    /// Asked before installing, so an update never yanks a rug out from under the mouse.
    var canInstallNow: () -> Bool = { true }

    private var timer: Timer?
    private let defaults = UserDefaults.standard

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// Set by build-app.sh only when it is given a VERSION, i.e. on CI.
    var isReleaseBuild: Bool {
        Bundle.main.bundleURL.pathExtension == "app"
            && (Bundle.main.object(forInfoDictionaryKey: "UTRReleaseBuild") as? Bool ?? false)
    }

    var installsAutomatically: Bool {
        get { defaults.object(forKey: "autoUpdate") as? Bool ?? true }
        set {
            defaults.set(newValue, forKey: "autoUpdate")
            if newValue, case .available = state, let latest { install(latest, userInitiated: false) }
        }
    }

    func start() {
        guard isReleaseBuild else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 15) { [weak self] in self?.check(userInitiated: false) }
        let timer = Timer(timeInterval: 6 * 60 * 60, repeats: true) { [weak self] _ in self?.check(userInitiated: false) }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    // MARK: - Checking

    func check(userInitiated: Bool) {
        if case .downloading = state { return }
        state = .checking
        Task { @MainActor in
            do {
                let release = try await fetchLatest()
                latest = release
                if Updater.isNewer(release.version, than: currentVersion), release.zip != nil {
                    state = .available(release.version)
                    if installsAutomatically && isReleaseBuild {
                        install(release, userInitiated: userInitiated)
                    } else if userInitiated {
                        offer(release)
                    }
                } else {
                    state = .idle
                    if userInitiated { tell("You have the latest version.", "Under the Rug \(currentVersion) is the newest release.") }
                }
            } catch {
                state = .failed(error.localizedDescription)
                if userInitiated { tell("Couldn't check for updates.", error.localizedDescription) }
            }
        }
    }

    private func fetchLatest() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://api.github.com/repos/\(Updater.repository)/releases/latest")!)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("UnderTheRug-Updater", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 30
        let (data, response) = try await URLSession.shared.data(for: request)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badResponse }
        return try JSONDecoder().decode(Release.self, from: data)
    }

    /// Numeric comparison of dotted versions: 1.10.0 is newer than 1.9.3.
    static func isNewer(_ candidate: String, than current: String) -> Bool {
        let a = candidate.split(separator: ".").map { Int($0) ?? 0 }
        let b = current.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(a.count, b.count) {
            let x = i < a.count ? a[i] : 0, y = i < b.count ? b[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    func installAvailableUpdate() {
        guard let latest else { return }
        install(latest, userInitiated: true)
    }

    private func install(_ release: Release, userInitiated: Bool) {
        guard let asset = release.zip else { return }
        guard isReleaseBuild else {
            NSWorkspace.shared.open(release.htmlURL)
            return
        }
        let destination = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: destination.deletingLastPathComponent().path) else {
            // Installed somewhere we may not write (an admin-only folder): the menu offers the download instead.
            if userInitiated { offer(release, writable: false) }
            return
        }
        state = .downloading(release.version)
        Task { @MainActor in
            do {
                let newApp = try await download(asset, expectedVersion: release.version)
                waitUntilIdle { [weak self] in self?.swap(to: newApp, at: destination) }
            } catch {
                try? FileManager.default.removeItem(at: Updater.workFolder)
                state = .failed(error.localizedDescription)
            }
        }
    }

    private static var workFolder: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("UnderTheRugUpdate", isDirectory: true)
    }

    /// Downloads and unpacks the release, and refuses anything that is not exactly the app it claims to be.
    private func download(_ asset: Release.Asset, expectedVersion: String) async throws -> URL {
        let fm = FileManager.default
        let work = Updater.workFolder
        try? fm.removeItem(at: work)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)

        let (temp, response) = try await URLSession.shared.download(from: asset.browserDownloadURL)
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError.badResponse }
        let zip = work.appendingPathComponent(asset.name)
        try fm.moveItem(at: temp, to: zip)

        if let digest = asset.digest, digest.hasPrefix("sha256:") {
            let data = try Data(contentsOf: zip)
            let hash = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard hash == digest.dropFirst("sha256:".count).lowercased() else { throw UpdateError.checksumMismatch }
        }

        let unpacked = work.appendingPathComponent("unpacked", isDirectory: true)
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, unpacked.path])
        guard let app = try fm.contentsOfDirectory(at: unpacked, includingPropertiesForKeys: nil).first(where: { $0.pathExtension == "app" }),
              let info = Bundle(url: app)?.infoDictionary,
              info["CFBundleIdentifier"] as? String == Bundle.main.bundleIdentifier,
              info["CFBundleShortVersionString"] as? String == expectedVersion
        else { throw UpdateError.notOurApp }
        try run("/usr/bin/codesign", ["--verify", "--deep", app.path])
        return app
    }

    /// Installs only while nobody is pushing a rug around.
    private func waitUntilIdle(_ then: @escaping () -> Void) {
        if canInstallNow() {
            then()
        } else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in self?.waitUntilIdle(then) }
        }
    }

    /// Hands over to a helper script that swaps the bundle once this process has quit, then opens the new one.
    private func swap(to newApp: URL, at destination: URL) {
        let script = Updater.workFolder.appendingPathComponent("install.sh")
        let body = """
        #!/bin/sh
        # $1 pid to wait for, $2 installed app, $3 new app
        while kill -0 "$1" 2>/dev/null; do sleep 0.2; done
        rm -rf "$2.old"
        if mv "$2" "$2.old" && mv "$3" "$2"; then
          rm -rf "$2.old"
        elif [ -d "$2.old" ] && [ ! -d "$2" ]; then
          mv "$2.old" "$2"
        fi
        xattr -dr com.apple.quarantine "$2" 2>/dev/null
        open "$2" --args --after-update
        rm -rf "$(dirname "$0")"
        """
        do {
            try body.write(to: script, atomically: true, encoding: .utf8)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [script.path, String(ProcessInfo.processInfo.processIdentifier), destination.path, newApp.path]
            try process.run()
        } catch {
            state = .failed(error.localizedDescription)
            return
        }
        NSApp.terminate(nil)
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw UpdateError.toolFailed((tool as NSString).lastPathComponent) }
    }

    // MARK: - Asking

    private func offer(_ release: Release, writable: Bool = true) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Under the Rug \(release.version) is out."
        alert.informativeText = writable
            ? "You have \(currentVersion). Install the update now? The app restarts and your rugs stay where they are."
            : "You have \(currentVersion), but the app sits in a folder it can't write to. Download the new version from GitHub instead."
        alert.addButton(withTitle: writable ? "Install and Restart" : "Open GitHub")
        alert.addButton(withTitle: "Later")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        if writable {
            install(release, userInitiated: true)
        } else {
            NSWorkspace.shared.open(release.htmlURL)
        }
    }

    private func tell(_ message: String, _ detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

enum UpdateError: LocalizedError {
    case badResponse
    case checksumMismatch
    case notOurApp
    case toolFailed(String)

    var errorDescription: String? {
        switch self {
        case .badResponse: return "GitHub didn't answer as expected."
        case .checksumMismatch: return "The download was damaged (its checksum doesn't match)."
        case .notOurApp: return "The download doesn't contain the expected version of Under the Rug."
        case .toolFailed(let tool): return "Checking the update failed (\(tool))."
        }
    }
}
