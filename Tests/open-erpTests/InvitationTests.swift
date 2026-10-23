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
                ]
            )
            let adminToken = try await signAccessToken(on: app, subject: "admin-a")

            let foreign = AccessGroup(organizationID: orgBID, name: "Foreign", createdByID: nil)
            try await foreign.save(on: app.db)
            try await app.testing().test(.POST, "organization-invitations", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateInvitationDTO(
                    email: "bea@acme.com",
                    firstName: "Bea",
                    lastName: "Admin",
                    groupId: try foreign.requireID()
                ))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            let removed = AccessGroup(organizationID: orgAID, name: "Removed", createdByID: nil)
            try await removed.save(on: app.db)
            try await removed.delete(on: app.db)
            try await app.testing().test(.POST, "organization-invitations", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateInvitationDTO(
                    email: "bea@acme.com",
                    firstName: "Bea",
                    lastName: "Admin",
                    groupId: try removed.requireID()
                ))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })

            let doomed = AccessGroup(organizationID: orgAID, name: "Doomed", createdByID: nil)
            try await doomed.save(on: app.db)
            let (_, doomedToken) = try await OrganizationInvitation.issue(
                organizationID: orgAID,
                email: "doomed@acme.com",
                firstName: "Doomed",
                lastName: "Invite",
                groupID: try doomed.requireID(),
                createdByID: nil,
                on: app.db
            )
            try await doomed.delete(on: app.db)
            let usersBeforeDoomed = try await User.query(on: app.db).count()
            let membershipsBeforeDoomed = try await OrganizationUser.query(on: app.db).count()
            stubUserInfo(app, email: "doomed@acme.com", emailVerified: true)
            let doomedUserToken = try await signAccessToken(on: app, subject: "doomed-user")
            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: doomedUserToken)
                try req.content.encode(AcceptInvitationDTO(token: doomedToken))
            }, afterResponse: { res async in
                #expect(res.status == .badRequest)
            })
            #expect(try await User.query(on: app.db).count() == usersBeforeDoomed)
            #expect(try await OrganizationUser.query(on: app.db).count() == membershipsBeforeDoomed)
            let doomedInvite = try await OrganizationInvitation.query(on: app.db)
                .filter(\.$tokenHash == InvitationToken.hash(doomedToken))
                .first()
            #expect(doomedInvite?.acceptedAt == nil)

            let viewers = AccessGroup(organizationID: orgAID, name: "Organization Viewers", createdByID: nil)
            try await viewers.save(on: app.db)
            let viewersID = try viewers.requireID()

            var inviteToken = ""
            try await app.testing().test(.POST, "organization-invitations", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgAID)
                try req.content.encode(CreateInvitationDTO(
                    email: "bea@acme.com",
                    firstName: "Bea",
                    lastName: "Acme",
                    groupId: viewersID
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
                #expect(Set(pending.map(\.email)) == ["bea@acme.com", "doomed@acme.com"])
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
            let groupMembership = try await GroupMember.query(on: app.db)
                .filter(\.$organizationUser.$id == membership!.requireID())
                .first()
            #expect(groupMembership?.$group.id == viewersID)
            #expect(groupMembership?.$createdBy.id == beaID)

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
                groupID: nil,
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
                groupID: nil,
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
                groupID: nil,
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
                groupID: nil,
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
                try req.content.encode(CreateInvitationDTO(email: "revoked@acme.com", firstName: "Rev", lastName: "Oked", groupId: nil))
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
                groupID: nil,
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

    @Test("A re-invited member's old groups grant nothing")
    func reinvitedMemberLosesPreviousGroups() async throws {
        try await withApp { app in
            let org = try await createOrganization(on: app.db, code: "ORGA", name: "Org A")
            let orgID = try org.requireID()
            _ = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "admin@example.com",
                subject: "admin",
                permissions: [.organizationUserDelete, .organizationInvitationCreate]
            )
            let returning = try await createMember(
                on: app.db,
                organizationID: orgID,
                email: "ann@example.com",
                subject: "ann",
                permissions: [.companyRead]
            )
            let returningID = try returning.requireID()
            let adminToken = try await signAccessToken(on: app, subject: "admin")
            let annToken = try await signAccessToken(on: app, subject: "ann")

            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: annToken, organizationID: orgID)
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.DELETE, "organization-users/\(returningID)", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
            }, afterResponse: { res async in
                #expect(res.status == .noContent)
            })

            var inviteToken = ""
            try await app.testing().test(.POST, "organization-invitations", beforeRequest: { req in
                authorize(&req, token: adminToken, organizationID: orgID)
                try req.content.encode(CreateInvitationDTO(email: "ann@example.com", firstName: "Ann", lastName: "A", groupId: nil))
            }, afterResponse: { res async throws in
                inviteToken = try res.content.decode(CreateInvitationResponse.self).token
            })
            stubUserInfo(app, email: "ann@example.com", emailVerified: true)
            try await app.testing().test(.POST, "invitations/accept", beforeRequest: { req in
                authorize(&req, token: annToken)
                try req.content.encode(AcceptInvitationDTO(token: inviteToken))
            }, afterResponse: { res async in
                #expect(res.status == .ok)
            })
            try await app.testing().test(.GET, "companies", beforeRequest: { req in
                authorize(&req, token: annToken, organizationID: orgID)
            }, afterResponse: { res async in
                #expect(res.status == .forbidden)
            })

            let memberships = try await OrganizationUser.query(on: app.db, organizationID: orgID)
                .filter(\.$user.$id == returningID)
                .withDeleted()
                .all()
            let removed = try #require(memberships.first { $0.deletedAt != nil })
            let groupMembership = try await GroupMember.query(on: app.db)
                .filter(\.$organizationUser.$id == removed.requireID())
                .withDeleted()
                .first()
            #expect(groupMembership?.deletedAt != nil)
            let active = try #require(memberships.first { $0.deletedAt == nil })
            let restored = try await GroupMember.query(on: app.db)
                .filter(\.$organizationUser.$id == active.requireID())
                .first()
            #expect(restored == nil)
        }
    }
}
