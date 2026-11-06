import Foundation

/// "Is there a newer QuickChat?" — nothing more.
///
/// The app ships as a notarized DMG from GitHub Releases and has no installer,
/// so without this a user who downloaded 0.1.0 stays on 0.1.0 forever: there is
/// no other channel that could ever tell them otherwise. Deliberately NOT an
/// updater — it never downloads, replaces, or relaunches anything; it reports a
/// version and links the release page, and the user decides. That keeps the
/// Developer-ID signing story and the "personal use, shared as-is" scope
/// intact, and it needs no privileged helper.
@MainActor
final class UpdateChecker: ObservableObject {
    /// The releases API for this app's own repository.
    nonisolated private static let latestReleaseURL = URL(
        string: "https://api.github.com/repos/SYJun404/QuickChat/releases/latest"
    )!

    /// How long a check stays good. A menu-bar app can run for weeks, so this
    /// is a real interval rather than a launch-only check.
    private static let checkInterval: TimeInterval = 24 * 60 * 60

    private static let lastCheckKey = "lastUpdateCheck"
    /// Opt-out lives in Settings › General, which owns it as `@AppStorage` like
    /// every other preference there. Read (never written) here, because the
    /// scheduled check runs outside any view. Default on: the whole point is
    /// reaching someone who will never think to look.
    static let automaticChecksKey = "automaticUpdateChecks"
    static var automaticChecksEnabled: Bool {
        UserDefaults.standard.object(forKey: automaticChecksKey) as? Bool ?? true
    }

    struct Release: Equatable, Sendable {
        var version: String
        var page: URL
    }

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        case available(Release)
        case failed(String)
    }

    @Published private(set) var state: State = .idle

    /// What this build calls itself. `CFBundleShortVersionString` is the same
    /// string `release.sh` reads to name the DMG and the `v…` tag, so the
    /// comparison below is against exactly the thing that was published.
    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// The update to point at, if any — nil while idle, checking, or current.
    var availableRelease: Release? {
        if case .available(let release) = state { return release }
        return nil
    }

    // MARK: - Checking

    /// Background check on launch and once a day after. Silent about failures:
    /// an offline laptop must not produce anything the user has to dismiss.
    func checkIfDue() {
        guard Self.automaticChecksEnabled else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date
        if let last, Date().timeIntervalSince(last) < Self.checkInterval { return }
        check(userInitiated: false)
    }

    /// The Settings button. Unlike the scheduled check this one always runs and
    /// always reports — including "you're up to date", which is the answer the
    /// user pressed the button to get.
    func check(userInitiated: Bool) {
        // `.checking` IS the in-flight flag — it is set here and reassigned on
        // every exit path, and Settings already disables its button on it.
        guard state != .checking else { return }
        state = .checking
        Task { [weak self] in
            let result = await Self.fetchLatest()
            guard let self else { return }
            switch result {
            case .success(let release):
                UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
                if let release, Self.isNewer(release.version, than: Self.currentVersion) {
                    self.state = .available(release)
                } else {
                    self.state = .upToDate
                }
            case .failure(let message):
                // A scheduled check that fails leaves no trace: it will run
                // again tomorrow, and the last thing a background poll should do
                // is put a network error in front of someone who didn't ask.
                self.state = userInitiated ? .failed(message) : .idle
            }
        }
    }

    private enum FetchResult: Sendable {
        case success(Release?)
        case failure(String)
    }

    nonisolated private static func fetchLatest() async -> FetchResult {
        var request = URLRequest(url: latestReleaseURL)
        request.timeoutInterval = 20
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("QuickChat/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return .failure("Unexpected response from GitHub.")
            }
            switch http.statusCode {
            case 200:
                return .success(decodeRelease(data))
            case 403, 429:
                return .failure("GitHub is rate-limiting update checks — try again later.")
            case 404:
                return .success(nil) // no releases published yet
            default:
                return .failure("GitHub returned HTTP \(http.statusCode).")
            }
        } catch {
            return .failure(error.localizedDescription)
        }
    }

    /// The `/releases/latest` payload. That endpoint already excludes drafts and
    /// prereleases, so there is nothing to filter here — but the flags are read
    /// anyway, because a repo can serve a prerelease as "latest" through the API
    /// if it is the only release, and offering a beta to everyone is not the job.
    nonisolated static func decodeRelease(_ data: Data) -> Release? {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = root["tag_name"] as? String,
              let page = (root["html_url"] as? String).flatMap(URL.init(string:)) else { return nil }
        if root["draft"] as? Bool == true || root["prerelease"] as? Bool == true { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard !version.isEmpty else { return nil }
        return Release(version: version, page: page)
    }

    /// Numeric component comparison, so 0.1.10 beats 0.1.9 — the string compare
    /// that "obviously works" for the first nine releases does not.
    /// Non-numeric suffixes ("0.2.0-beta.1") compare as their leading number, so
    /// a prerelease never reads as newer than the release of the same version.
    nonisolated static func isNewer(_ candidate: String, than current: String) -> Bool {
        let left = components(candidate)
        let right = components(current)
        for index in 0..<max(left.count, right.count) {
            let a = index < left.count ? left[index] : 0
            let b = index < right.count ? right[index] : 0
            if a != b { return a > b }
        }
        return false
    }

    /// Everything from the first non-numeric character is dropped BEFORE
    /// splitting, not per component: "0.2.0-beta.1" has to reduce to [0, 2, 0]
    /// and tie with 0.2.0. Trimming per component instead leaves a trailing
    /// [.., 1] from the beta counter, which outranks the real release.
    nonisolated private static func components(_ version: String) -> [Int] {
        version
            .prefix { $0.isNumber || $0 == "." }
            .split(separator: ".")
            .map { Int($0) ?? 0 }
    }
}
