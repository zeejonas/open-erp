@testable import open_erp
import Fluent
import Testing
import VaporTesting

extension OpenERPTests {
    private struct ProtectedRoute {
        var method: HTTPMethod
        var path: String
        var permission: Permission
    }

    @Test("Each organization route rejects a member missing its permission")
    func routePermissionSweep() async throws {
        let missingID = "00000000-0000-0000-0000-000000000099"
        let routes = [
            ProtectedRoute(method: .GET, path: "organization", permission: .organizationRead),
            ProtectedRoute(method: .PATCH, path: "organization", permission: .organizationUpdate),
            ProtectedRoute(method: .DELETE, path: "organization", permission: .organizationDelete),
            ProtectedRoute(method: .GET, path: "companies", permission: .companyRead),
            ProtectedRoute(method: .GET, path: "companies/\(missingID)", permission: .companyRead),
            ProtectedRoute(method: .POST, path: "companies", permission: .companyCreate),
            ProtectedRoute(method: .PATCH, path: "companies/\(missingID)", permission: .companyUpdate),
            ProtectedRoute(method: .DELETE, path: "companies/\(missingID)", permission: .companyDelete),
            ProtectedRoute(method: .GET, path: "users", permission: .organizationUserRead),
            ProtectedRoute(method: .GET, path: "users/\(missingID)", permission: .organizationUserRead),
            ProtectedRoute(method: .DELETE, path: "organization-users/\(missingID)", permission: .organizationUserDelete),
            ProtectedRoute(method: .POST, path: "organization-invitations", permission: .organizationInvitationCreate),
            ProtectedRoute(method: .GET, path: "organization-invitations", permission: .organizationInvitationRead),
            ProtectedRoute(method: .DELETE, path: "organization-invitations/\(missingID)", permission: .organizationInvitationDelete),
            ProtectedRoute(method: .POST, path: "roles", permission: .roleCreate),
            ProtectedRoute(method: .GET, path: "roles", permission: .roleRead),
            ProtectedRoute(method: .GET, path: "roles/\(missingID)", permission: .roleRead),
            ProtectedRoute(method: .PATCH, path: "roles/\(missingID)", permission: .roleUpdate),
            ProtectedRoute(method: .DELETE, path: "roles/\(missingID)", permission: .roleDelete),
            ProtectedRoute(method: .POST, path: "organization-role-assignments", permission: .organizationRoleAssignmentCreate),
            ProtectedRoute(method: .GET, path: "organization-role-assignments", permission: .organizationRoleAssignmentRead),
            ProtectedRoute(method: .DELETE, path: "organization-role-assignments/\(missingID)", permission: .organizationRoleAssignmentDelete),
        ]

        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()
            for (index, route) in routes.enumerated() {
                let slug = "\(index)-\(route.permission.rawValue.replacingOccurrences(of: ":", with: "-"))"
                _ = try await createMember(
                    on: app.db,
                    organizationID: orgID,
                    email: "\(slug)@example.com",
                    subject: slug,
                    permissions: Permission.allCases.filter { $0 != route.permission }
                )
                let token = try await signAccessToken(on: app, subject: slug)
                try await app.testing().test(route.method, route.path, beforeRequest: { req in
                    authorize(&req, token: token, organizationID: orgID)
                }, afterResponse: { res async in
                    #expect(res.status == .forbidden, "\(route.method) \(route.path) should be forbidden")
                })
            }
        }
    }

    @Test("Roles and organization role assignments enforce the catalog")
    func rolesAndAssignments() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let orgAID = try orgA.requireID()
            let orgBID = try orgB.requireID()
            let admin = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "admin@example.com",
                subject: "admin",
                permissions: Permission.allCases
            )
            let viewer = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "viewer@example.com",
                subject: "viewer",
                permissions: [.companyRead]
            )
            let outsider = try await createUser(on: app.db, email: "out@example.com", subject: "outsider")
            _ = try await createMember(
                on: app.db,
                organizationID: orgBID,
                email: "other-admin@example.com",
                subject: "other-admin",
                permissions: [.roleCreate]
            )
            let adminID = try admin.requireID()
            let adminToken = try await signAccessToken(on: app, subject: "admin")
            let viewerToken = try await signAccessToken(on: app, subject: "viewer")
            let otherAdminToken = try await signAccessToken(on: app, subject: "other-admin")
            let viewerID = try viewer.requireID()

            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: viewerToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })

            try await app.testing().test(.POST, "roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateRoleDTO(name: "Auditor", level: "organization", permissions: ["company:read"]))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let role = try res.content.decode(GetRoleDTO.self)
                #expect(role.name == "Auditor")
                #expect(role.permissions == ["company:read"])
            })

            try await app.testing().test(.POST, "roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateRoleDTO(name: "Broken", level: "company", permissions: ["organization:read"]))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            struct RoleWithoutLevel: Content {
                var name: String
                var permissions: [String]
            }
            try await app.testing().test(.POST, "roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(RoleWithoutLevel(name: "No Level", permissions: ["company:read"]))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            try await app.testing().test(.POST, "roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateRoleDTO(name: "Unknown", level: "organization", permissions: ["nope:read"]))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            try await app.testing().test(.POST, "roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateRoleDTO(name: "Auditor", level: "organization", permissions: []))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            var foreignRoleID: UUID?
            try await app.testing().test(.POST, "roles", beforeRequest: { req in
                authorize(&req, token: otherAdminToken, organizationID: orgBID)
                try req.content.encode(CreateRoleDTO(name: "Foreign", level: "organization", permissions: ["company:read"]))
            }, afterResponse: { res async throws in
                foreignRoleID = try res.content.decode(GetRoleDTO.self).id
            })

            try await app.testing().test(.POST, "organization-role-assignments", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateOrganizationRoleAssignmentDTO(userId: viewerID, roleId: try #require(foreignRoleID)))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            var companyRoleID: UUID?
            try await app.testing().test(.POST, "roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateRoleDTO(name: "Plant", level: "company", permissions: []))
            }, afterResponse: { res async throws in
                companyRoleID = try res.content.decode(GetRoleDTO.self).id
            })
            try await app.testing().test(.POST, "organization-role-assignments", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateOrganizationRoleAssignmentDTO(userId: viewerID, roleId: try #require(companyRoleID)))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            try await app.testing().test(.POST, "organization-role-assignments", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateOrganizationRoleAssignmentDTO(userId: try outsider.requireID(), roleId: try #require(companyRoleID)))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            let viewerRole = try await Role.query(on: app.db, organizationID: orgAID)
                .filter(\.$name == "permissions-viewer@example.com")
                .first()
            let viewerRoleID = try #require(viewerRole).requireID()
            var assignmentID: UUID?
            try await app.testing().test(.POST, "organization-role-assignments", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateOrganizationRoleAssignmentDTO(userId: viewerID, roleId: viewerRoleID))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            let auditor = try await Role.query(on: app.db, organizationID: orgAID).filter(\.$name == "Auditor").first()
            try await app.testing().test(.POST, "organization-role-assignments", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateOrganizationRoleAssignmentDTO(userId: viewerID, roleId: try auditor!.requireID()))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(GetOrganizationRoleAssignmentDTO.self)
                #expect(body.createdById == adminID)
                assignmentID = body.id
            })
            try await app.testing().test(.POST, "organization-role-assignments", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateOrganizationRoleAssignmentDTO(userId: viewerID, roleId: try auditor!.requireID()))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            try await app.testing().test(.DELETE, "roles/\(try auditor!.requireID())", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            try await app.testing().test(.DELETE, "organization-role-assignments/\(try #require(assignmentID))", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })

            try await app.testing().test(.POST, "organization-role-assignments", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateOrganizationRoleAssignmentDTO(userId: viewerID, roleId: try auditor!.requireID()))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                assignmentID = try res.content.decode(GetOrganizationRoleAssignmentDTO.self).id
            })
            let auditorGrants = try await OrganizationRoleAssignment.query(on: app.db)
                .filter(\.$role.$id == auditor!.requireID())
                .withDeleted()
                .all()
            #expect(auditorGrants.count == 2, "Re-granting keeps the revoked assignment as history")
            #expect(auditorGrants.contains { $0.$deletedBy.id == adminID })
            try await app.testing().test(.DELETE, "organization-role-assignments/\(try #require(assignmentID))", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })

            try await app.testing().test(.PATCH, "roles/\(viewerRoleID)", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(PatchRoleDTO(name: nil, level: nil, permissions: []))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            let removedGrant = try await RolePermission.query(on: app.db)
                .filter(\.$role.$id == viewerRoleID)
                .withDeleted()
                .first()
            #expect(removedGrant?.permission == Permission.companyRead.rawValue)
            #expect(removedGrant?.$deletedBy.id == adminID)
            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: viewerToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            try await app.testing().test(.PATCH, "roles/\(viewerRoleID)", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(PatchRoleDTO(name: nil, level: "company", permissions: nil))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            try await app.testing().test(.DELETE, "roles/\(try auditor!.requireID())", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            try await app.testing().test(.POST, "roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateRoleDTO(name: "Auditor", level: "organization", permissions: []))
            }, afterResponse: { res async in
                #expect(res.status == .ok, "A deleted role's name can be reused")
            })
        }
    }
}
