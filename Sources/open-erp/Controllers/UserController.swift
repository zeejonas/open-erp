import Fluent
import Vapor

struct UserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let scoped = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("users")
        scoped.get(use: self.index)
        scoped.group(":userID") { user in
            user.get(use: self.show)
        }
    }

    @Sendable
    func index(req: Request) async throws -> [GetUserDTO] {
        try req.require(.organizationUserRead)
        return try await User.query(on: req.db, organizationID: req.organizationID)
            .all()
            .map { $0.toGetDTO() }
    }

    @Sendable
    func show(req: Request) async throws -> GetUserDTO {
        try req.require(.organizationUserRead)
        let user = try await self.findUser(req: req)
        return user.toGetDTO()
    }

    private func findUser(req: Request) async throws -> User {
        guard let userID = req.parameters.get("userID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid user ID")
        }
        guard let user = try await User.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$id == userID)
            .first()
        else {
            throw Abort(.notFound)
        }
        return user
    }
}
