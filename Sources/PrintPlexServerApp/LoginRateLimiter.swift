import Vapor

/// Brute-force guard for the login form: after `maxFailures` wrong attempts
/// from the same client within `window`, further attempts are refused until
/// the oldest one ages out. Per client (not global) so someone hammering the
/// endpoint can't lock the real admin out; in memory, so a restart clears it.
actor LoginRateLimiter {
    private let maxFailures = 5
    private let window: TimeInterval = 15 * 60
    private var failures: [String: [Date]] = [:]

    /// Seconds the caller must wait before retrying, or nil if allowed.
    func retryAfter(for key: String, now: Date = Date()) -> Int? {
        let recent = (failures[key] ?? []).filter { now.timeIntervalSince($0) < window }
        failures[key] = recent.isEmpty ? nil : recent
        guard recent.count >= maxFailures, let oldest = recent.first else { return nil }
        return max(1, Int(window - now.timeIntervalSince(oldest)))
    }

    func recordFailure(for key: String, now: Date = Date()) {
        failures[key, default: []].append(now)
    }

    func reset(for key: String) {
        failures[key] = nil
    }
}

extension Request {
    /// Behind a reverse proxy every request comes from the proxy's own
    /// address, so the real client is in X-Forwarded-For. Only the LAST entry
    /// is trusted: that's the one the proxy appended itself — earlier ones are
    /// whatever the client chose to send.
    var clientKey: String {
        if let forwarded = headers.first(name: "X-Forwarded-For"),
           let last = forwarded.split(separator: ",").last {
            return last.trimmingCharacters(in: .whitespaces)
        }
        return remoteAddress?.ipAddress ?? "unknown"
    }
}

struct LoginRateLimiterKey: StorageKey {
    typealias Value = LoginRateLimiter
}

extension Application {
    var loginRateLimiter: LoginRateLimiter {
        if let existing = storage[LoginRateLimiterKey.self] { return existing }
        let created = LoginRateLimiter()
        storage[LoginRateLimiterKey.self] = created
        return created
    }
}
