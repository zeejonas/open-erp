import Fluent
import Vapor

private struct OrganizationIDKey: StorageKey {
    typealias Value = UUID
}

extension Request {
    var organizationID: UUID {
        get {
            guard let id = self.storage[OrganizationIDKey.self] else {
                fatalError("OrganizationMiddleware must run before accessing req.organizationID")
            }
            return id
        }
        set {
            self.storage[OrganizationIDKey.self] = newValue
        }
    }
}

/// Reads `X-Organization-ID`, verifies the organization exists, and stores it on the request.
/// Stand-in until Auth0 supplies the organization from the access token.
struct OrganizationMiddleware: AsyncMiddleware {
    static let headerName = "X-Organization-ID"

    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let raw = request.headers.first(name: Self.headerName) else {
            throw Abort(.badRequest, reason: "Missing \(Self.headerName) header")
        }
        guard let organizationID = UUID(uuidString: raw) else {
            throw Abort(.badRequest, reason: "\(Self.headerName) must be a UUID")
        }

        guard try await Organization.find(organizationID, on: request.db) != nil else {
            throw Abort(.notFound, reason: "Organization not found")
        }

        request.organizationID = organizationID
        return try await next.respond(to: request)
    }
}
