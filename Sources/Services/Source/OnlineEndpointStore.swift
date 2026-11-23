import Foundation

/// 在线图源最近一次测通的最优域名节点持久化管理
/// 消除冷启动后的多域名试错，同时支持节点失效自愈覆盖
public actor OnlineEndpointStore {
    public static let shared = OnlineEndpointStore()

    private enum Keys {
        static let jmApiBase = "keda_endpoint_jm_api_base_v1"
        static let jmImageDomain = "keda_endpoint_jm_image_domain_v1"
        static let wnacgBaseUrl = "keda_endpoint_wnacg_base_url_v1"
        static let wnacgApiBaseUrl = "keda_endpoint_wnacg_api_base_url_v1"
    }

    private var jmApiBase: String?
    private var jmImageDomain: String?
    private var wnacgBaseUrl: String?
    private var wnacgApiBaseUrl: String?
    private var healthyImageDomains: [String: String] = [:]

    private init() {
        let defaults = UserDefaults.standard
        self.jmApiBase = Self.sanitizeBaseURL(defaults.string(forKey: Keys.jmApiBase))
        self.jmImageDomain = Self.sanitizeHost(defaults.string(forKey: Keys.jmImageDomain))
        self.wnacgBaseUrl = Self.sanitizeBaseURL(defaults.string(forKey: Keys.wnacgBaseUrl))
        self.wnacgApiBaseUrl = Self.sanitizeBaseURL(defaults.string(forKey: Keys.wnacgApiBaseUrl))
    }

    public func currentJmApiBase() -> String? { jmApiBase }
    public func currentJmImageDomain() -> String? { jmImageDomain }
    public func currentWnacgBaseUrl() -> String? { wnacgBaseUrl }
    public func currentWnacgApiBaseUrl() -> String? { wnacgApiBaseUrl }

    public func updateJmApiBase(_ baseURL: String?) {
        let sanitized = Self.sanitizeBaseURL(baseURL)
        guard jmApiBase != sanitized else { return }
        jmApiBase = sanitized
        UserDefaults.standard.set(sanitized, forKey: Keys.jmApiBase)
    }

    public func updateJmImageDomain(_ host: String?) {
        let sanitized = Self.sanitizeHost(host)
        guard jmImageDomain != sanitized else { return }
        jmImageDomain = sanitized
        UserDefaults.standard.set(sanitized, forKey: Keys.jmImageDomain)
    }

    public func updateWnacgBaseUrl(_ baseURL: String?) {
        let sanitized = Self.sanitizeBaseURL(baseURL)
        guard wnacgBaseUrl != sanitized else { return }
        wnacgBaseUrl = sanitized
        UserDefaults.standard.set(sanitized, forKey: Keys.wnacgBaseUrl)
    }

    public func updateWnacgApiBaseUrl(_ baseURL: String?) {
        let sanitized = Self.sanitizeBaseURL(baseURL)
        guard wnacgApiBaseUrl != sanitized else { return }
        wnacgApiBaseUrl = sanitized
        UserDefaults.standard.set(sanitized, forKey: Keys.wnacgApiBaseUrl)
    }

    public func healthyImageDomain(for group: String) -> String? {
        healthyImageDomains[group]
    }

    public func setHealthyImageDomain(_ host: String?, for group: String) {
        let sanitized = Self.sanitizeHost(host)
        if let sanitized {
            healthyImageDomains[group] = sanitized
        } else {
            healthyImageDomains.removeValue(forKey: group)
        }
    }

    public func clearAll() {
        jmApiBase = nil
        jmImageDomain = nil
        wnacgBaseUrl = nil
        wnacgApiBaseUrl = nil
        healthyImageDomains.removeAll()
        let defaults = UserDefaults.standard
        defaults.removeObject(forKey: Keys.jmApiBase)
        defaults.removeObject(forKey: Keys.jmImageDomain)
        defaults.removeObject(forKey: Keys.wnacgBaseUrl)
        defaults.removeObject(forKey: Keys.wnacgApiBaseUrl)
    }

    public static func sanitizeBaseURL(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while trimmed.hasSuffix("/") { trimmed.removeLast() }
        guard !trimmed.isEmpty,
              let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              (scheme == "https" || scheme == "http"),
              let host = components.host,
              !host.isEmpty else {
            return nil
        }
        if let port = components.port {
            return "\(scheme)://\(host):\(port)"
        }
        return "\(scheme)://\(host)"
    }

    public static func sanitizeHost(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var cleaned = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if cleaned.lowercased().hasPrefix("https://") {
            cleaned = String(cleaned.dropFirst(8))
        } else if cleaned.lowercased().hasPrefix("http://") {
            cleaned = String(cleaned.dropFirst(7))
        }
        while cleaned.hasSuffix("/") { cleaned.removeLast() }
        guard !cleaned.isEmpty,
              !cleaned.contains("/"),
              cleaned.rangeOfCharacter(from: .whitespacesAndNewlines) == nil,
              let comps = URLComponents(string: "https://\(cleaned)"),
              let host = comps.host,
              !host.isEmpty else {
            return nil
        }
        return cleaned
    }
}
