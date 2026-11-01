import Foundation

/// The list of models a local server offers, for choosing one in Settings → AI
/// instead of typing its name. Foundation only, so what is asked and what is
/// accepted back are checked off a Mac.
///
/// Only a server on this Mac is asked, and it is asked for nothing but the
/// list, with no key: the address is the base URL's `/models`, and only when
/// that is `http` or `https` on `localhost`, `127.0.0.1` or `::1`, with no
/// login in it. Whatever comes back is names to show, nothing more.
enum LocalModels {
    static let maxModels = 200
    static let maxNameLength = 200
    /// More than a list of models ever is.
    static let maxResponseBytes = 2_000_000

    /// `{base}/models` for a base URL on this Mac, or nil for anything else.
    static func listURL(baseURL: String) -> URL? {
        let trimmed = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        guard var components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(), scheme == "http" || scheme == "https",
              let host = components.host?.trimmingCharacters(in: CharacterSet(charactersIn: "[]")),
              AssistantDestination.isLoopback(host: host),
              components.user == nil, components.password == nil else { return nil }
        var path = components.path
        while path.hasSuffix("/") { path.removeLast() }
        components.path = path + "/models"
        components.query = nil
        components.fragment = nil
        return components.url
    }

    /// The model names in a reply, in the shape OpenAI-compatible servers and
    /// Ollama use (`{"data": [{"id": …}]}` and `{"models": [{"name": …}]}`),
    /// sorted, once each. A name that is empty, too long or has a control
    /// character in it is left out, and so is everything past `maxModels`.
    static func parse(_ data: Data) -> [String] {
        guard data.count <= maxResponseBytes,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [] }
        var names: [String] = []
        if let entries = object["data"] as? [[String: Any]] {
            names += entries.compactMap { $0["id"] as? String }
        }
        if let entries = object["models"] as? [[String: Any]] {
            names += entries.compactMap { ($0["name"] as? String) ?? ($0["model"] as? String) }
        }
        var seen = Set<String>()
        let clean = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { name in
            !name.isEmpty && name.count <= maxNameLength
                && !name.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F }
                && seen.insert(name).inserted
        }
        let sorted = clean.sorted { lhs, rhs in
            let (a, b) = (lhs.lowercased(), rhs.lowercased())
            return a == b ? lhs < rhs : a < b
        }
        return Array(sorted.prefix(maxModels))
    }
}
