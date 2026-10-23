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
    func index(req: Request) async throws -> [GetCompanyDTO] {
        try req.require(.companyRead)
        return try await Company.query(on: req.db, organizationID: req.organizationID)
            .all()
            .map { $0.toGetDTO() }
    }

    @Sendable
    func create(req: Request) async throws -> GetCompanyDTO {
        try req.require(.companyCreate)
        try CreateCompanyDTO.validate(content: req)
        let dto = try req.content.decode(CreateCompanyDTO.self)

        let company = Company(
            code: dto.code,
            name: dto.name,
            organizationID: req.organizationID,
            createdBy: req.user,
            updatedBy: nil,
            deletedBy: nil
        )
        try await conflictOnDuplicate(Self.duplicateCode) {
            try await company.save(on: req.db)
        }
        return company.toGetDTO()
    }

    @Sendable
    func show(req: Request) async throws -> GetCompanyDTO {
        try req.require(.companyRead)
        let company = try await self.findCompany(req: req)
        return company.toGetDTO()
    }

    @Sendable
    func patch(req: Request) async throws -> GetCompanyDTO {
        try req.require(.companyUpdate)
        try PatchCompanyDTO.validate(content: req)
        let dto = try req.content.decode(PatchCompanyDTO.self)
        let company = try await self.findCompany(req: req)

        if let code = dto.code {
            company.code = code
        }
        if let name = dto.name {
            company.name = name
        }
        company.$updatedBy.id = try req.userID()

        try await conflictOnDuplicate(Self.duplicateCode) {
            try await company.update(on: req.db)
        }
        return company.toGetDTO()
    }

    @Sendable
    func delete(req: Request) async throws -> HTTPStatus {
        try req.require(.companyDelete)
        let company = try await self.findCompany(req: req)
        let actorID = try req.userID()
        let companyID = try company.requireID()
        try await req.db.transaction { db in
            for link in try await GroupCompany.query(on: db).filter(\.$company.$id == companyID).all() {
                try await link.softDelete(by: actorID, \.$deletedBy, on: db)
            }
            try await company.softDelete(by: actorID, \.$deletedBy, on: db)
        }
        return .noContent
    }

    private static let duplicateCode = "A company with this code already exists"

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
