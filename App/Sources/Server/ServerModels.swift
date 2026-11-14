import Foundation

/// A saved CloudXR server (a PC or the office VM) reached by IP address / hostname on the local
/// network. The port is fixed by CloudXR, so it is not stored.
struct StreamServer: Codable, Identifiable, Hashable {
    var id: UUID = UUID()
    var name: String
    var host: String
}

/// Streaming resolution preset (maps to CloudXRKit's `ResolutionPreset` in ServerSessionController).
enum StreamQuality: String, Codable, CaseIterable, Identifiable {
    case standard
    case performance

    var id: String { rawValue }

    var title: String {
        switch self {
        case .standard: return "Standard"
        case .performance: return "Performance"
        }
    }

    /// One-line explanation shown under the picker.
    var detail: String {
        switch self {
        case .standard: return "Best image quality."
        case .performance: return "Lower resolution, lower latency."
        }
    }
}

/// Validation of the address typed for a server: an IPv4 address or an RFC 1123 hostname
/// (e.g. "192.168.0.87", "my-pc", "my-pc.local", "render01.office.lan").
enum StreamHostValidator {
    /// Trims whitespace and a trailing dot; lowercases hostnames.
    static func normalized(_ raw: String) -> String {
        var host = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if host.hasSuffix(".") { host.removeLast() }
        return isIPv4(host) ? host : host.lowercased()
    }

    static func isValid(_ raw: String) -> Bool {
        let host = normalized(raw)
        guard !host.isEmpty else { return false }
        // Only digits and dots: it has to be a complete IPv4 address ("192.168.0" is a typo, not a name).
        if host.allSatisfy({ $0.isASCII && ($0.isNumber || $0 == ".") }) {
            return isIPv4(host)
        }
        return isHostname(host)
    }

    static func isIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4 else { return false }
        for part in parts {
            guard !part.isEmpty, part.count <= 3,
                  part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(part), value <= 255 else { return false }
        }
        return true
    }

    static func isHostname(_ host: String) -> Bool {
        guard host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        guard !labels.isEmpty else { return false }
        for label in labels {
            guard !label.isEmpty, label.count <= 63,
                  label.first != "-", label.last != "-",
                  label.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return false }
        }
        return true
    }
}
