import NIOSSL
import Fluent
import FluentPostgresDriver
import Vapor

/// configures your application
func configure(_ app: Application) async throws {
    configureProblemMiddleware(app)
    // uncomment to serve files from /Public folder
    // app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))

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
    app.asyncCommands.use(PlatformAdminCommand(), as: "platform-admin")
    app.asyncCommands.use(ApprovalOverrideCommand(), as: "approval-override")

    // register routes
    try routes(app)
}
