import Fluent
import Vapor

struct CompanyController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let companies = routes.grouped(AuthMiddleware(), OrganizationMiddleware()).grouped("companies")

        companies.get(use: self.index)
        companies.post(use: self.create)
        companies.group(":companyID") { company in
            company.get(use: self.show)
            company.patch(use: self.patch)
            company.delete(use: self.delete)
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
