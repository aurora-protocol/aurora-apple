import Foundation

public struct AuroraConfiguration: Equatable, Sendable {
    public var endpoint: URL
    public var routePolicy: String

    public init(endpoint: URL, routePolicy: String = "balanced") {
        self.endpoint = endpoint
        self.routePolicy = routePolicy
    }

    public static func validatedEndpoint(from input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: trimmed),
              let scheme = url.scheme?.lowercased(),
              (scheme == "http" || scheme == "https"),
              let host = url.host,
              scheme == "https" || Self.isLoopbackHost(host)
        else {
            return nil
        }
        return url
    }

    private static func isLoopbackHost(_ host: String) -> Bool {
        let normalized = host.trimmingCharacters(in: CharacterSet(charactersIn: "[]")).lowercased()
        return normalized == "localhost" || normalized == "::1" || Self.isIPv4LoopbackHost(normalized)
    }

    private static func isIPv4LoopbackHost(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4, octets.first == "127" else {
            return false
        }
        return octets.allSatisfy { octet in
            !octet.isEmpty
                && octet.allSatisfy(\.isNumber)
                && Int(octet).map { (0...255).contains($0) } == true
        }
    }
}

public enum AuroraPortableProfileError: Error, Equatable, Sendable {
    case missingEquals(line: Int)
    case keyOutsideTable(String)
    case unknownTable(String)
    case unknownKey(section: String, key: String)
    case invalidBoolean(key: String)
    case invalidValue(section: String, key: String, value: String)
    case invalidEndpoint(String)
}

public struct AuroraPortableProfile: Equatable, Sendable {
    public static let appleExtensionSection = "x.aurora.apple"

    public var endpoint: URL?
    public var version: String
    public var profile: String
    public var route: String
    public var speed: String
    public var localMode: String
    public var localDNS: String
    public var allowH2: Bool
    public var allowH1WebSocket: Bool
    public var allowH3ExtendedDatagram: Bool
    public var allowMasque: Bool
    public var requirePostQuantum: Bool
    public var requireSplit2ForAdversarial: Bool
    public var allowLabTokens: Bool
    public var replayCache: String

    public init(
        endpoint: URL? = nil,
        version: String = "2.0",
        profile: String = "smart",
        route: String = "auto",
        speed: String = "balanced",
        localMode: String = "socks5",
        localDNS: String = "through-aurora",
        allowH2: Bool = true,
        allowH1WebSocket: Bool = true,
        allowH3ExtendedDatagram: Bool = false,
        allowMasque: Bool = false,
        requirePostQuantum: Bool = true,
        requireSplit2ForAdversarial: Bool = true,
        allowLabTokens: Bool = false,
        replayCache: String = "sqlite"
    ) {
        self.endpoint = endpoint
        self.version = version
        self.profile = profile
        self.route = route
        self.speed = speed
        self.localMode = localMode
        self.localDNS = localDNS
        self.allowH2 = allowH2
        self.allowH1WebSocket = allowH1WebSocket
        self.allowH3ExtendedDatagram = allowH3ExtendedDatagram
        self.allowMasque = allowMasque
        self.requirePostQuantum = requirePostQuantum
        self.requireSplit2ForAdversarial = requireSplit2ForAdversarial
        self.allowLabTokens = allowLabTokens
        self.replayCache = replayCache
    }

    public init(
        configuration: AuroraConfiguration,
        route: String = "auto",
        localMode: String = "socks5"
    ) {
        let routePolicy = configuration.routePolicy
        let exportedProfile = Self.validProfiles.contains(routePolicy) ? routePolicy : "smart"
        let exportedSpeed = routePolicy == "max" ? "max" : "balanced"
        self.init(
            endpoint: configuration.endpoint,
            profile: exportedProfile,
            route: route,
            speed: exportedSpeed,
            localMode: localMode
        )
    }

    public func configuration(defaultEndpoint: URL) -> AuroraConfiguration {
        AuroraConfiguration(
            endpoint: endpoint ?? defaultEndpoint,
            routePolicy: profile == "smart" ? speed : profile
        )
    }

    public static func parse(_ text: String) throws -> AuroraPortableProfile {
        var profile = AuroraPortableProfile()
        var section = ""
        let lines = text.components(separatedBy: .newlines)
        for (index, rawLine) in lines.enumerated() {
            let lineNumber = index + 1
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix("#") {
                continue
            }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespacesAndNewlines)
                continue
            }
            guard let equals = line.firstIndex(of: "=") else {
                throw AuroraPortableProfileError.missingEquals(line: lineNumber)
            }
            let key = line[..<equals].trimmingCharacters(in: .whitespacesAndNewlines)
            let value = Self.unquote(line[line.index(after: equals)...].trimmingCharacters(in: .whitespacesAndNewlines))
            try profile.set(section: section, key: key, value: value)
        }
        try profile.validate()
        return profile
    }

    public func tomlString() -> String {
        var lines: [String] = [
            "[aurora]",
            "version = \(Self.quote(version))",
            "profile = \(Self.quote(profile))",
            "route = \(Self.quote(route))",
            "speed = \(Self.quote(speed))",
            "",
            "[local]",
            "mode = \(Self.quote(localMode))",
            "dns = \(Self.quote(localDNS))",
            "",
            "[methods]",
            "allow_h2 = \(allowH2)",
            "allow_h1_ws = \(allowH1WebSocket)",
            "allow_h3_ext_dgram = \(allowH3ExtendedDatagram)",
            "allow_masque = \(allowMasque)",
            "",
            "[security]",
            "require_pq = \(requirePostQuantum)",
            "require_split2_for_adversarial = \(requireSplit2ForAdversarial)",
            "allow_lab_tokens = \(allowLabTokens)",
            "",
            "[storage]",
            "replay_cache = \(Self.quote(replayCache))",
        ]
        if let endpoint {
            lines.append("")
            lines.append("[\(Self.appleExtensionSection)]")
            lines.append("endpoint = \(Self.quote(endpoint.absoluteString))")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    private mutating func set(section: String, key: String, value: String) throws {
        switch section {
        case "aurora":
            switch key {
            case "version":
                version = value
            case "profile":
                profile = value
            case "route":
                route = value
            case "speed":
                speed = value
            default:
                throw AuroraPortableProfileError.unknownKey(section: section, key: key)
            }
        case "local":
            switch key {
            case "mode":
                localMode = value
            case "dns":
                localDNS = value
            default:
                throw AuroraPortableProfileError.unknownKey(section: section, key: key)
            }
        case "methods":
            switch key {
            case "allow_h2":
                allowH2 = try Self.parseBool(value, key: key)
            case "allow_h1_ws":
                allowH1WebSocket = try Self.parseBool(value, key: key)
            case "allow_h3_ext_dgram":
                allowH3ExtendedDatagram = try Self.parseBool(value, key: key)
            case "allow_masque":
                allowMasque = try Self.parseBool(value, key: key)
            default:
                throw AuroraPortableProfileError.unknownKey(section: section, key: key)
            }
        case "security":
            switch key {
            case "require_pq":
                requirePostQuantum = try Self.parseBool(value, key: key)
            case "require_split2_for_adversarial":
                requireSplit2ForAdversarial = try Self.parseBool(value, key: key)
            case "allow_lab_tokens":
                allowLabTokens = try Self.parseBool(value, key: key)
            default:
                throw AuroraPortableProfileError.unknownKey(section: section, key: key)
            }
        case "storage":
            switch key {
            case "replay_cache":
                replayCache = value
            default:
                throw AuroraPortableProfileError.unknownKey(section: section, key: key)
            }
        case Self.appleExtensionSection:
            if key == "endpoint" {
                guard let parsed = AuroraConfiguration.validatedEndpoint(from: value) else {
                    throw AuroraPortableProfileError.invalidEndpoint(value)
                }
                endpoint = parsed
            }
        default:
            if section.isEmpty {
                throw AuroraPortableProfileError.keyOutsideTable(key)
            }
            if !Self.isExtensionSection(section) {
                throw AuroraPortableProfileError.unknownTable(section)
            }
        }
    }

    private func validate() throws {
        try require(version == "2.0", section: "aurora", key: "version", value: version)
        try require(Self.validProfiles.contains(profile), section: "aurora", key: "profile", value: profile)
        try require(Self.validRoutes.contains(route), section: "aurora", key: "route", value: route)
        try require(Self.validSpeeds.contains(speed), section: "aurora", key: "speed", value: speed)
        try require(Self.validLocalModes.contains(localMode), section: "local", key: "mode", value: localMode)
        try require(localDNS == "through-aurora", section: "local", key: "dns", value: localDNS)
        try require(Self.validReplayCaches.contains(replayCache), section: "storage", key: "replay_cache", value: replayCache)
    }

    private func require(_ ok: Bool, section: String, key: String, value: String) throws {
        if !ok {
            throw AuroraPortableProfileError.invalidValue(section: section, key: key, value: value)
        }
    }

    private static func parseBool(_ value: String, key: String) throws -> Bool {
        switch value {
        case "true":
            return true
        case "false":
            return false
        default:
            throw AuroraPortableProfileError.invalidBoolean(key: key)
        }
    }

    private static func isExtensionSection(_ section: String) -> Bool {
        section.hasPrefix("x.") ||
            section.hasPrefix("ext.") ||
            section.hasPrefix("extension.") ||
            section.hasPrefix("extensions.")
    }

    private static func unquote(_ value: String) -> String {
        guard value.count >= 2, value.first == "\"", value.last == "\"" else {
            return value
        }
        return String(value.dropFirst().dropLast())
    }

    private static func quote(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }

    private static let validProfiles = [
        "smart",
        "fast-web",
        "balanced-web",
        "adversarial-dpi",
        "adversarial-dpi-strict",
        "emergency-web",
        "lab",
    ]
    private static let validRoutes = ["auto", "fast-1", "split-2", "safe-3", "bridge-split"]
    private static let validSpeeds = ["balanced", "max"]
    private static let validLocalModes = ["socks5", "http-connect", "tun", "platform-vpn"]
    private static let validReplayCaches = ["sqlite", "redis", "postgres", "memory-lab-only"]
}

public struct AuroraServerStatus: Codable, Equatable, Sendable {
    public var ready: Bool
    public var issuer: Bool
    public var cover: Bool

    public init(ready: Bool, issuer: Bool, cover: Bool) {
        self.ready = ready
        self.issuer = issuer
        self.cover = cover
    }

    public var clientReady: Bool {
        ready && issuer && cover
    }

    public var summary: String {
        clientReady ? "ready" : "unavailable"
    }
}
