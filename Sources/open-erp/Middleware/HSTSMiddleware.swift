import Vapor

/// Sent whatever the request scheme: RFC 6797 §8.1 has browsers ignore it over plain HTTP,
/// so the app needs no trusted `X-Forwarded-Proto` to decide.
struct HSTSMiddleware: AsyncMiddleware {
    let maxAge: Int

    /// Returns nil when the header is off: `HSTS_MAX_AGE_SECONDS=0`, or unset in testing.
    static func configured(testing: Bool, lookup: (String) -> String?) throws -> HSTSMiddleware? {
        let name = "HSTS_MAX_AGE_SECONDS"
        guard let raw = lookup(name) else { return testing ? nil : HSTSMiddleware(maxAge: 31_536_000) }
        guard !raw.isEmpty, raw.utf8.allSatisfy({ (48...57).contains($0) }), let maxAge = Int(raw) else {
            throw DatabaseSettings.InvalidValue(name: name)
        }
        return maxAge == 0 ? nil : HSTSMiddleware(maxAge: maxAge)
    }

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        response.headers.replaceOrAdd(name: .strictTransportSecurity, value: "max-age=\(maxAge)")
        return response
    }
}
