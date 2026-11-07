import Fluent
import FluentPostgresDriver
import Vapor

/// configures your application
func configure(_ app: Application, serving: Bool = true) async throws {
    // API setup resets middleware, so it runs before services.
    try configureAPI(app)
    try configureServices(app)
    if serving {
        app.storage[TrustedProxyCount.self] = try TrustedProxyCount.parse(Environment.get("TRUSTED_PROXY_COUNT"))
        try await checkServingDatabaseRole(on: app.db, environment: app.environment, logger: app.logger)
        _ = try WebhookEncryptionKey.load() // Fail at startup rather than on first secret use.
        try await configureAuthentication(app)
    }
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
func configureServices(_ app: Application) throws {
    let testing = app.environment == .testing
    let database = try DatabaseSettings(testing: testing, lookup: Environment.get)
    app.databases.use(.postgres(
        configuration: try database.postgresConfiguration(),
        maxConnectionsPerEventLoop: database.maxConnectionsPerEventLoop
    ), as: .psql)
    if database.tlsMode == .disable && !testing {
        app.logger.warning("Database TLS is disabled")
    }

    // Fluent clamps an oversized page. Handlers reject it first; this limit is the backstop.
    app.fluent.pagination.pageSizeLimit = 100

    app.migrations.add(CreateAuditEvent())
    app.migrations.add(CreateRevokedAccessToken())
    app.migrations.add(CreateUser())
    app.migrations.add(CreateOrganization())
    app.migrations.add(CreateOrganizationRestoration())
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
    app.migrations.add(CreateBusinessEventStream())
    app.migrations.add(CreateBusinessEvent())
    app.migrations.add(CreateBusinessEventDispatch())
    app.migrations.add(CreateWebhookSubscription())
    app.migrations.add(CreateWebhookSubscriptionRevision())
    app.migrations.add(CreateWebhookSecretReveal())
    app.migrations.add(CreateWebhookDelivery())
    app.migrations.add(CreateWebhookDeliveryEntry())

    app.asyncCommands.use(PruneRevokedTokensCommand(), as: "prune-revoked-tokens")
    app.asyncCommands.use(PlatformAdminCommand(), as: "platform-admin")
    app.asyncCommands.use(ApprovalOverrideCommand(), as: "approval-override")
    app.asyncCommands.use(AuditVerifyCommand(), as: "audit-verify")
    app.asyncCommands.use(WebhookWorkerCommand(), as: "webhook-worker")
}
