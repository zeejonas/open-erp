@testable import open_erp
import Fluent
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Invitation acceptance, rejection, and revocation")
    func invitations() async throws {
        try await withApp { app in
            let orgA = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgB = try await createOrganization(on: app.db, code: "ORGB", name: "Org B")
            let orgAID = try orgA.requireID()
            let orgBID = try orgB.requireID()
            _ = try await createMember(
                on: app.db,
                organizationID: orgAID,
                email: "admin-a@example.com",
                subject: "admin-a",
                permissions: [
                    .organizationInvitationCreate,
                    .organizationInvitationRead,
                    .organizationInvitationDelete,
                    .roleCreate,
                    .roleDelete,
                ]
            )
            _ = try await createMember(
                on: app.db,
                organizationID: orgBID,
                email: "admin-b@example.com",
                subject: "admin-b",
                permissions: [.roleCreate]
            )
            let adminToken = try await signAccessToken(on: app, subject: "admin-a")
            let adminBToken = try await signAccessToken(on: app, subject: "admin-b")

            var foreignRoleID: UUID?
            try await app.testing().test(.POST, "roles", beforeRequest: { req in
                authorize(&req, token: adminBToken, organizationID: orgBID)
                try req.content.encode(CreateRoleDTO(name: "Foreign", level: "organization", permissions: ["company:read"]))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                foreignRoleID = try res.content.decode(GetRoleDTO.self).id
            })

            try await app.testing().test(.POST, "organization-invitations", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateInvitationDTO(
                    email: "bea@acme.com",
                    firstName: "Bea",
                    lastName: "Admin",
                    roleId: foreignRoleID
                ))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            var companyRoleID: UUID?
            try await app.testing().test(.POST, "roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateRoleDTO(name: "Company Scoped", level: "company", permissions: []))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                companyRoleID = try res.content.decode(GetRoleDTO.self).id
            })
            try await app.testing().test(.POST, "organization-invitations", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateInvitationDTO(
                    email: "bea@acme.com",
                    firstName: "Bea",
                    lastName: "Admin",
                    roleId: companyRoleID
                ))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            var adminRoleID: UUID?
            try await app.testing().test(.POST, "roles", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateRoleDTO(name: "Auditor", level: "organization", permissions: ["company:read"]))
            }, afterResponse: { res async throws in
                adminRoleID = try res.content.decode(GetRoleDTO.self).id
            })

            var inviteToken = ""
            try await app.testing().test(.POST, "organization-invitations", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateInvitationDTO(
                    email: "bea@acme.com",
                    firstName: "Bea",
                    lastName: "Acme",
                    roleId: adminRoleID
                ))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(CreateInvitationResponse.self)
                inviteToken = body.token
                #expect(body.invitation.email == "bea@acme.com")
                let stored = try await OrganizationInvitation.query(on: app.db)
                    .filter(\.$tokenHash == InvitationToken.hash(body.token))
                    .first()
                #expect(stored?.tokenHash != body.token)
                let lifetime = try #require(stored).expiresAt.timeIntervalSinceNow
                #expect(lifetime > 6.9 * 24 * 60 * 60)
                #expect(lifetime < 7.1 * 24 * 60 * 60)
            })

            try await app.testing().test(.GET, "organization-invitations", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let pending = try res.content.decode([GetInvitationDTO].self)
                #expect(pending.map(\.email) == ["bea@acme.com"])
            })

            try await app.testing().test(.DELETE, "roles/\(try #require(adminRoleID))", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .conflict, "A role used by a pending invitation cannot be deleted")
            })

            let before = try await User.query(on: app.db).count()
            stubUserInfo(app, email: "bea@acme.com", emailVerified: false)
            let beaToken = try await signAccessToken(on: app, subject: "bea")
            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: beaToken)
                try req.content.encode(AcceptInvitationDTO(token: inviteToken))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
            #expect(try await User.query(on: app.db).count() == before)

            stubUserInfo(app, email: "other@acme.com", emailVerified: true)
            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: beaToken)
                try req.content.encode(AcceptInvitationDTO(token: inviteToken))
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })
            #expect(try await User.query(on: app.db).count() == before)

            stubUserInfo(app, email: "bea@acme.com", emailVerified: true)
            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: beaToken)
                try req.content.encode(AcceptInvitationDTO(token: inviteToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                let body = try res.content.decode(AcceptInvitationResponse.self)
                #expect(body.user.email == "bea@acme.com")
                #expect(body.user.firstName == "Bea")
                #expect(body.organizationId == orgAID)
            })

            let bea = try await User.find(email: "bea@acme.com", on: app.db)
            #expect(bea?.authSubject == "bea")
            let beaID = try #require(bea).requireID()
            let membership = try await OrganizationUser.query(on: app.db, organizationID: orgAID)
                .filter(\.$user.$id == beaID)
                .first()
            let assignment = try await OrganizationRoleAssignment.query(on: app.db)
                .filter(\.$organizationUser.$id == membership!.requireID())
                .first()
            #expect(assignment?.$role.id == adminRoleID)

            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: beaToken)
                try req.content.encode(AcceptInvitationDTO(token: inviteToken))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            let (_, secondToken) = try await OrganizationInvitation.issue(
                organizationID: orgBID,
                email: "bea@acme.com",
                firstName: "Bea",
                lastName: "Acme",
                roleID: nil,
                createdByID: nil,
                on: app.db
            )
            let usersBeforeSecond = try await User.query(on: app.db).count()
            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: beaToken)
                try req.content.encode(AcceptInvitationDTO(token: secondToken))
            }, afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(try res.content.decode(AcceptInvitationResponse.self).organizationId == orgBID)
            })
            #expect(try await User.query(on: app.db).count() == usersBeforeSecond)

            let conflictEmail = "taken@acme.com"
            _ = try await createUser(on: app.db, email: conflictEmail, subject: "original")
            let (_, conflictToken) = try await OrganizationInvitation.issue(
                organizationID: orgAID,
                email: conflictEmail,
                firstName: "Taken",
                lastName: "User",
                roleID: nil,
                createdByID: nil,
                on: app.db
            )
            stubUserInfo(app, email: conflictEmail, emailVerified: true)
            let intruder = try await signAccessToken(on: app, subject: "intruder")
            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: intruder)
                try req.content.encode(AcceptInvitationDTO(token: conflictToken))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })
            let taken = try await User.find(email: conflictEmail, on: app.db)
            #expect(taken?.authSubject == "original")
            #expect(try await OrganizationUser.query(on: app.db, organizationID: orgAID).filter(\.$user.$id == taken!.requireID()).first() == nil)

            let (_, memberToken) = try await OrganizationInvitation.issue(
                organizationID: orgAID,
                email: "bea@acme.com",
                firstName: "Bea",
                lastName: "Acme",
                roleID: nil,
                createdByID: nil,
                on: app.db
            )
            stubUserInfo(app, email: "bea@acme.com", emailVerified: true)
            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: beaToken)
                try req.content.encode(AcceptInvitationDTO(token: memberToken))
            }, afterResponse: { res async in
                #expect(res.status == .conflict)
            })

            let (expired, expiredToken) = try await OrganizationInvitation.issue(
                organizationID: orgBID,
                email: "late@acme.com",
                firstName: "Late",
                lastName: "User",
                roleID: nil,
                createdByID: nil,
                on: app.db
            )
            expired.expiresAt = Date().addingTimeInterval(-60)
            try await expired.save(on: app.db)
            stubUserInfo(app, email: "late@acme.com", emailVerified: true)
            let lateToken = try await signAccessToken(on: app, subject: "late")
            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: lateToken)
                try req.content.encode(AcceptInvitationDTO(token: expiredToken))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            var revokedID: UUID?
            var revokedToken = ""
            try await app.testing().test(.POST, "organization-invitations", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateInvitationDTO(email: "revoked@acme.com", firstName: "Rev", lastName: "Oked", roleId: nil))
            }, afterResponse: { res async throws in
                let body = try res.content.decode(CreateInvitationResponse.self)
                revokedID = body.invitation.id
                revokedToken = body.token
            })
            try await app.testing().test(.DELETE, "organization-invitations/\(try #require(revokedID))", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })
            stubUserInfo(app, email: "revoked@acme.com", emailVerified: true)
            let revokedUserToken = try await signAccessToken(on: app, subject: "revoked-user")
            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: revokedUserToken)
                try req.content.encode(AcceptInvitationDTO(token: revokedToken))
            }, afterResponse: { res async in
                #expect(res.status == .notFound)
            })

            let closed = try await createOrganization(on: app.db, code: "ORGC", name: "Closed")
            let (_, closedToken) = try await OrganizationInvitation.issue(
                organizationID: try closed.requireID(),
                email: "revoked@acme.com",
                firstName: "Rev",
                lastName: "Oked",
                roleID: nil,
                createdByID: nil,
                on: app.db
            )
            try await closed.delete(on: app.db)
            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: revokedUserToken)
                try req.content.encode(AcceptInvitationDTO(token: closedToken))
            }, afterResponse: { res async in
                #expect(res.status == .notFound, "Invitations to a deleted organization cannot be accepted")
            })
        }
    }
}
