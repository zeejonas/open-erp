import Fluent
import Vapor

struct CompanyController: RouteCollection {
    func boot(routes: any RoutesBuilder) throws {
        let companies = routes.grouped(OrganizationMiddleware()).grouped("companies")

        companies.get(use: self.index)
        companies.post(use: self.create)
        companies.group(":companyID") { company in
            company.get(use: self.show)
            company.patch(use: self.patch)
            company.delete(use: self.delete)
        }
    }

    @Sendable
    func index(req: Request) async throws -> [GetCompanyDTO] {
        try await Company.query(on: req.db, organizationID: req.organizationID)
            .all()
            .map { $0.toGetDTO() }
    }

    @Sendable
    func create(req: Request) async throws -> GetCompanyDTO {
        try CreateCompanyDTO.validate(content: req)
        let dto = try req.content.decode(CreateCompanyDTO.self)

        let company = Company(
            code: dto.code,
            name: dto.name,
            organizationID: req.organizationID,
            createdBy: nil,
            updatedBy: nil,
            deletedBy: nil
        )
        try await company.save(on: req.db)
        return company.toGetDTO()
    }

    @Sendable
    func show(req: Request) async throws -> GetCompanyDTO {
        let company = try await self.findCompany(req: req)
        return company.toGetDTO()
    }

    @Sendable
    func patch(req: Request) async throws -> GetCompanyDTO {
        try PatchCompanyDTO.validate(content: req)
        let dto = try req.content.decode(PatchCompanyDTO.self)
        let company = try await self.findCompany(req: req)

        if let code = dto.code {
            company.code = code
        }
        if let name = dto.name {
            company.name = name
        }

        try await company.update(on: req.db)
        return company.toGetDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        let company = try await self.findCompany(req: req)
        try await company.delete(on: req.db)
        return .noContent
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
