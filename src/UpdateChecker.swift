import Foundation

// UpdateChecker
// -------------
// Once a day, asks GitHub for the version number of the newest Verbaline (the Info.plist on the main branch) and
// says so when it's newer than the one running. It only reads that one public file: nothing about you or your
// dictation is sent. GitHub sees the request like any web page visit. Turn it off with "Check for Updates Daily".
//
// Updating is one command (scripts/install.sh): it downloads, builds and installs the newest version, then cleans up.
//
//     UpdateChecker.isNewer("0.3", than: "0.2")   compare version numbers ("1.10" is newer than "1.9")
//     start(onChange:)                            check now if a day has passed, then every few hours
//     checkNow(completion:)                       check regardless of the daily limit (the menu's "Check for Updates…")
//     available                                   the newer version found, if any
//     installCommand / aiPrompt                   what the update notice lets you copy

final class UpdateChecker {
    static let versionURL = URL(string: "https://raw.githubusercontent.com/JLFinance25/Verbaline/main/Info.plist")!
    static let installCommand =
        #"/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/JLFinance25/Verbaline/main/scripts/install.sh)""#
    static let aiPrompt = """
        Please update Verbaline (the dictation app on my Mac) to the newest version. Run this command in Terminal, \
        explain in plain English what it's doing, and tell me if anything fails:
        \(installCommand)
        """

    static var current: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    /// True when `a` is a higher version than `b`, comparing each dot-separated number ("1.10" > "1.9").
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: .whitespaces).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    private let defaults = UserDefaults.standard
    var enabled: Bool {
        get { defaults.object(forKey: "checkForUpdates") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "checkForUpdates"); if newValue { checkIfDue() } }
    }
    /// The newest version GitHub reported, remembered so the notice stays up after a restart.
    private var latestSeen: String? {
        get { defaults.string(forKey: "updateLatestSeen") }
        set { defaults.set(newValue, forKey: "updateLatestSeen") }
    }
    private var lastCheck: Date? {
        get { defaults.object(forKey: "updateLastCheck") as? Date }
        set { defaults.set(newValue, forKey: "updateLastCheck") }
    }

    var available: String? {
        guard enabled, let v = latestSeen, Self.isNewer(v, than: Self.current) else { return nil }
        return v
    }

    private var timer: Timer?
    private var onChange: () -> Void = {}

    func start(onChange: @escaping () -> Void) {
        self.onChange = onChange
        // Not at the very first second of launch: the speech model is loading then.
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in self?.checkIfDue() }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in self?.checkIfDue() }
    }

    private func checkIfDue() {
        guard enabled else { return }
        if let last = lastCheck, Date().timeIntervalSince(last) < 24 * 3600 { return }
        checkNow { _ in }
    }

    /// Fetches the newest version number. `completion` (main thread) gets it, or nil if GitHub couldn't be reached.
    func checkNow(completion: @escaping (String?) -> Void) {
        let config = URLSessionConfiguration.ephemeral          // no cookies or cache kept
        config.timeoutIntervalForRequest = 15
        var request = URLRequest(url: Self.versionURL)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        URLSession(configuration: config).dataTask(with: request) { [weak self] data, response, _ in
            let ok = (response as? HTTPURLResponse)?.statusCode == 200
            let plist = ok ? data.flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) } : nil
            let version = (plist as? [String: Any])?["CFBundleShortVersionString"] as? String
            DispatchQueue.main.async {
                if let self, let version {
                    self.lastCheck = Date()
                    self.latestSeen = version
                    self.onChange()
                }
                completion(version)
            }
        }.resume()
    }
}
