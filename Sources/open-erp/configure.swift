import NIOSSL
import Fluent
import FluentPostgresDriver
import Vapor

/// configures your application
func configure(_ app: Application) async throws {
    // API setup resets middleware, so it runs before services.
    try configureAPI(app)
    try await configureServices(app)
}

/// Registers the HTTP contract without runtime services or credentials.
func configureAPI(_ app: Application) throws {
    configureProblemMiddleware(app)
    // Wrap error handling so generated failures receive the same cache policy.
    app.middleware.use(NoStoreMiddleware(), at: .beginning)
    try routes(app)
    app.asyncCommands.use(ExportOpenAPICommand(), as: "export-openapi")
}

/// Configures dependencies required by serving and operational commands.
func configureServices(_ app: Application) async throws {
    app.databases.use(DatabaseConfigurationFactory.postgres(configuration: .init(
        hostname: Environment.get("DATABASE_HOST") ?? "localhost",
        port: Environment.get("DATABASE_PORT").flatMap(Int.init(_:)) ?? SQLPostgresConfiguration.ianaPortNumber,
        username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
        password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
        database: Environment.get("DATABASE_NAME") ?? "vapor_database",
        tls: .prefer(try .init(configuration: .clientDefault)))
    ), as: .psql)

    // Fluent clamps an oversized page. Handlers reject it first; this limit is the backstop.
    app.fluent.pagination.pageSizeLimit = 100

    app.migrations.add(CreateRevokedAccessToken())
    app.migrations.add(CreateUser())
    app.migrations.add(CreateOrganization())
    app.migrations.add(CreateCompany())
    app.migrations.add(CreateOrganizationUser())
    app.migrations.add(CreateCompanyUser())
    app.migrations.add(CreateRole())
    app.migrations.add(CreateRolePermission())
    app.migrations.add(CreateGroup())
    app.migrations.add(CreateGroupMember())
    app.migrations.add(CreateGroupRole())
    app.migrations.add(CreateGroupCompany())
    app.migrations.add(CreateApprovalPolicy())
    app.migrations.add(CreateApprovalPolicySlot())
    app.migrations.add(CreateApprovalPolicyVersion())
    app.migrations.add(CreateApprovalRequest())
    app.migrations.add(CreateApprovalRequestTrack())
    app.migrations.add(CreateApprovalDecision())
    app.migrations.add(CreateOrganizationInvitation())

    try await configureAuthentication(app)
    app.asyncCommands.use(PruneRevokedTokensCommand(), as: "prune-revoked-tokens")
    app.asyncCommands.use(PlatformAdminCommand(), as: "platform-admin")
    app.asyncCommands.use(ApprovalOverrideCommand(), as: "approval-override")
}
