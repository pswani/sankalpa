import Foundation

/// Where the Sankalpa service is running: the name of the computer, and the port it listens on.
///
/// This is a setting rather than a build constant because the answer is different for every person
/// who runs it. On the simulator the service is on the same machine, so `localhost` works. On a
/// real phone it never does — `localhost` is the phone — so the name of the Mac is the only thing
/// that can find it, and only the person holding the phone knows what that is.
public struct ServiceLocation: Equatable, Sendable {
    /// A host name, an mDNS name like `studio.local`, or an address.
    public let host: String
    public let port: Int

    public static let defaultPort = 8080
    /// What the simulator needs, and a sensible thing to show someone who has not changed it yet.
    public static let simulatorDefault = ServiceLocation(host: "localhost", port: defaultPort)

    public init(host: String, port: Int = ServiceLocation.defaultPort) {
        self.host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        self.port = port
    }

    /// Reads "studio.local", "studio.local:8080" or "http://studio.local:8080" the same way, so a
    /// person can type whichever of those they have to hand.
    ///
    /// Returns `nil` for anything that cannot name a computer, which is what stops the app from
    /// storing a setting that can only ever fail.
    public init?(text: String) {
        var remainder = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !remainder.isEmpty else { return nil }

        for scheme in ["http://", "https://"] where remainder.lowercased().hasPrefix(scheme) {
            remainder = String(remainder.dropFirst(scheme.count))
        }
        // A trailing path is not part of where the service is; the client builds its own paths.
        if let slash = remainder.firstIndex(of: "/") {
            remainder = String(remainder[remainder.startIndex..<slash])
        }

        let parts = remainder.split(separator: ":", omittingEmptySubsequences: false)
        let host: String
        var port = ServiceLocation.defaultPort
        switch parts.count {
        case 1:
            host = String(parts[0])
        case 2:
            host = String(parts[0])
            guard let parsed = Int(parts[1]), (1...65_535).contains(parsed) else { return nil }
            port = parsed
        default:
            // More than one colon is an IPv6 address, which this app has no way to ask for and
            // no reason to accept by accident.
            return nil
        }

        guard !host.isEmpty,
              host.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              // A host name is letters, digits, dots and hyphens. Anything else is a typo or a
              // paste of something that is not an address.
              host.unicodeScalars.allSatisfy({
                  CharacterSet.alphanumerics.contains($0) || $0 == "." || $0 == "-"
              })
        else { return nil }

        self.init(host: host, port: port)
    }

    public var url: URL {
        // Every component has been validated, so this cannot fail; the fallback keeps the type
        // honest without making every caller handle an impossible case.
        URL(string: "http://\(host):\(port)") ?? ServiceLocation.simulatorDefault.fallbackURL
    }

    private var fallbackURL: URL { URL(string: "http://localhost:8080")! }

    /// What the settings screen shows and the recovery screen names.
    public var displayText: String {
        port == ServiceLocation.defaultPort ? host : "\(host):\(port)"
    }
}

/// Reads and writes the service location, and says where the answer came from.
///
/// An environment variable wins over the stored setting so a UI run, or a developer with a staging
/// service, can point the app somewhere without disturbing what the person using it chose.
public struct ServiceLocationStore {
    public static let environmentKey = "SANKALPA_API_BASE_URL"
    private static let defaultsKey = "serviceLocation"

    private let defaults: UserDefaults
    private let environment: [String: String]

    public init(
        defaults: UserDefaults = .standard,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.defaults = defaults
        self.environment = environment
    }

    /// True when the environment is deciding, so the settings screen can say the field it shows is
    /// not the one in use rather than appearing to be ignored.
    public var isOverriddenByEnvironment: Bool {
        environment[ServiceLocationStore.environmentKey].flatMap(ServiceLocation.init(text:)) != nil
    }

    public var current: ServiceLocation {
        if let override = environment[ServiceLocationStore.environmentKey],
           let location = ServiceLocation(text: override) {
            return location
        }
        return stored ?? ServiceLocation.simulatorDefault
    }

    /// What the person last chose, or `nil` if they never have.
    public var stored: ServiceLocation? {
        guard let text = defaults.string(forKey: ServiceLocationStore.defaultsKey) else {
            return nil
        }
        return ServiceLocation(text: text)
    }

    public func save(_ location: ServiceLocation) {
        defaults.set(location.displayText, forKey: ServiceLocationStore.defaultsKey)
    }
}
