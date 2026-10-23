import Fluent
import FluentSQL
import Foundation
import Vapor

/// `page` and `per` for every list. Out-of-range values fail validation instead of being clamped.
struct ListPage: Decodable, Validatable {
    var page: Int?
    var per: Int?

    static func validations(_ validations: inout Validations) {
        validations.add("page", as: Int.self, is: .range(1...), required: false)
        validations.add("per", as: Int.self, is: .range(1...100), required: false)
    }

    var request: PageRequest {
        PageRequest(page: page ?? 1, per: per ?? 25)
    }
}

protocol ListFilters: Decodable, Validatable {
    static var keys: Set<String> { get }
}

struct NoFilters: ListFilters {
    static let keys: Set<String> = []

    static func validations(_ validations: inout Validations) {}
}

struct CompanyListFilters: ListFilters {
    static let keys: Set<String> = ["code", "name"]
    var code: String?
    var name: String?

    static func validations(_ validations: inout Validations) {
        validations.add("code", as: String.self, is: !.empty, required: false)
        validations.add("name", as: String.self, is: !.empty, required: false)
    }
}

struct UserListFilters: ListFilters {
    static let keys: Set<String> = ["firstName", "lastName", "email", "groupId"]
    var firstName: String?
    var lastName: String?
    var email: String?
    var groupId: UUID?

    static func validations(_ validations: inout Validations) {
        validations.add("firstName", as: String.self, is: !.empty, required: false)
        validations.add("lastName", as: String.self, is: !.empty, required: false)
        validations.add("email", as: String.self, is: !.empty, required: false)
        validations.add("groupId", as: UUID.self, required: false)
    }
}

struct RoleListFilters: ListFilters {
    static let keys: Set<String> = ["name", "level"]
    var name: String?
    var level: RoleLevel?

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty, required: false)
        validations.add("level", as: String.self, is: .case(of: RoleLevel.self), required: false)
    }
}

struct GroupListFilters: ListFilters {
    static let keys: Set<String> = ["name", "roleId", "companyId"]
    var name: String?
    var roleId: UUID?
    var companyId: UUID?

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty, required: false)
        validations.add("roleId", as: UUID.self, required: false)
        validations.add("companyId", as: UUID.self, required: false)
    }
}

struct ApprovalPolicyListFilters: ListFilters {
    static let keys: Set<String> = ["name", "permission", "groupId", "companyId"]
    var name: String?
    var permission: String?
    var groupId: UUID?
    var companyId: UUID?

    static func validations(_ validations: inout Validations) {
        validations.add("name", as: String.self, is: !.empty, required: false)
        validations.add("permission", as: String.self, is: !.empty, required: false)
        validations.add("groupId", as: UUID.self, required: false)
        validations.add("companyId", as: UUID.self, required: false)
    }
}

struct ApprovalRequestListFilters: ListFilters {
    static let keys: Set<String> = ["status", "permission", "requestedBy"]
    var status: ApprovalRequestStatus?
    var permission: String?
    var requestedBy: UUID?

    static func validations(_ validations: inout Validations) {
        validations.add("status", as: String.self, is: .case(of: ApprovalRequestStatus.self), required: false)
        validations.add("permission", as: String.self, is: !.empty, required: false)
        validations.add("requestedBy", as: UUID.self, required: false)
    }
}

struct InvitationListFilters: ListFilters {
    static let keys: Set<String> = ["email", "groupId"]
    var email: String?
    var groupId: UUID?

    static func validations(_ validations: inout Validations) {
        validations.add("email", as: String.self, is: !.empty, required: false)
        validations.add("groupId", as: UUID.self, required: false)
    }
}

extension Request {
    /// Rejects undeclared or repeated query keys, then validates and decodes paging and filters.
    func listParameters<Filters: ListFilters>(_ filters: Filters.Type) throws -> (Filters, PageRequest) {
        let allowed = filters.keys.union(["page", "per"])
        var seen: Set<String> = []
        for name in try queryParameterNames() {
            guard allowed.contains(name) else {
                throw Abort(.badRequest, reason: "Unknown parameter \(name)")
            }
            guard seen.insert(name).inserted else {
                throw Abort(.badRequest, reason: "Repeated parameter \(name)")
            }
        }
        try ListPage.validate(query: self)
        try Filters.validate(query: self)
        let page = try query.decode(ListPage.self)
        return (try query.decode(Filters.self), page.request)
    }

    private func queryParameterNames() throws -> [String] {
        guard let query = url.query, !query.isEmpty else {
            return []
        }
        var components = URLComponents()
        components.percentEncodedQuery = query
        guard let items = components.queryItems else {
            throw Abort(.badRequest, reason: "Invalid query")
        }
        return items.map(\.name)
    }
}

extension QueryBuilder {
    /// Newest first by the given timestamp, then `id`, so a tie still has one order.
    @discardableResult
    func newestFirst<Field>(
        _ timestamp: KeyPath<Model, Field>
    ) -> Self
        where Field: QueryableProperty, Field.Model == Model
    {
        sort(timestamp, .descending).sort(FieldKey.id, .ascending)
    }

    /// Newest first by a joined model's timestamp, then that model's `id`.
    @discardableResult
    func newestFirst<Joined, Field>(
        _ joined: Joined.Type,
        _ timestamp: KeyPath<Joined, Field>
    ) -> Self
        where Joined: Schema, Field: QueryableProperty, Field.Model == Joined
    {
        sort(Joined.self, timestamp, .descending).sort(Joined.self, FieldKey.id, .ascending)
    }

    /// Case-insensitive substring match. `%`, `_`, and `\` in the value match literally. `nil` adds no filter.
    @discardableResult
    func filter<Field>(
        _ field: KeyPath<Model, Field>,
        contains value: String?
    ) -> Self
        where Field: QueryableProperty, Field.Model == Model, Field.Value == String
    {
        guard let value else { return self }
        let column = Model.path(for: field).map(\.description).joined()
        let pattern = "%\(escapeLike(value))%"
        return filter(.sql(embed: """
            \(ident: Model.schema).\(ident: column) ILIKE \(bind: pattern) ESCAPE \(literal: "\\")
            """))
    }
}

private func escapeLike(_ value: String) -> String {
    value
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
}
