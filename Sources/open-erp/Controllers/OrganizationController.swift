import Fluent
import Vapor
import VaporToOpenAPI

struct OrganizationController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let scoped = routes.grouped(AuthMiddleware(), OrganizationMiddleware())
        scoped.get("organization", use: self.show)
            .openAPI(
                summary: "Get organization",
                description: "Requires organization:read.",
                headers: .type(OrganizationHeaders.self),
                response: .type(GetOrganizationDTO.self),
                auth: .bearer()
            )
        scoped.patch("organization", use: self.patch)
            .openAPI(
                summary: "Update organization",
                description: "Requires organization:update. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                headers: .type(OrganizationHeaders.self),
                body: .type(PatchOrganizationDTO.self),
                response: .type(GetOrganizationDTO.self),
                auth: .bearer()
            )
            .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        scoped.delete("organization", use: self.delete)
            .openAPI(
                summary: "Delete organization",
                description: "Requires organization:delete. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                headers: .type(OrganizationHeaders.self),
                responseDescription: "Deleted",
                statusCode: 204,
                auth: .bearer()
            )
            .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
    }

    @Sendable
    func show(req: Request) async throws -> GetOrganizationDTO {
        try req.require(.organizationRead)
        guard let organization = try await Organization.find(req.organizationID, on: req.db) else {
            throw Abort(.notFound)
        }
        return organization.toGetDTO()
    }

    @Sendable
    func patch(req: Request) async throws -> ApprovalOutcome<GetOrganizationDTO> {
        try req.require(.organizationUpdate)
        try PatchOrganizationDTO.validate(content: req)
        let dto = try req.content.decode(PatchOrganizationDTO.self)
        guard let organization = try await Organization.find(req.organizationID, on: req.db) else {
            throw Abort(.notFound)
        }
        let before = CodeNameSnapshot(code: organization.code, name: organization.name)
        var after = before
        if let code = dto.code { after.code = code }
        if let name = dto.name { after.name = name }
        return try await req.approvals.submit(.organizationUpdate(id: req.organizationID, before: before, after: after))
    }

    @Sendable
    func delete(req: Request) async throws -> ApprovalOutcome<HTTPStatus> {
        try req.require(.organizationDelete)
        guard let organization = try await Organization.find(req.organizationID, on: req.db) else {
            throw Abort(.notFound)
        }
        return try await req.approvals.submit(.organizationDelete(
            id: req.organizationID,
            before: CodeNameSnapshot(code: organization.code, name: organization.name)
        ))
    }
}
