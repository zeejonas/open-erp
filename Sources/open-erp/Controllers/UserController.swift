import Fluent
import Vapor

struct UserController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        routes.post("users", use: self.create)

        let scoped = routes.grouped(OrganizationMiddleware()).grouped("users")
        scoped.get(use: self.index)
        scoped.group(":userID") { user in
            user.get(use: self.show)
            user.patch(use: self.patch)
        }
    }

    @Sendable
    func create(req: Request) async throws -> GetUserDTO {
        try CreateUserDTO.validate(content: req)
        let dto = try req.content.decode(CreateUserDTO.self)

        let user = User(
            firstName: dto.firstName,
            lastName: dto.lastName,
            email: dto.email,
            createdBy: nil,
            updatedBy: nil,
            deletedBy: nil
        )
        try await user.save(on: req.db)
        return user.toGetDTO()
    }

    @Sendable
    func index(req: Request) async throws -> [GetUserDTO] {
        try await User.query(on: req.db, organizationID: req.organizationID)
            .all()
            .map { $0.toGetDTO() }
    }

    @Sendable
    func show(req: Request) async throws -> GetUserDTO {
        let user = try await self.findUser(req: req)
        return user.toGetDTO()
    }

    @Sendable
    func patch(req: Request) async throws -> GetUserDTO {
        try PatchUserDTO.validate(content: req)
        let dto = try req.content.decode(PatchUserDTO.self)
        let user = try await self.findUser(req: req)

        if let firstName = dto.firstName {
            user.firstName = firstName
        }
        if let lastName = dto.lastName {
            user.lastName = lastName
        }
        if let email = dto.email {
            user.email = email
        }

        try await user.update(on: req.db)
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
