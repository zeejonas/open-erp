import Foundation

struct WebhookWorkerSettings: Sendable {
    let concurrency: Int
    let perOrganization: Int
    let perSubscription: Int
    let pollIntervalMilliseconds: Int

    struct InvalidValue: Error, CustomStringConvertible {
        let name: String
        var description: String { "Invalid \(name)" }
    }

    init(lookup: (String) -> String?) throws {
        func positive(_ name: String, default value: Int) throws -> Int {
            guard let raw = lookup(name) else { return value }
            guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let value = Int(raw), value > 0 else {
                throw InvalidValue(name: name)
            }
            return value
        }
        concurrency = try positive("WEBHOOK_WORKER_CONCURRENCY", default: 16)
        perOrganization = try positive("WEBHOOK_MAX_IN_FLIGHT_PER_ORGANIZATION", default: 8)
        perSubscription = try positive("WEBHOOK_MAX_IN_FLIGHT_PER_SUBSCRIPTION", default: 4)
        pollIntervalMilliseconds = try positive("WEBHOOK_POLL_INTERVAL_MS", default: 1000)
        guard perSubscription <= perOrganization else {
            throw InvalidValue(name: "WEBHOOK_MAX_IN_FLIGHT_PER_SUBSCRIPTION / WEBHOOK_MAX_IN_FLIGHT_PER_ORGANIZATION")
        }
    }
}

enum WebhookRetryPolicy {
    static let window: TimeInterval = 72 * 60 * 60
    static let lease: TimeInterval = 60

    static func outcome(status: Int?) -> WebhookAttemptOutcome {
        guard let status else { return .retryable }
        if (200...299).contains(status) { return .acknowledged }
        if [408, 425, 429].contains(status) || (500...599).contains(status) { return .retryable }
        return .exhausted
    }

    /// Returns nil once the next attempt would fall at or past the window, so every scheduled attempt is sent.
    static func nextAttempt(count: Int, firstAttempt: Date, now: Date, status: Int?, retryAfter: String?, jitter: Double) -> Date? {
        let deadline = firstAttempt.addingTimeInterval(window)
        let cap = min(21_600, 5 * pow(2, Double(min(max(count - 1, 0), 13))))
        var delay = cap * min(max(jitter, 0), 1)
        if status == 429 || status == 503, let retryAfter {
            let seconds: TimeInterval?
            if !retryAfter.isEmpty && retryAfter.utf8.allSatisfy({ (48...57).contains($0) }) {
                seconds = TimeInterval(retryAfter)
            } else {
                let formatter = DateFormatter()
                formatter.locale = Locale(identifier: "en_US_POSIX")
                formatter.timeZone = TimeZone(secondsFromGMT: 0)
                formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
                seconds = formatter.date(from: retryAfter)?.timeIntervalSince(now)
            }
            if let seconds, seconds.isFinite, seconds > 0 { delay = max(delay, seconds) }
        }
        let next = now.addingTimeInterval(delay)
        return next < deadline ? next : nil
    }
}
