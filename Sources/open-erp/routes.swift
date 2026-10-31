import Fluent
import Vapor
import VaporToOpenAPI

func routes(_ app: Application) throws {
    app.get { req async in
        "It works!"
    }.excludeFromOpenAPI()

    app.get("hello") { req async -> String in
        "Hello, world!"
    }.excludeFromOpenAPI()

    try app.register(collection: AuthController())
    try app.register(collection: MeController())
    try app.register(collection: PlatformController())
    try app.register(collection: InvitationController())
    try app.register(collection: OrganizationController())
    try app.register(collection: CompanyController())
    try app.register(collection: UserController())
    try app.register(collection: OrganizationUserController())
    try app.register(collection: RoleController())
    try app.register(collection: GroupController())
    try app.register(collection: ApprovalPolicyController())
    try app.register(collection: ApprovalRequestController())
    registerAPIDocumentation(app)
}
