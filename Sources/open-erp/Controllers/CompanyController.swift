import Fluent
import Vapor
import VaporToOpenAPI

struct CompanyController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let companies = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("companies")

        companies.get(use: self.index)
            .openAPI(
                summary: "List companies",
                description: "Requires company:read. Newest updatedAt first, then id ascending. page defaults to 1; per defaults to 25 (maximum 100). Unknown or repeated query parameters return 400.",
                query: [.type(ListPage.self), .type(CompanyListFilters.self)],
                headers: .type(OrganizationHeaders.self),
                response: .type(Page<GetCompanyDTO>.self),
                auth: .bearer()
            )
            .problemResponses(.badRequest)
        companies.post(use: self.create)
            .openAPI(
                summary: "Create company",
                description: "Requires company:create. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                headers: .type(OrganizationHeaders.self),
                body: .type(CreateCompanyDTO.self),
                response: .type(GetCompanyDTO.self),
                auth: .bearer()
            )
            .problemResponses(.badRequest, .payloadTooLarge, .unsupportedMediaType, .conflict)
            .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        companies.group(":companyID") { company in
            company.get(use: self.show)
                .openAPI(
                    summary: "Get company",
                    description: "Requires company:read.",
                    headers: .type(OrganizationHeaders.self),
                    response: .type(GetCompanyDTO.self),
                    auth: .bearer()
                )
                .problemResponses(.badRequest, .notFound)
            company.patch(use: self.patch)
                .openAPI(
                    summary: "Update company",
                    description: "Requires company:update. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                    headers: .type(OrganizationHeaders.self),
                    body: .type(PatchCompanyDTO.self),
                    response: .type(GetCompanyDTO.self),
                    auth: .bearer()
                )
                .problemResponses(.badRequest, .payloadTooLarge, .unsupportedMediaType, .notFound, .conflict)
                .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
            company.delete(use: self.delete)
                .openAPI(
                    summary: "Delete company",
                    description: "Requires company:delete. Returns 202 with an approval request when approval is required; otherwise applies the change immediately.",
                    headers: .type(OrganizationHeaders.self),
                    responseDescription: "Deleted",
                    statusCode: 204,
                    auth: .bearer()
                )
                .problemResponses(.badRequest, .notFound, .conflict)
                .response(statusCode: 202, body: .type(GetApprovalRequestDTO.self), description: "Waiting for approval")
        }
    }

    @Sendable
    func index(req: Request) async throws -> Page<GetCompanyDTO> {
        try req.require(.companyRead)
        let (filters, page) = try req.listParameters(CompanyListFilters.self)
        return try await Company.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$code, contains: filters.code)
            .filter(\.$name, contains: filters.name)
            .newestFirst(\.$updatedAt)
            .paginate(page)
            .map { $0.toGetDTO() }
    }

    @Sendable
    func create(req: Request) async throws -> ApprovalOutcome<GetCompanyDTO> {
        try req.require(.companyCreate)
        try CreateCompanyDTO.validate(content: req)
        let dto = try req.content.decode(CreateCompanyDTO.self)
        return try await req.approvals.submit(.companyCreate(CodeNameSnapshot(code: dto.code, name: dto.name)))
    }

    @Sendable
    func show(req: Request) async throws -> GetCompanyDTO {
        try req.require(.companyRead)
        let company = try await self.findCompany(req: req)
        return company.toGetDTO()
    }

    @Sendable
    func patch(req: Request) async throws -> ApprovalOutcome<GetCompanyDTO> {
        try req.require(.companyUpdate)
        try PatchCompanyDTO.validate(content: req)
        let dto = try req.content.decode(PatchCompanyDTO.self)
        let company = try await self.findCompany(req: req)
        let before = CodeNameSnapshot(code: company.code, name: company.name)
        var after = before
        if let code = dto.code { after.code = code }
        if let name = dto.name { after.name = name }
        return try await req.approvals.submit(.companyUpdate(id: try company.requireID(), before: before, after: after))
    }

    @Sendable
    func delete(req: Request) async throws -> ApprovalOutcome<HTTPStatus> {
        try req.require(.companyDelete)
        let company = try await self.findCompany(req: req)
        return try await req.approvals.submit(.companyDelete(
            id: try company.requireID(),
            before: CodeNameSnapshot(code: company.code, name: company.name)
        ))
    }

    private func findCompany(req: Request) async throws -> Company {
        guard let companyID = req.parameters.get("companyID", as: UUID.self) else {
            throw Abort(.badRequest, reason: "Invalid company ID")
        }
        guard let company = try await Company.query(on: req.db, organizationID: req.organizationID)
            .filter(\.$id == companyID)
            .first()
        else {
            throw Abort(.notFound)
        }
        return company
    }
}
