import Fluent
import FluentSQL
import Foundation
import Vapor
import VaporToOpenAPI

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

struct ListSort: Decodable, Validatable {
    var sort: String?

    static func validations(_ validations: inout Validations) {
        validations.add("sort", as: String.self, is: !.empty, required: false)
    }
}

/// What one list endpoint can sort by. Parsing, errors, and published documentation all derive from this.
struct ListSortOrder<Row: Model>: Sendable {
    typealias Field = @Sendable (QueryBuilder<Row>, DatabaseQuery.Sort.Direction) -> Void
    typealias TieBreak = @Sendable (QueryBuilder<Row>) -> Void

    private let fields: [String: Field]
    private let defaultSort: String
    private let tieBreak: TieBreak

    /// `default` uses the same grammar as the request parameter. An invalid default stops the app at boot.
    init(
        fields: [String: Field],
        default defaultSort: String,
        tieBreak: @escaping TieBreak = { $0.sort(FieldKey.id, .ascending) }
    ) {
        self.fields = fields
        self.defaultSort = defaultSort
        self.tieBreak = tieBreak
        precondition((try? parse(defaultSort)) != nil, "Invalid default sort \(defaultSort)")
    }

    var fieldNames: [String] { fields.keys.sorted() }

    /// Matches the grammar, except that a pattern cannot require distinct fields.
    var pattern: String {
        let field = "-?(\(fieldNames.joined(separator: "|")))"
        return "^\(field)(,\(field))*$"
    }

    var openAPIParameter: OpenAPIParameters {
        ["sort": .string(pattern: pattern)]
    }

    var documentation: String {
        "Optional sort is a comma-separated list of distinct fields (\(fieldNames.joined(separator: ", "))), highest priority first. Fields sort ascending unless prefixed with - for descending. Defaults to \(defaultSort)."
    }

    fileprivate func parse(_ sort: String?) throws -> ListSortTerms<Row> {
        var seen: Set<String> = []
        var terms: [ListSortTerms<Row>.Term] = []
        for term in (sort ?? defaultSort).split(separator: ",", omittingEmptySubsequences: false) {
            let descending = term.hasPrefix("-")
            let name = String(descending ? term.dropFirst() : term)
            guard !name.isEmpty else {
                throw Abort(.badRequest, reason: "Empty field in sort")
            }
            guard let field = fields[name] else {
                throw Abort(.badRequest, reason: "Invalid sort field \(name). Allowed: \(fieldNames.joined(separator: ", "))")
            }
            guard seen.insert(name).inserted else {
                throw Abort(.badRequest, reason: "Repeated sort field \(name)")
            }
            terms.append(.init(field: field, direction: descending ? .descending : .ascending))
        }
        return ListSortTerms(terms: terms, tieBreak: tieBreak)
    }
}

/// A validated sort, ready to apply to a query.
struct ListSortTerms<Row: Model> {
    fileprivate struct Term {
        let field: ListSortOrder<Row>.Field
        let direction: DatabaseQuery.Sort.Direction
    }

    fileprivate let terms: [Term]
    fileprivate let tieBreak: ListSortOrder<Row>.TieBreak
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

struct PlatformOrganizationListFilters: ListFilters {
    static let keys: Set<String> = ["code", "name", "onboarded", "deleted"]
    var code: String?
    var name: String?
    var onboarded: Bool?
    var deleted: Bool?

    static func validations(_ validations: inout Validations) {
        validations.add("code", as: String.self, is: !.empty, required: false)
        validations.add("name", as: String.self, is: !.empty, required: false)
        validations.add("onboarded", as: Bool.self, required: false)
        validations.add("deleted", as: Bool.self, required: false)
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

struct PermissionListFilters: ListFilters {
    static let keys: Set<String> = ["level"]
    var level: RoleLevel?

    static func validations(_ validations: inout Validations) {
        validations.add("level", as: String.self, is: .case(of: RoleLevel.self), required: false)
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
        try listParameters(filters, additionalKeys: [])
    }

    /// Also validates and parses `sort` against the endpoint's declared order.
    func listParameters<Filters: ListFilters, Row: Model>(
        _ filters: Filters.Type,
        sort order: ListSortOrder<Row>
    ) throws -> (Filters, PageRequest, ListSortTerms<Row>) {
        let (filters, page) = try listParameters(filters, additionalKeys: ["sort"])
        try ListSort.validate(query: self)
        return (filters, page, try order.parse(query.decode(ListSort.self).sort))
    }

    private func listParameters<Filters: ListFilters>(
        _ filters: Filters.Type,
        additionalKeys: Set<String>
    ) throws -> (Filters, PageRequest) {
        let allowed = filters.keys.union(["page", "per"]).union(additionalKeys)
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
    /// Applies the terms in precedence order, then the tie-break.
    @discardableResult
    func sorted(by order: ListSortTerms<Model>) -> Self {
        for term in order.terms {
            term.field(self, term.direction)
        }
        order.tieBreak(self)
        return self
    }

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
