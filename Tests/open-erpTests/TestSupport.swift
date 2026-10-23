@testable import open_erp
import Crypto
import Fluent
import JWT
import VaporTesting

@discardableResult
func withApp<T>(_ test: (Application) async throws -> T) async throws -> T {
    let app = try await Application.make(.testing)
    let result: T
    do {
        try await configure(app)
        try await app.autoMigrate()
        result = try await test(app)
        try await app.autoRevert()
    } catch {
        try? await app.autoRevert()
        try await app.asyncShutdown()
        throw error
    }
    try await app.asyncShutdown()
    return result
}

@discardableResult
func createOrganization(
    on db: any Database,
    code: String,
    name: String
) async throws -> Organization {
    let organization = Organization(code: code, name: name, createdBy: nil, updatedBy: nil, deletedBy: nil)
    try await organization.save(on: db)
    return organization
}

@discardableResult
func createUser(
    on db: any Database,
    firstName: String = "Ada",
    lastName: String = "Lovelace",
    email: String,
    subject: String? = nil,
    isPlatformAdmin: Bool = false
) async throws -> User {
    let user = User(
        firstName: firstName,
        lastName: lastName,
        email: email,
        authSubject: subject,
        isPlatformAdmin: isPlatformAdmin
    )
    try await user.save(on: db)
    return user
}

@discardableResult
func createMember(
    on db: any Database,
    organizationID: UUID,
    email: String,
    subject: String,
    permissions: [Permission],
    firstName: String = "Ada",
    lastName: String = "Lovelace",
    isPlatformAdmin: Bool = false
) async throws -> User {
    let user = try await createUser(
        on: db,
        firstName: firstName,
        lastName: lastName,
        email: email,
        subject: subject,
        isPlatformAdmin: isPlatformAdmin
    )
    let membership = OrganizationUser(
        organizationID: organizationID,
        userID: try user.requireID(),
        createdByID: try user.requireID()
    )
    try await membership.save(on: db)
    if !permissions.isEmpty {
        let role = Role(
            organizationID: organizationID,
            name: "permissions-\(email)",
            level: .organization,
            createdByID: try user.requireID()
        )
        try await role.save(on: db)
        for permission in permissions {
            try await RolePermission(roleID: try role.requireID(), permission: permission.rawValue).save(on: db)
        }
        let group = AccessGroup(
            organizationID: organizationID,
            name: "permissions-\(email)",
            createdByID: try user.requireID()
        )
        try await group.save(on: db)
        try await GroupRole(
            groupID: try group.requireID(),
            roleID: try role.requireID(),
            createdByID: try user.requireID()
        ).save(on: db)
        try await GroupMember(
            groupID: try group.requireID(),
            organizationUserID: try membership.requireID(),
            createdByID: try user.requireID()
        ).save(on: db)
    }
    return user
}

func signAccessToken(
    on app: Application,
    subject: String,
    issuer: String? = nil,
    audience: String? = nil,
    expiration: Date = Date().addingTimeInterval(3600),
    untrustedKey: Bool = false
) async throws -> String {
    let payload = AccessToken(
        issuer: .init(value: issuer ?? app.oidc.issuer),
        subject: .init(value: subject),
        audience: .init(value: audience ?? app.oidc.audience),
        expiration: .init(value: expiration)
    )
    if untrustedKey {
        let keys = JWTKeyCollection()
        await keys.add(ecdsa: try ES256PrivateKey(backing: P256.Signing.PrivateKey()))
        return try await keys.sign(payload)
    }
    return try await app.jwt.keys.sign(payload)
}

func authorize(_ request: inout TestingHTTPRequest, token: String, organizationID: UUID? = nil) {
    request.headers.bearerAuthorization = .init(token: token)
    if let organizationID {
        request.headers.replaceOrAdd(name: OrganizationMiddleware.headerName, value: organizationID.uuidString)
    }
}

func stubUserInfo(_ app: Application, email: String, emailVerified: Bool) {
    app.userInfoFetcher.fetch = { _ in
        UserInfo(email: email, emailVerified: emailVerified)
    }
}
