import Fluent
import SQLKit
import Vapor
import VaporToOpenAPI

func routes(_ app: Application) throws {
    app.get("health") { req async throws -> [String: String] in
        // ProblemMiddleware logs these reasons and keeps the response generic.
        guard req.application.signingKeysLoaded else {
            throw Abort(.serviceUnavailable, reason: "Signing keys are not loaded")
        }
        guard let database = req.db as? any SQLDatabase else {
            throw Abort(.serviceUnavailable, reason: "Database does not support SQL")
        }
        do {
            try await database.raw("SELECT 1").run()
        } catch {
            throw Abort(.serviceUnavailable, reason: "Database probe failed: \(ProblemMiddleware.diagnostics(for: error))")
        }
        return ["status": "ok"]
    }.excludeFromOpenAPI()

    try app.register(collection: AuthController())
    try app.register(collection: MeController())
    try app.register(collection: PlatformController())
    try app.register(collection: InvitationController())
    try app.register(collection: OrganizationController())
    try app.register(collection: CompanyController())
    try app.register(collection: UserController())
    try app.register(collection: OrganizationUserController())
    try app.register(collection: ServiceAccountController())
    try app.register(collection: RoleController())
    try app.register(collection: GroupController())
    try app.register(collection: ApprovalPolicyController())
    try app.register(collection: ApprovalRequestController())
    try app.register(collection: AuditEventController())
    try app.register(collection: WebhookSubscriptionController())
    try app.register(collection: WebhookEventController())
    try app.register(collection: WebhookDeliveryController())
    registerAPIDocumentation(app)
}
