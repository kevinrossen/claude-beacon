import Foundation

private func nonEmpty(_ s: String?) -> String? {
    guard let s, !s.isEmpty else { return nil }
    return s
}

struct BeaconSession: Decodable, Identifiable {
    let session_id: String
    let host: String
    let project: String
    let state: String          // working | needs_input | done
    let label: String?         // where it runs (tmux session name)
    let title: String?         // what it is (/rename name or Claude's auto title)
    let acked: Bool?
    let age: Int?
    let updated: Double?

    var id: String { session_id }
    var isAcked: Bool { acked ?? false }
    var isAsking: Bool { state == "needs_input" }
    var isIdle: Bool { state == "done" }
    var isWorking: Bool { state == "working" }
    /// Idle or asking, and not yet marked seen.
    var isFresh: Bool { (isAsking || isIdle) && !isAcked }
    /// Long name: what the session is.
    var name: String { nonEmpty(title) ?? nonEmpty(label) ?? project }
    /// Short name: where it runs.
    var short: String { nonEmpty(label) ?? nonEmpty(title) ?? project }
    /// Seconds since the last change. SSE only pushes on change, so compute from `updated`.
    var ageNow: Int {
        if let updated { return max(0, Int(Date().timeIntervalSince1970 - updated)) }
        return age ?? 0
    }
}

struct BeaconState: Decodable {
    let waiting: Int
    let sessions: [BeaconSession]
    static let empty = BeaconState(waiting: 0, sessions: [])

    var asking: [BeaconSession] { sessions.filter(\.isAsking) }
    var idle: [BeaconSession] { sessions.filter(\.isIdle) }
    var working: [BeaconSession] { sessions.filter(\.isWorking) }
}

// MARK: - Layouts and settings (same keys and values as the Windows client)

enum Slot { case attention, asking, idle, work }

struct Layout {
    let key: String
    let label: String
    let slots: [Slot]

    static let all: [Layout] = [
        Layout(key: "needs-you+working", label: "Needs you + Working", slots: [.attention, .work]),
        Layout(key: "asking+idle+working", label: "Asking + Idle + Working", slots: [.asking, .idle, .work]),
        Layout(key: "asking+working", label: "Asking + Working", slots: [.asking, .work]),
        Layout(key: "needs-you", label: "Needs you only", slots: [.attention]),
        Layout(key: "asking", label: "Asking only", slots: [.asking]),
    ]
    static func find(_ key: String) -> Layout { all.first { $0.key == key } ?? all[0] }
}

let notifyModes: [(key: String, label: String)] = [
    ("all", "When a session finishes or asks you"),
    ("asking", "Only when a session asks you"),
    ("off", "Off"),
]

struct BeaconSettings {
    var layout = "needs-you+working"
    var notify = "all"
    var hideEmpty = false
    var notch = true            // Mac only: the light beside the notch when a session asks you
}

/// ~/.config/claude-beacon/client.json: url + token, plus settings this app writes back.
/// Unknown keys are preserved.
final class ConfigStore {
    static let path = NSString(string: "~/.config/claude-beacon/client.json").expandingTildeInPath
    private var raw: [String: Any] = [:]
    var settings = BeaconSettings()

    var url: String {
        var u = (raw["url"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        while u.hasSuffix("/") { u.removeLast() }
        return u
    }
    var token: String { (raw["token"] as? String ?? "").trimmingCharacters(in: .whitespaces) }

    init?() {
        guard let data = FileManager.default.contents(atPath: Self.path),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return nil }
        raw = obj
        if let v = obj["layout"] as? String, Layout.all.contains(where: { $0.key == v }) { settings.layout = v }
        if let v = obj["notify"] as? String, notifyModes.contains(where: { $0.key == v }) { settings.notify = v }
        if let v = obj["hideEmpty"] as? Bool { settings.hideEmpty = v }
        if let v = obj["notch"] as? Bool { settings.notch = v }
        if url.isEmpty || token.isEmpty { return nil }
    }

    func save() {
        raw["layout"] = settings.layout
        raw["notify"] = settings.notify
        raw["hideEmpty"] = settings.hideEmpty
        raw["notch"] = settings.notch
        if let data = try? JSONSerialization.data(withJSONObject: raw, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: Self.path), options: .atomic)
        }
    }
}

// MARK: - Client

/// Subscribes to the beacon's SSE stream and reconnects with backoff.
final class BeaconClient {
    var onState: ((BeaconState) -> Void)?
    var onConnection: ((Bool) -> Void)?
    private let baseURL: String
    private let token: String
    private var task: Task<Void, Never>?

    init(url: String, token: String) {
        baseURL = url
        self.token = token
    }

    /// Mark one session seen, or every idle/asking session when `sessionId` is nil.
    /// The beacon pushes the new state back over SSE.
    func acknowledge(_ sessionId: String? = nil) {
        guard let url = URL(string: baseURL + "/ack") else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = sessionId.map { ["session_id": $0] } ?? [:]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        URLSession.shared.dataTask(with: req).resume()
    }

    func start() {
        let baseURL = self.baseURL, token = self.token
        task = Task {
            var delay: UInt64 = 1
            while !Task.isCancelled {
                do {
                    guard let url = URL(string: baseURL + "/events") else { throw URLError(.badURL) }
                    var req = URLRequest(url: url)
                    req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                    req.timeoutInterval = 45  // server sends a keepalive every 15s
                    let (bytes, resp) = try await URLSession.shared.bytes(for: req)
                    guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw URLError(.badServerResponse) }
                    await MainActor.run { self.onConnection?(true) }
                    delay = 1
                    for try await line in bytes.lines where line.hasPrefix("data: ") {
                        let json = Data(line.dropFirst(6).utf8)
                        if let state = try? JSONDecoder().decode(BeaconState.self, from: json) {
                            await MainActor.run { self.onState?(state) }
                        }
                    }
                } catch {}
                await MainActor.run { self.onConnection?(false) }
                try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
                delay = min(delay * 2, 30)
            }
        }
    }
}
