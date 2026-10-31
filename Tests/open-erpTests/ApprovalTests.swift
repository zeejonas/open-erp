@testable import open_erp
import Fluent
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("GET /approval-catalog lists gateable permissions")
    func approvalCatalog() async throws {
        try await withApp { app in
            let tenant = try await makeTenant(app, code: "CATA", subject: "catalog-admin")
            let readerDenied = try await signedMember(
                app,
                organizationID: tenant.organizationID,
                email: "catalog-denied@example.com",
                subject: "catalog-denied",
                permissions: [.companyRead]
            )

            let denied = try await api(
                app, .GET, "approval-catalog",
                token: readerDenied.token,
                organizationID: tenant.organizationID
            )
            try requireStatus(denied, .forbidden)

            let response = try await api(
                app, .GET, "approval-catalog",
                token: tenant.admin.token,
                organizationID: tenant.organizationID
            )
            try requireStatus(response, .ok)
            let entries = try response.content.decode([ApprovalCatalogEntry].self)
            #expect(response.headers[.cacheControl] == ["no-store"])
            let permissions = Set(entries.map(\.permission))
            #expect(permissions == Set(Permission.allCases.filter(ApprovalCatalog.isGateable).map(\.rawValue)))
            #expect(!permissions.contains { $0.hasSuffix(":read") || $0 == Permission.approvalOverrideCreate.rawValue })
            #expect(entries.first { $0.permission == "organization:update" }?.fields == ["code", "name"])
            #expect(entries.first { $0.permission == "company:update" }?.fields == ["code", "name"])
            #expect(entries.first { $0.permission == "role:update" }?.fields == ["name", "permissions"])
            #expect(entries.first { $0.permission == "group:update" }?.fields == ["name"])
            #expect(entries.first { $0.permission == "approval_policy:update" }?.fields == ["name", "fields", "companyId", "stages"])
            let scoped = Set(entries.filter(\.companyScope).map(\.permission))
            #expect(scoped == [
                "company:update", "company:delete",
                "group:update", "group:delete",
                "group_member:create", "group_member:delete",
                "group_role:create", "group_role:delete",
                "group_company:create", "group_company:delete",
            ])
        }
    }

    @Test("Approval policies validate, version, isolate, filter, and block deletes")
    func approvalPolicies() async throws {
        try await withApp { app in
            let tenant = try await makeTenant(app, code: "POLA", subject: "policy-admin")
            let orgID = tenant.organizationID
            let security = try await makePool(app, organizationID: orgID, name: "Security", prefix: "sec", count: 2)
            let it = try await makePool(app, organizationID: orgID, name: "IT", prefix: "it", count: 1)
            let cfo = try await makePool(app, organizationID: orgID, name: "CFO Office", prefix: "cfo", count: 1)
            let finance = try await makePool(app, organizationID: orgID, name: "Finance", prefix: "fin", count: 1)
            let other = try await makeTenant(app, code: "POLB", subject: "policy-other")
            let foreignGroup = AccessGroup(organizationID: other.organizationID, name: "Foreign", createdByID: nil)
            try await foreignGroup.save(on: app.db)
            let company = try await makeCompany(app, tenant: tenant, code: "SCOPED", name: "Scoped Co")
            let denied = try await signedMember(
                app, organizationID: orgID,
                email: "policy-denied@example.com", subject: "policy-denied",
                permissions: [.approvalPolicyRead]
            )

            let unknown = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Bad field", permission: .companyUpdate, fields: ["company_code"], stages: [(security.groupID, 1)])
            )
            try requireStatus(unknown, .badRequest)
            #expect(try failureReason(unknown).contains("company_code"))

            let fieldsOnDelete = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Bad delete", permission: .companyDelete, fields: ["name"], stages: [(security.groupID, 1)])
            )
            try requireStatus(fieldsOnDelete, .badRequest)

            let unscoped = try await postPolicy(
                app, tenant: tenant,
                policy(
                    name: "Bad company",
                    permission: .roleUpdate,
                    companyId: try #require(company.id),
                    stages: [(security.groupID, 1)]
                )
            )
            try requireStatus(unscoped, .badRequest)

            let foreign = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Foreign group", permission: .roleUpdate, stages: [(try foreignGroup.requireID(), 1)])
            )
            try requireStatus(foreign, .badRequest)
            #expect(try await ApprovalPolicy.query(on: app.db).count() == 0)

            let oversized = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Too big", permission: .roleUpdate, stages: [(security.groupID, 3)])
            )
            try requireStatus(oversized, .badRequest)
            #expect(try failureReason(oversized).contains("3"))

            let forbidden = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Nope", permission: .roleUpdate, stages: [(security.groupID, 1)]),
                token: denied.token
            )
            try requireStatus(forbidden, .forbidden)

            let created = try await postPolicy(
                app, tenant: tenant,
                policy(
                    name: "Role changes",
                    permission: .roleUpdate,
                    fields: ["permissions"],
                    stages: [(security.groupID, 1), (it.groupID, 1)],
                    then: [(cfo.groupID, 1)]
                )
            )
            try requireStatus(created, .ok)
            var rolePolicy = try created.content.decode(GetApprovalPolicyDTO.self)
            let policyID = try #require(rolePolicy.id)
            #expect(rolePolicy.currentVersion == 1)
            #expect(rolePolicy.createdById == tenant.admin.id)
            #expect(Set(rolePolicy.stages[0].slots.map(\.groupId)) == [security.groupID, it.groupID])
            #expect(rolePolicy.stages[1].slots.map(\.groupId) == [cfo.groupID])

            let duplicate = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Role changes", permission: .companyUpdate, stages: [(security.groupID, 1)])
            )
            try requireStatus(duplicate, .conflict)

            for method in [HTTPMethod.GET, .PATCH, .DELETE] {
                let cross = try await api(
                    app, method, "approval-policies/\(policyID)",
                    token: other.admin.token,
                    organizationID: other.organizationID,
                    json: method == .PATCH ? try json(policy(
                        name: "Stolen",
                        permission: .roleUpdate,
                        fields: ["permissions"],
                        stages: [(security.groupID, 1)],
                        then: [(cfo.groupID, 1)]
                    )) : nil
                )
                try requireStatus(cross, .notFound)
            }
            let unchanged = try await ApprovalPolicy.find(policyID, on: app.db)
            #expect(unchanged?.name == "Role changes")

            let edited = try await api(
                app, .PATCH, "approval-policies/\(policyID)",
                token: tenant.admin.token,
                organizationID: orgID,
                json: try json(policy(
                    name: "Role changes",
                    permission: .roleUpdate,
                    fields: ["permissions"],
                    stages: [(security.groupID, 1), (it.groupID, 1)],
                    then: [(finance.groupID, 1)]
                ))
            )
            try requireStatus(edited, .ok)
            rolePolicy = try edited.content.decode(GetApprovalPolicyDTO.self)
            #expect(rolePolicy.currentVersion == 2)
            #expect(rolePolicy.stages[1].slots.map(\.groupId) == [finance.groupID])

            let renamed = try await api(
                app, .PATCH, "approval-policies/\(policyID)",
                token: tenant.admin.token,
                organizationID: orgID,
                json: try json(policy(
                    name: "Role changes",
                    permission: .companyUpdate,
                    stages: [(security.groupID, 1)]
                ))
            )
            try requireStatus(renamed, .badRequest)
            #expect(try await ApprovalPolicy.find(policyID, on: app.db)?.currentVersion == 2)

            let versions = try await api(
                app, .GET, "approval-policies/\(policyID)/versions",
                token: tenant.admin.token,
                organizationID: orgID
            )
            try requireStatus(versions, .ok)
            let history = try versions.content.decode(Page<GetApprovalPolicyVersionDTO>.self)
            #expect(history.items.map(\.version) == [2, 1])
            #expect(history.items[0].definition.stages[1].slots.map(\.groupId) == [finance.groupID])
            #expect(history.items[1].definition.stages[1].slots.map(\.groupId) == [cfo.groupID])
            #expect(history.items[1].createdById == tenant.admin.id)

            let companyPolicyResponse = try await postPolicy(
                app, tenant: tenant,
                policy(
                    name: "Company edits",
                    permission: .companyDelete,
                    companyId: try #require(company.id),
                    stages: [(finance.groupID, 1)]
                )
            )
            try requireStatus(companyPolicyResponse, .ok)

            let byGroup = try await api(
                app, .GET, "approval-policies",
                token: tenant.admin.token,
                organizationID: orgID,
                query: "groupId=\(security.groupID)"
            )
            try requireStatus(byGroup, .ok)
            let grouped = try byGroup.content.decode(Page<GetApprovalPolicyDTO>.self)
            #expect(grouped.items.map(\.name) == ["Role changes"])

            let byCompany = try await api(
                app, .GET, "approval-policies",
                token: tenant.admin.token,
                organizationID: orgID,
                query: "companyId=\(try #require(company.id))"
            )
            try requireStatus(byCompany, .ok)
            let scoped = try byCompany.content.decode(Page<GetApprovalPolicyDTO>.self)
            #expect(scoped.items.map(\.name) == ["Company edits"])

            let deleteGroup = try await api(
                app, .DELETE, "groups/\(security.groupID)",
                token: tenant.admin.token,
                organizationID: orgID
            )
            try requireStatus(deleteGroup, .conflict)
            #expect(try failureReason(deleteGroup).contains("approver pool"))
            #expect(try await AccessGroup.find(security.groupID, on: app.db)?.deletedAt == nil)

            let deleteCompany = try await api(
                app, .DELETE, "companies/\(try #require(company.id))",
                token: tenant.admin.token,
                organizationID: orgID
            )
            try requireStatus(deleteCompany, .conflict)
            #expect(try failureReason(deleteCompany).contains("scope"))
            #expect(try await Company.find(try #require(company.id), on: app.db)?.deletedAt == nil)

            let role = try await makeRole(app, tenant: tenant, name: "Auditors", permissions: ["company:read"])
            let held = try await api(
                app, .PATCH, "roles/\(try #require(role.id))",
                token: tenant.admin.token,
                organizationID: orgID,
                json: try json(PatchRoleDTO(name: nil, level: nil, permissions: ["company:read", "company:update"]))
            )
            try requireStatus(held, .accepted)
            let removed = try await api(
                app, .DELETE, "approval-policies/\(policyID)",
                token: tenant.admin.token,
                organizationID: orgID
            )
            try requireStatus(removed, .noContent)

            let afterDelete = try await api(
                app, .GET, "approval-policies/\(policyID)/versions",
                token: tenant.admin.token,
                organizationID: orgID
            )
            try requireStatus(afterDelete, .ok)
            #expect(try afterDelete.content.decode(Page<GetApprovalPolicyVersionDTO>.self).items.count == 2)
            let shown = try await api(
                app, .GET, "approval-policies/\(policyID)",
                token: tenant.admin.token,
                organizationID: orgID
            )
            try requireStatus(shown, .ok)
            #expect(try shown.content.decode(GetApprovalPolicyDTO.self).deletedAt != nil)
            let listed = try await api(
                app, .GET, "approval-policies",
                token: tenant.admin.token,
                organizationID: orgID,
                query: "name=Role"
            )
            try requireStatus(listed, .ok)
            #expect(try listed.content.decode(Page<GetApprovalPolicyDTO>.self).items.isEmpty)

            let passed = try await api(
                app, .PATCH, "roles/\(try #require(role.id))",
                token: tenant.admin.token,
                organizationID: orgID,
                json: try json(PatchRoleDTO(name: "Auditors renamed", level: nil, permissions: nil))
            )
            try requireStatus(passed, .ok)
            #expect(try passed.content.decode(GetRoleDTO.self).name == "Auditors renamed")
        }
    }

    @Test("Matching holds covered writes and lets everything else through")
    func approvalMatching() async throws {
        try await withApp { app in
            let tenant = try await makeTenant(app, code: "MATCH", subject: "match-admin")
            let orgID = tenant.organizationID
            let approvers = try await makePool(app, organizationID: orgID, name: "Approvers", prefix: "match-app", count: 1)
            let stageTwo = try await makePool(app, organizationID: orgID, name: "Second stage", prefix: "match-s2", count: 1)
            let companyA = try await makeCompany(app, tenant: tenant, code: "CMPA", name: "Company A")
            let companyB = try await makeCompany(app, tenant: tenant, code: "CMPB", name: "Company B")
            let companyAID = try #require(companyA.id)
            let companyBID = try #require(companyB.id)

            let renamed = try await api(
                app, .PATCH, "companies/\(companyAID)",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(PatchCompanyDTO(code: nil, name: "Company A1"))
            )
            try requireStatus(renamed, .ok)
            #expect(try renamed.content.decode(GetCompanyDTO.self).name == "Company A1")

            let scoped = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Company A edits", permission: .companyUpdate, companyId: companyAID, stages: [(approvers.groupID, 1)])
            )
            try requireStatus(scoped, .ok)

            let otherCompany = try await api(
                app, .PATCH, "companies/\(companyBID)",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(PatchCompanyDTO(code: nil, name: "Company B1"))
            )
            try requireStatus(otherCompany, .ok)

            let orgWide = try await postPolicy(
                app, tenant: tenant,
                policy(name: "All company edits", permission: .companyUpdate, stages: [(approvers.groupID, 1)])
            )
            try requireStatus(orgWide, .ok)
            let both = try await api(
                app, .PATCH, "companies/\(companyAID)",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(PatchCompanyDTO(code: nil, name: "Company A2"))
            )
            try requireStatus(both, .accepted)
            let bothRequest = try heldRequest(both)
            #expect(bothRequest.status == "pending")
            #expect(bothRequest.tracks.count == 2)
            #expect(try await Company.find(companyAID, on: app.db)?.name == "Company A1")

            let role = try await makeRole(app, tenant: tenant, name: "Clerks", permissions: ["company:read"])
            let roleID = try #require(role.id)
            let rolePolicy = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Role changes", permission: .roleUpdate, fields: ["permissions"], stages: [(approvers.groupID, 1)])
            )
            try requireStatus(rolePolicy, .ok)

            let permissionChange = try await api(
                app, .PATCH, "roles/\(roleID)",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(PatchRoleDTO(name: nil, level: nil, permissions: ["company:read", "company:update"]))
            )
            try requireStatus(permissionChange, .accepted)
            #expect(try await rolePermissions(app, roleID: roleID) == ["company:read"])

            let nameOnly = try await api(
                app, .PATCH, "roles/\(roleID)",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(PatchRoleDTO(name: "Clerk team", level: nil, permissions: nil))
            )
            try requireStatus(nameOnly, .ok)
            #expect(try nameOnly.content.decode(GetRoleDTO.self).name == "Clerk team")

            let samePermissions = try await api(
                app, .PATCH, "roles/\(roleID)",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(PatchRoleDTO(name: "Clerk desk", level: nil, permissions: ["company:read"]))
            )
            try requireStatus(samePermissions, .ok)
            #expect(try samePermissions.content.decode(GetRoleDTO.self).name == "Clerk desk")

            let plant = try await api(
                app, .POST, "groups",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(CreateGroupDTO(name: "Plant"))
            )
            try requireStatus(plant, .ok)
            let plantID = try #require(try plant.content.decode(GetGroupDTO.self).id)
            for companyID in [companyAID, companyBID] {
                let link = try await api(
                    app, .POST, "groups/\(plantID)/companies",
                    token: tenant.admin.token, organizationID: orgID,
                    json: try json(AddGroupCompanyDTO(companyId: companyID))
                )
                try requireStatus(link, .ok)
            }
            let memberPolicyA = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Members A", permission: .groupMemberCreate, companyId: companyAID, stages: [(approvers.groupID, 1)])
            )
            let memberPolicyB = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Members B", permission: .groupMemberCreate, companyId: companyBID, stages: [(approvers.groupID, 1)])
            )
            try requireStatus(memberPolicyA, .ok)
            try requireStatus(memberPolicyB, .ok)
            let recruit = try await signedMember(
                app, organizationID: orgID,
                email: "recruit@example.com", subject: "recruit", permissions: []
            )
            let membership = try await api(
                app, .POST, "groups/\(plantID)/members",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(AddGroupMemberDTO(userId: recruit.id))
            )
            try requireStatus(membership, .accepted)
            #expect(try heldRequest(membership).tracks.count == 2)

            let noUpdate = try await signedMember(
                app, organizationID: orgID,
                email: "no-update@example.com", subject: "no-update", permissions: [.roleRead]
            )
            let before = try await ApprovalRequest.query(on: app.db).count()
            let missingPermission = try await api(
                app, .PATCH, "roles/\(roleID)",
                token: noUpdate.token, organizationID: orgID,
                json: try json(PatchRoleDTO(name: "Blocked", level: nil, permissions: nil))
            )
            try requireStatus(missingPermission, .forbidden)
            let invalid = try await api(
                app, .PATCH, "roles/\(roleID)",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(PatchRoleDTO(name: nil, level: nil, permissions: ["not-a-permission"]))
            )
            try requireStatus(invalid, .badRequest)
            #expect(try await ApprovalRequest.query(on: app.db).count() == before)

            let governing = try await postPolicy(
                app, tenant: tenant,
                policy(
                    name: "Govern policies",
                    permission: .approvalPolicyUpdate,
                    stages: [(approvers.groupID, 1)],
                    then: [(stageTwo.groupID, 1)]
                )
            )
            try requireStatus(governing, .ok)
            let governingID = try #require(try governing.content.decode(GetApprovalPolicyDTO.self).id)
            let loosened = try await api(
                app, .PATCH, "approval-policies/\(governingID)",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(policy(name: "Govern policies", permission: .approvalPolicyUpdate, stages: [(approvers.groupID, 1)]))
            )
            try requireStatus(loosened, .accepted)
            let loosenedRequest = try heldRequest(loosened)
            #expect(loosenedRequest.tracks.count == 1)
            #expect(loosenedRequest.tracks[0].version == 1)
            #expect(loosenedRequest.tracks[0].definition.stages.count == 2)
            let still = try await api(
                app, .GET, "approval-policies/\(governingID)",
                token: tenant.admin.token, organizationID: orgID
            )
            let stillPolicy = try still.content.decode(GetApprovalPolicyDTO.self)
            #expect(stillPolicy.currentVersion == 1)
            #expect(stillPolicy.stages.count == 2)

            let first = try await approve(app, tenant: tenant, requestID: loosenedRequest.id, member: approvers.members[0])
            #expect(first.status == "pending")
            #expect(first.tracks[0].currentStage == 2)
            let second = try await approve(app, tenant: tenant, requestID: loosenedRequest.id, member: stageTwo.members[0])
            #expect(second.status == "applied")
            let governed = try await api(
                app, .GET, "approval-policies/\(governingID)",
                token: tenant.admin.token, organizationID: orgID
            )
            let governedPolicy = try governed.content.decode(GetApprovalPolicyDTO.self)
            #expect(governedPolicy.currentVersion == 2)
            #expect(governedPolicy.stages.count == 1)
            #expect(governedPolicy.updatedById == tenant.admin.id)
        }
    }

    @Test("Approvers fill slots, and only the current stage of each track")
    func approvalDecisions() async throws {
        try await withApp { app in
            let tenant = try await makeTenant(app, code: "DECN", subject: "decision-admin")
            let orgID = tenant.organizationID
            let security = try await makePool(app, organizationID: orgID, name: "Security", prefix: "d-sec", count: 1)
            let it = try await makePool(app, organizationID: orgID, name: "IT", prefix: "d-it", count: 1)
            let cfo = try await makePool(app, organizationID: orgID, name: "CFO Office", prefix: "d-cfo", count: 1)
            let dual = try await signedMember(app, organizationID: orgID, email: "dual@example.com", subject: "dual", permissions: [])
            let securityOnly = try await signedMember(app, organizationID: orgID, email: "sec-only@example.com", subject: "sec-only", permissions: [])
            let temporary = try await signedMember(app, organizationID: orgID, email: "temp@example.com", subject: "temp-approver", permissions: [])
            try await join(app, tenant: tenant, groupID: security.groupID, userID: dual.id)
            try await join(app, tenant: tenant, groupID: it.groupID, userID: dual.id)
            try await join(app, tenant: tenant, groupID: security.groupID, userID: securityOnly.id)
            try await join(app, tenant: tenant, groupID: security.groupID, userID: temporary.id)
            let clerk = try await signedMember(
                app, organizationID: orgID, email: "clerk@example.com", subject: "clerk", permissions: [.companyUpdate]
            )
            let outsider = try await makeTenant(app, code: "DECO", subject: "decision-outsider")

            func company(_ code: String) async throws -> UUID {
                try #require(try await makeCompany(app, tenant: tenant, code: code, name: "Company \(code)").id)
            }

            let shared = try await postPolicy(
                app, tenant: tenant,
                policy(
                    name: "Shared edits",
                    permission: .companyUpdate,
                    stages: [(security.groupID, 1), (it.groupID, 1)]
                )
            )
            try requireStatus(shared, .ok)
            let sharedID = try #require(try shared.content.decode(GetApprovalPolicyDTO.self).id)

            let parallelCompany = try await company("PARA")
            let parallel = try await rename(app, tenant: tenant, companyID: parallelCompany, name: "Parallel", token: clerk.token)
            let securityApproval = try await approve(app, tenant: tenant, requestID: parallel.id, member: security.members[0])
            #expect(securityApproval.status == "pending")
            #expect(securityApproval.tracks[0].currentStage == 1)
            #expect(try await Company.find(parallelCompany, on: app.db)?.name == "Company PARA")
            let itApproval = try await approve(app, tenant: tenant, requestID: parallel.id, member: it.members[0])
            #expect(itApproval.status == "applied")
            #expect(try await Company.find(parallelCompany, on: app.db)?.name == "Parallel")

            let soloCompany = try await company("SOLO")
            let solo = try await rename(app, tenant: tenant, companyID: soloCompany, name: "Solo", token: clerk.token)
            let soloApproval = try await approve(app, tenant: tenant, requestID: solo.id, member: dual)
            #expect(soloApproval.status == "pending")
            #expect(soloApproval.decisions.count == 1)
            #expect(try await Company.find(soloCompany, on: app.db)?.name == "Company SOLO")
            try await withdraw(app, tenant: tenant, requestID: solo.id, token: clerk.token)

            let bestCompany = try await company("BEST")
            let best = try await rename(app, tenant: tenant, companyID: bestCompany, name: "Best", token: clerk.token)
            let onlySecurity = try await approve(app, tenant: tenant, requestID: best.id, member: securityOnly)
            #expect(onlySecurity.status == "pending")
            let bestApproval = try await approve(app, tenant: tenant, requestID: best.id, member: dual)
            #expect(bestApproval.status == "applied")
            #expect(try await Company.find(bestCompany, on: app.db)?.name == "Best")

            let removedCompany = try await company("REMV")
            let removed = try await rename(app, tenant: tenant, companyID: removedCompany, name: "Removed", token: clerk.token)
            let removal = try await api(
                app, .DELETE, "groups/\(security.groupID)/members/\(temporary.id)",
                token: tenant.admin.token, organizationID: orgID
            )
            try requireStatus(removal, .noContent)
            let removedApproval = try await api(
                app, .POST, "approval-requests/\(removed.id)/approve",
                token: temporary.token, organizationID: orgID
            )
            try requireStatus(removedApproval, .forbidden)
            try await withdraw(app, tenant: tenant, requestID: removed.id, token: clerk.token)

            try await join(app, tenant: tenant, groupID: security.groupID, userID: clerk.id)
            let ownCompany = try await company("OWNR")
            let own = try await rename(app, tenant: tenant, companyID: ownCompany, name: "Own", token: clerk.token)
            let selfApproval = try await api(
                app, .POST, "approval-requests/\(own.id)/approve",
                token: clerk.token, organizationID: orgID
            )
            try requireStatus(selfApproval, .forbidden)
            #expect(try await ApprovalDecision.query(on: app.db).filter(\.$request.$id == own.id).count() == 0)
            try await withdraw(app, tenant: tenant, requestID: own.id, token: clerk.token)
            let leave = try await api(
                app, .DELETE, "groups/\(security.groupID)/members/\(clerk.id)",
                token: tenant.admin.token, organizationID: orgID
            )
            try requireStatus(leave, .noContent)

            let foreignCompany = try await company("FRGN")
            let foreign = try await rename(app, tenant: tenant, companyID: foreignCompany, name: "Foreign", token: clerk.token)
            let foreignApproval = try await api(
                app, .POST, "approval-requests/\(foreign.id)/approve",
                token: outsider.admin.token, organizationID: outsider.organizationID
            )
            try requireStatus(foreignApproval, .notFound)
            try await withdraw(app, tenant: tenant, requestID: foreign.id, token: clerk.token)

            let deleted = try await api(
                app, .DELETE, "approval-policies/\(sharedID)",
                token: tenant.admin.token, organizationID: orgID
            )
            try requireStatus(deleted, .noContent)

            let staged = try await postPolicy(
                app, tenant: tenant,
                policy(
                    name: "Staged edits",
                    permission: .companyUpdate,
                    stages: [(security.groupID, 1)],
                    then: [(cfo.groupID, 1)]
                )
            )
            try requireStatus(staged, .ok)
            let stagedCompany = try await company("STAG")
            let stagedRequest = try await rename(app, tenant: tenant, companyID: stagedCompany, name: "Staged", token: clerk.token)
            let early = try await api(
                app, .POST, "approval-requests/\(stagedRequest.id)/approve",
                token: cfo.members[0].token, organizationID: orgID
            )
            try requireStatus(early, .forbidden)
            let stageOne = try await approve(app, tenant: tenant, requestID: stagedRequest.id, member: security.members[0])
            #expect(stageOne.status == "pending")
            #expect(stageOne.tracks[0].currentStage == 2)
            let stageTwo = try await approve(app, tenant: tenant, requestID: stagedRequest.id, member: cfo.members[0])
            #expect(stageTwo.status == "applied")
            try requireStatus(
                try await api(app, .DELETE, "approval-policies/\(try #require(try staged.content.decode(GetApprovalPolicyDTO.self).id))", token: tenant.admin.token, organizationID: orgID),
                .noContent
            )

            let firstTrack = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Track one", permission: .companyUpdate, stages: [(security.groupID, 1)])
            )
            let secondTrack = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Track two", permission: .companyUpdate, stages: [(it.groupID, 1)])
            )
            try requireStatus(firstTrack, .ok)
            try requireStatus(secondTrack, .ok)
            try await join(app, tenant: tenant, groupID: it.groupID, userID: security.members[0].id)
            let countedCompany = try await company("BOTH")
            let counted = try await rename(app, tenant: tenant, companyID: countedCompany, name: "Counted", token: clerk.token)
            #expect(counted.tracks.count == 2)
            let countedApproval = try await approve(app, tenant: tenant, requestID: counted.id, member: security.members[0])
            #expect(countedApproval.status == "applied")
            #expect(countedApproval.decisions.count == 2)
            #expect(Set(countedApproval.decisions.map(\.trackId)) == Set(counted.tracks.map(\.id)))
        }
    }

    @Test("Final approval applies as the requester, or records a failure")
    func approvalApply() async throws {
        try await withApp { app in
            let tenant = try await makeTenant(app, code: "APLY", subject: "apply-admin")
            let orgID = tenant.organizationID
            let approvers = try await makePool(app, organizationID: orgID, name: "Approvers", prefix: "apply", count: 2)
            let clerk = try await signedMember(
                app, organizationID: orgID, email: "apply-clerk@example.com", subject: "apply-clerk",
                permissions: [.companyUpdate, .companyCreate]
            )

            let governed = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Renames", permission: .companyUpdate, fields: ["name"], stages: [(approvers.groupID, 1)])
            )
            try requireStatus(governed, .ok)
            let policyID = try #require(try governed.content.decode(GetApprovalPolicyDTO.self).id)
            let company = try await makeCompany(app, tenant: tenant, code: "MAIN", name: "Original")
            let companyID = try #require(company.id)
            let request = try await rename(app, tenant: tenant, companyID: companyID, name: "Approved", token: clerk.token)
            let applied = try await approve(app, tenant: tenant, requestID: request.id, member: approvers.members[0])
            #expect(applied.status == "applied")
            let saved = try #require(try await Company.find(companyID, on: app.db))
            #expect(saved.name == "Approved")
            #expect(saved.$updatedBy.id == clerk.id)

            let edited = try await api(
                app, .PATCH, "approval-policies/\(policyID)",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(policy(name: "Renames revised", permission: .companyUpdate, fields: ["name"], stages: [(approvers.groupID, 1)]))
            )
            try requireStatus(edited, .ok)
            try requireStatus(
                try await api(app, .DELETE, "approval-policies/\(policyID)", token: tenant.admin.token, organizationID: orgID),
                .noContent
            )
            let evidence = try await api(
                app, .GET, "approval-requests/\(request.id)",
                token: tenant.admin.token, organizationID: orgID
            )
            try requireStatus(evidence, .ok)
            let recorded = try evidence.content.decode(GetApprovalRequestDTO.self)
            #expect(recorded.tracks[0].version == 1)
            #expect(recorded.tracks[0].definition.name == "Renames")
            #expect(recorded.decisions.map(\.kind) == ["approve"])
            let closed = try await api(
                app, .POST, "approval-requests/\(request.id)/approve",
                token: approvers.members[1].token, organizationID: orgID
            )
            try requireStatus(closed, .conflict)

            let stalePolicy = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Stale renames", permission: .companyUpdate, fields: ["name"], stages: [(approvers.groupID, 1)])
            )
            try requireStatus(stalePolicy, .ok)
            let staleCompany = try await makeCompany(app, tenant: tenant, code: "STALE", name: "Before")
            let staleID = try #require(staleCompany.id)
            let staleRequest = try await rename(app, tenant: tenant, companyID: staleID, name: "Held", token: clerk.token)
            let direct = try #require(try await Company.find(staleID, on: app.db))
            direct.name = "Direct"
            try await direct.save(on: app.db)
            let staleApproval = try await approve(app, tenant: tenant, requestID: staleRequest.id, member: approvers.members[0])
            #expect(staleApproval.status == "failed")
            #expect(staleApproval.failureReason?.contains("changed") == true)
            #expect(staleApproval.decisions.map(\.kind) == ["approve"])
            #expect(try await Company.find(staleID, on: app.db)?.name == "Direct")

            let createPolicy = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Creates", permission: .companyCreate, stages: [(approvers.groupID, 1)])
            )
            try requireStatus(createPolicy, .ok)
            let heldCreate = try await api(
                app, .POST, "companies",
                token: clerk.token, organizationID: orgID,
                json: try json(CreateCompanyDTO(code: "TAKEN", name: "Taken Co"))
            )
            try requireStatus(heldCreate, .accepted)
            let createRequest = try heldRequest(heldCreate)
            let rival = Company(code: "TAKEN", name: "Already", organizationID: orgID, createdBy: nil, updatedBy: nil, deletedBy: nil)
            try await rival.save(on: app.db)
            let failedCreate = try await approve(app, tenant: tenant, requestID: createRequest.id, member: approvers.members[0])
            #expect(failedCreate.status == "failed")
            #expect(try await Company.query(on: app.db).filter(\.$code == "TAKEN").count() == 1)

            let racePolicy = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Race", permission: .companyUpdate, fields: ["name"], stages: [(approvers.groupID, 1)])
            )
            try requireStatus(racePolicy, .ok)
            let raceCompany = Company(
                code: "RACE", name: "Race start", organizationID: orgID, createdBy: nil, updatedBy: nil, deletedBy: nil
            )
            try await raceCompany.save(on: app.db)
            let raceID = try raceCompany.requireID()
            let race = try await rename(app, tenant: tenant, companyID: raceID, name: "Race end", token: clerk.token)
            async let first = api(app, .POST, "approval-requests/\(race.id)/approve", token: approvers.members[0].token, organizationID: orgID)
            async let second = api(app, .POST, "approval-requests/\(race.id)/approve", token: approvers.members[1].token, organizationID: orgID)
            let results = try await [first, second]
            #expect(Set(results.map(\.status)) == [.ok, .conflict])
            #expect(try await Company.find(raceID, on: app.db)?.name == "Race end")
            #expect(try await ApprovalRequest.find(race.id, on: app.db)?.status == "applied")

            let lostPolicy = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Lost permission", permission: .companyUpdate, fields: ["name"], stages: [(approvers.groupID, 1)])
            )
            try requireStatus(lostPolicy, .ok)
            let lostCompany = Company(
                code: "LOST", name: "Still", organizationID: orgID, createdBy: nil, updatedBy: nil, deletedBy: nil
            )
            try await lostCompany.save(on: app.db)
            let lostID = try lostCompany.requireID()
            let lostRequest = try await rename(app, tenant: tenant, companyID: lostID, name: "Should fail", token: clerk.token)
            let grant = try #require(try await RolePermission.query(on: app.db)
                .filter(\.$permission == Permission.companyUpdate.rawValue)
                .join(Role.self, on: \RolePermission.$role.$id == \Role.$id)
                .filter(Role.self, \.$name == "permissions-apply-clerk@example.com")
                .first())
            try await grant.delete(on: app.db)
            let lostApproval = try await approve(app, tenant: tenant, requestID: lostRequest.id, member: approvers.members[0])
            #expect(lostApproval.status == "failed")
            #expect(lostApproval.failureReason?.contains("company:update") == true)
            #expect(try await Company.find(lostID, on: app.db)?.name == "Still")
        }
    }

    @Test("Requests can be rejected, withdrawn, and read by the people involved")
    func approvalRequests() async throws {
        try await withApp { app in
            let tenant = try await makeTenant(app, code: "REQA", subject: "request-admin")
            let orgID = tenant.organizationID
            let approvers = try await makePool(app, organizationID: orgID, name: "Approvers", prefix: "req", count: 1)
            let clerk = try await signedMember(
                app, organizationID: orgID, email: "request-clerk@example.com", subject: "request-clerk",
                permissions: [.companyUpdate]
            )
            let stranger = try await signedMember(
                app, organizationID: orgID, email: "stranger@example.com", subject: "stranger",
                permissions: [.companyRead]
            )
            let other = try await makeTenant(app, code: "REQB", subject: "request-other")
            let created = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Renames", permission: .companyUpdate, stages: [(approvers.groupID, 1)])
            )
            try requireStatus(created, .ok)
            let pendingCompany = try #require(try await makeCompany(app, tenant: tenant, code: "PEND", name: "Pending Co").id)
            let appliedCompany = try #require(try await makeCompany(app, tenant: tenant, code: "DONE", name: "Done Co").id)
            let pending = try await rename(app, tenant: tenant, companyID: pendingCompany, name: "Still pending", token: clerk.token)
            let soonApplied = try await rename(app, tenant: tenant, companyID: appliedCompany, name: "Now applied", token: clerk.token)
            let applied = try await approve(app, tenant: tenant, requestID: soonApplied.id, member: approvers.members[0])
            #expect(applied.status == "applied")

            let listed = try await api(
                app, .GET, "approval-requests",
                token: tenant.admin.token, organizationID: orgID,
                query: "status=pending"
            )
            try requireStatus(listed, .ok)
            let page = try listed.content.decode(Page<GetApprovalRequestDTO>.self)
            #expect(try page.items.map { try #require($0.id) } == [pending.id])

            let own = try await api(
                app, .GET, "approval-requests/\(pending.id)",
                token: clerk.token, organizationID: orgID
            )
            try requireStatus(own, .ok)
            let ownBody = try own.content.decode(GetApprovalRequestDTO.self)
            #expect(ownBody.tracks.count == 1)
            #expect(ownBody.decisions.isEmpty)
            guard case .companyUpdate(let id, let before, let after) = ownBody.change else {
                Issue.record("Expected a company update")
                return
            }
            #expect(id == pendingCompany)
            #expect(before.name == "Pending Co")
            #expect(after.name == "Still pending")

            let eligible = try await api(
                app, .GET, "approval-requests/\(pending.id)",
                token: approvers.members[0].token, organizationID: orgID
            )
            try requireStatus(eligible, .ok)
            let unrelated = try await api(
                app, .GET, "approval-requests/\(pending.id)",
                token: stranger.token, organizationID: orgID
            )
            try requireStatus(unrelated, .forbidden)
            let foreign = try await api(
                app, .GET, "approval-requests/\(pending.id)",
                token: other.admin.token, organizationID: other.organizationID
            )
            try requireStatus(foreign, .notFound)
            let missing = try await api(
                app, .GET, "approval-requests/\(UUID())",
                token: stranger.token, organizationID: orgID
            )
            try requireStatus(missing, .notFound)

            let missingComment = try await api(
                app, .POST, "approval-requests/\(pending.id)/reject",
                token: approvers.members[0].token, organizationID: orgID,
                json: try json(ApprovalCommentDTO(comment: nil))
            )
            try requireStatus(missingComment, .badRequest)
            let rejected = try await api(
                app, .POST, "approval-requests/\(pending.id)/reject",
                token: approvers.members[0].token, organizationID: orgID,
                json: try json(ApprovalCommentDTO(comment: "No"))
            )
            try requireStatus(rejected, .ok)
            let rejectedBody = try rejected.content.decode(GetApprovalRequestDTO.self)
            #expect(rejectedBody.status == "rejected")
            #expect(rejectedBody.decisions.map(\.kind) == ["reject"])
            #expect(try await Company.find(pendingCompany, on: app.db)?.name == "Pending Co")

            let rejectCompany = try #require(try await makeCompany(app, tenant: tenant, code: "RJCT", name: "Reject later").id)
            let rejectRequest = try await rename(app, tenant: tenant, companyID: rejectCompany, name: "Nope", token: clerk.token)
            let strangerWithdraw = try await api(
                app, .POST, "approval-requests/\(rejectRequest.id)/withdraw",
                token: approvers.members[0].token, organizationID: orgID
            )
            try requireStatus(strangerWithdraw, .forbidden)
            try await withdraw(app, tenant: tenant, requestID: rejectRequest.id, token: clerk.token)
            let withdrawn = try await api(
                app, .GET, "approval-requests/\(rejectRequest.id)",
                token: clerk.token, organizationID: orgID
            )
            #expect(try withdrawn.content.decode(GetApprovalRequestDTO.self).status == "withdrawn")
            let late = try await api(
                app, .POST, "approval-requests/\(rejectRequest.id)/approve",
                token: approvers.members[0].token, organizationID: orgID
            )
            try requireStatus(late, .conflict)
        }
    }

    @Test("Override and the operator command complete a pending request")
    func approvalOverride() async throws {
        try await withApp { app in
            let tenant = try await makeTenant(app, code: "OVRA", subject: "override-admin")
            let orgID = tenant.organizationID
            let approvers = try await makePool(app, organizationID: orgID, name: "Approvers", prefix: "ovr", count: 1)
            let clerk = try await signedMember(
                app, organizationID: orgID, email: "override-clerk@example.com", subject: "override-clerk",
                permissions: [.companyUpdate, .approvalOverrideCreate]
            )
            let bystander = try await signedMember(
                app, organizationID: orgID, email: "bystander@example.com", subject: "bystander",
                permissions: [.companyRead]
            )
            let created = try await postPolicy(
                app, tenant: tenant,
                policy(
                    name: "Renames",
                    permission: .companyUpdate,
                    stages: [(approvers.groupID, 1)],
                    then: [(approvers.groupID, 1)]
                )
            )
            try requireStatus(created, .ok)

            let ownCompany = try #require(try await makeCompany(app, tenant: tenant, code: "SELF", name: "Self Co").id)
            let own = try await rename(app, tenant: tenant, companyID: ownCompany, name: "Self edit", token: clerk.token)
            let selfOverride = try await api(
                app, .POST, "approval-requests/\(own.id)/override",
                token: clerk.token, organizationID: orgID,
                json: try json(ApprovalOverrideDTO(reason: "mine"))
            )
            try requireStatus(selfOverride, .forbidden)
            #expect(try await Company.find(ownCompany, on: app.db)?.name == "Self Co")

            let openCompany = try #require(try await makeCompany(app, tenant: tenant, code: "OPEN", name: "Open Co").id)
            let open = try await rename(app, tenant: tenant, companyID: openCompany, name: "Opened", token: clerk.token)
            let withoutPermission = try await api(
                app, .POST, "approval-requests/\(open.id)/override",
                token: bystander.token, organizationID: orgID,
                json: try json(ApprovalOverrideDTO(reason: "nope"))
            )
            try requireStatus(withoutPermission, .forbidden)
            let withoutReason = try await api(
                app, .POST, "approval-requests/\(open.id)/override",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(ApprovalOverrideDTO(reason: " "))
            )
            try requireStatus(withoutReason, .badRequest)
            let overridden = try await api(
                app, .POST, "approval-requests/\(open.id)/override",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(ApprovalOverrideDTO(reason: "controller sign-off"))
            )
            try requireStatus(overridden, .ok)
            let overriddenBody = try overridden.content.decode(GetApprovalRequestDTO.self)
            #expect(overriddenBody.status == "applied")
            #expect(overriddenBody.decisions.map(\.kind) == ["override"])
            #expect(overriddenBody.tracks.allSatisfy { $0.status == "pending" })
            #expect(try await Company.find(openCompany, on: app.db)?.name == "Opened")
            #expect(try await Company.find(openCompany, on: app.db)?.$updatedBy.id == clerk.id)

            let stuckCompany = try #require(try await makeCompany(app, tenant: tenant, code: "STUCK", name: "Stuck Co").id)
            let stuck = try await rename(app, tenant: tenant, companyID: stuckCompany, name: "Unstuck", token: clerk.token)
            var context = CommandContext(
                console: app.console,
                input: CommandInput(arguments: [
                    "approval-override",
                    "--request", stuck.id.uuidString,
                    "--operator", "Pat Operator",
                    "--reason", "audit fix",
                ])
            )
            context.application = app
            try await ApprovalOverrideCommand().run(using: &context)
            let stuckSaved = try #require(try await Company.find(stuckCompany, on: app.db))
            #expect(stuckSaved.name == "Unstuck")
            #expect(stuckSaved.$updatedBy.id == clerk.id)
            let stuckRequest = try await ApprovalRequest.query(on: app.db)
                .filter(\.$id == stuck.id)
                .with(\.$decisions)
                .first()
            let decision = try #require(stuckRequest?.decisions.first)
            #expect(stuckRequest?.status == "applied")
            #expect(decision.kind == "override")
            #expect(decision.$decidedBy.id == nil)
            #expect(decision.operatorName == "Pat Operator")
            #expect(decision.comment == "audit fix")

            let decisionsBefore = try await ApprovalDecision.query(on: app.db).filter(\.$request.$id == stuck.id).count()
            var closed = CommandContext(
                console: app.console,
                input: CommandInput(arguments: [
                    "approval-override",
                    "--request", stuck.id.uuidString,
                    "--operator", "Pat Operator",
                    "--reason", "again",
                ])
            )
            closed.application = app
            await #expect(throws: ApprovalOverrideCommandError.self) {
                try await ApprovalOverrideCommand().run(using: &closed)
            }
            #expect(try await Company.find(stuckCompany, on: app.db)?.name == "Unstuck")
            #expect(try await ApprovalDecision.query(on: app.db).filter(\.$request.$id == stuck.id).count() == decisionsBefore)
        }
    }

    @Test("Held invitations wait for approval and die with the request")
    func heldInvitations() async throws {
        try await withApp { app in
            let tenant = try await makeTenant(app, code: "INVA", subject: "invite-admin")
            let orgID = tenant.organizationID
            let approvers = try await makePool(app, organizationID: orgID, name: "Approvers", prefix: "inv", count: 1)
            let admins = AccessGroup(organizationID: orgID, name: "Admins", createdByID: tenant.admin.id)
            try await admins.save(on: app.db)
            let adminsID = try admins.requireID()
            let joins = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Admin joins", permission: .groupMemberCreate, stages: [(approvers.groupID, 1)])
            )
            try requireStatus(joins, .ok)
            let intoAdmins = try await api(
                app, .POST, "organization-invitations",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(CreateInvitationDTO(email: "dee@acme.com", firstName: "Dee", lastName: "Acme", groupId: adminsID))
            )
            try requireStatus(intoAdmins, .accepted)
            #expect(try heldRequest(intoAdmins).tracks.map(\.definition.name) == ["Admin joins"])

            let created = try await postPolicy(
                app, tenant: tenant,
                policy(name: "Invites", permission: .organizationInvitationCreate, stages: [(approvers.groupID, 1)])
            )
            try requireStatus(created, .ok)

            let invited = try await api(
                app, .POST, "organization-invitations",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(CreateInvitationDTO(email: "bea@acme.com", firstName: "Bea", lastName: "Acme", groupId: nil))
            )
            try requireStatus(invited, .accepted)
            #expect(invited.headers[.cacheControl] == ["no-store"])
            let held = try heldRequest(invited)
            let token = try #require(held.invitation?.token)
            #expect(!token.isEmpty)
            let stored = try await OrganizationInvitation.query(on: app.db)
                .filter(\.$tokenHash == InvitationToken.hash(token))
                .first()
            #expect(stored?.tokenHash != token)
            #expect(stored?.$approvalRequest.id == held.id)

            let hidden = try await api(
                app, .GET, "approval-requests/\(held.id)",
                token: tenant.admin.token, organizationID: orgID
            )
            #expect(try hidden.content.decode(GetApprovalRequestDTO.self).invitation == nil)

            stubUserInfo(app, email: "bea@acme.com", emailVerified: true)
            let bea = try await signAccessToken(on: app, subject: "bea")
            let usersBefore = try await User.query(on: app.db).count()
            let early = try await api(app, .POST, "invitations/accept", token: bea, json: try json(AcceptInvitationDTO(token: token)))
            try requireStatus(early, .conflict)
            #expect(try await User.query(on: app.db).count() == usersBefore)

            let waiting = try #require(stored)
            waiting.expiresAt = Date().addingTimeInterval(-60)
            try await waiting.update(on: app.db)
            let applied = try await approve(app, tenant: tenant, requestID: held.id, member: approvers.members[0])
            #expect(applied.status == "applied")
            let accepted = try await api(app, .POST, "invitations/accept", token: bea, json: try json(AcceptInvitationDTO(token: token)))
            try requireStatus(accepted, .ok)
            let membership = try await OrganizationUser.query(on: app.db)
                .filter(\.$organization.$id == orgID)
                .join(User.self, on: \OrganizationUser.$user.$id == \User.$id)
                .filter(User.self, \.$email == "bea@acme.com")
                .first()
            #expect(membership != nil)

            let rejectedInvite = try await api(
                app, .POST, "organization-invitations",
                token: tenant.admin.token, organizationID: orgID,
                json: try json(CreateInvitationDTO(email: "cam@acme.com", firstName: "Cam", lastName: "Acme", groupId: nil))
            )
            try requireStatus(rejectedInvite, .accepted)
            let rejectedHeld = try heldRequest(rejectedInvite)
            let rejectedToken = try #require(rejectedHeld.invitation?.token)
            let rejection = try await api(
                app, .POST, "approval-requests/\(rejectedHeld.id)/reject",
                token: approvers.members[0].token, organizationID: orgID,
                json: try json(ApprovalCommentDTO(comment: "No"))
            )
            try requireStatus(rejection, .ok)
            stubUserInfo(app, email: "cam@acme.com", emailVerified: true)
            let cam = try await signAccessToken(on: app, subject: "cam")
            let tooLate = try await api(app, .POST, "invitations/accept", token: cam, json: try json(AcceptInvitationDTO(token: rejectedToken)))
            try requireStatus(tooLate, .notFound)
        }
    }
}

private struct Tenant {
    var organizationID: UUID
    var admin: SignedMember
}

private struct SignedMember {
    var id: UUID
    var token: String
}

private struct Pool {
    var groupID: UUID
    var members: [SignedMember]
}

private struct ApprovalTestFailure: Error, CustomStringConvertible {
    var description: String
}

private func makeTenant(_ app: Application, code: String, subject: String) async throws -> Tenant {
    let organization = try await createOrganization(on: app.db, code: code, name: code)
    let admin = try await signedMember(
        app,
        organizationID: try organization.requireID(),
        email: "\(subject)@example.com",
        subject: subject,
        permissions: Permission.allCases
    )
    return Tenant(organizationID: try organization.requireID(), admin: admin)
}

private func signedMember(
    _ app: Application,
    organizationID: UUID,
    email: String,
    subject: String,
    permissions: [Permission]
) async throws -> SignedMember {
    let user = try await createMember(
        on: app.db,
        organizationID: organizationID,
        email: email,
        subject: subject,
        permissions: permissions
    )
    return SignedMember(id: try user.requireID(), token: try await signAccessToken(on: app, subject: subject))
}

private func makePool(_ app: Application, organizationID: UUID, name: String, prefix: String, count: Int) async throws -> Pool {
    let group = AccessGroup(organizationID: organizationID, name: name, createdByID: nil)
    try await group.save(on: app.db)
    let groupID = try group.requireID()
    var members: [SignedMember] = []
    for index in 0..<count {
        let member = try await signedMember(
            app,
            organizationID: organizationID,
            email: "\(prefix)-\(index)@example.com",
            subject: "\(prefix)-\(index)",
            permissions: []
        )
        try await addToGroup(app, groupID: groupID, userID: member.id, organizationID: organizationID)
        members.append(member)
    }
    return Pool(groupID: groupID, members: members)
}

private func addToGroup(_ app: Application, groupID: UUID, userID: UUID, organizationID: UUID) async throws {
    let membership = try #require(try await OrganizationUser.query(on: app.db)
        .filter(\.$user.$id == userID)
        .filter(\.$organization.$id == organizationID)
        .first())
    try await GroupMember(groupID: groupID, organizationUserID: try membership.requireID(), createdByID: nil).save(on: app.db)
}

private func join(_ app: Application, tenant: Tenant, groupID: UUID, userID: UUID) async throws {
    let response = try await api(
        app, .POST, "groups/\(groupID)/members",
        token: tenant.admin.token, organizationID: tenant.organizationID,
        json: try json(AddGroupMemberDTO(userId: userID))
    )
    try requireStatus(response, .ok)
}

private func makeCompany(_ app: Application, tenant: Tenant, code: String, name: String) async throws -> GetCompanyDTO {
    let response = try await api(
        app, .POST, "companies",
        token: tenant.admin.token, organizationID: tenant.organizationID,
        json: try json(CreateCompanyDTO(code: code, name: name))
    )
    try requireStatus(response, .ok)
    return try response.content.decode(GetCompanyDTO.self)
}

private func makeRole(_ app: Application, tenant: Tenant, name: String, permissions: [String]) async throws -> GetRoleDTO {
    let response = try await api(
        app, .POST, "roles",
        token: tenant.admin.token, organizationID: tenant.organizationID,
        json: try json(CreateRoleDTO(name: name, level: "organization", permissions: permissions))
    )
    try requireStatus(response, .ok)
    return try response.content.decode(GetRoleDTO.self)
}

private func policy(
    name: String,
    permission: Permission,
    fields: [String] = [],
    companyId: UUID? = nil,
    stages first: [(UUID, Int)],
    then rest: [(UUID, Int)]...
) -> ApprovalPolicyDefinition {
    let stages = [first] + rest
    return ApprovalPolicyDefinition(
        name: name,
        permission: permission.rawValue,
        fields: fields,
        companyId: companyId,
        stages: stages.map { slots in
            ApprovalStageDTO(slots: slots.map { ApprovalSlotDTO(groupId: $0.0, required: $0.1) })
        }
    )
}

private func postPolicy(
    _ app: Application,
    tenant: Tenant,
    _ definition: ApprovalPolicyDefinition,
    token: String? = nil
) async throws -> TestingHTTPResponse {
    try await api(
        app, .POST, "approval-policies",
        token: token ?? tenant.admin.token,
        organizationID: tenant.organizationID,
        json: try json(definition)
    )
}

private struct HeldRequest {
    var id: UUID
    var status: String
    var failureReason: String?
    var tracks: [GetApprovalTrackDTO]
    var decisions: [GetApprovalDecisionDTO]
    var change: ProposedChange
    var invitation: CreateInvitationResponse?
}

private func heldRequest(_ response: TestingHTTPResponse) throws -> HeldRequest {
    let body = try response.content.decode(GetApprovalRequestDTO.self)
    return try HeldRequest(
        id: #require(body.id),
        status: body.status,
        failureReason: body.failureReason,
        tracks: body.tracks,
        decisions: body.decisions,
        change: body.change,
        invitation: body.invitation
    )
}

private func rename(
    _ app: Application,
    tenant: Tenant,
    companyID: UUID,
    name: String,
    token: String
) async throws -> HeldRequest {
    let response = try await api(
        app, .PATCH, "companies/\(companyID)",
        token: token, organizationID: tenant.organizationID,
        json: try json(PatchCompanyDTO(code: nil, name: name))
    )
    try requireStatus(response, .accepted)
    return try heldRequest(response)
}

private func approve(
    _ app: Application,
    tenant: Tenant,
    requestID: UUID,
    member: SignedMember
) async throws -> HeldRequest {
    let response = try await api(
        app, .POST, "approval-requests/\(requestID)/approve",
        token: member.token, organizationID: tenant.organizationID
    )
    try requireStatus(response, .ok)
    return try heldRequest(response)
}

private func withdraw(_ app: Application, tenant: Tenant, requestID: UUID, token: String) async throws {
    let response = try await api(
        app, .POST, "approval-requests/\(requestID)/withdraw",
        token: token, organizationID: tenant.organizationID
    )
    try requireStatus(response, .ok)
}

private func rolePermissions(_ app: Application, roleID: UUID) async throws -> [String] {
    try await RolePermission.query(on: app.db)
        .filter(\.$role.$id == roleID)
        .all()
        .map(\.permission)
        .sorted()
}

private func api(
    _ app: Application,
    _ method: HTTPMethod,
    _ path: String,
    token: String,
    organizationID: UUID? = nil,
    query: String? = nil,
    json: Data? = nil
) async throws -> TestingHTTPResponse {
    try await app.sendRequest(method, path, beforeRequest: { request in
        authorize(&request, token: token, organizationID: organizationID)
        if let query {
            request.url.query = query
        }
        if let json {
            request.headers.contentType = .json
            var body = ByteBufferAllocator().buffer(capacity: json.count)
            body.writeBytes(json)
            request.body = body
        }
    })
}

private func json<T: Encodable>(_ value: T) throws -> Data {
    try JSONEncoder().encode(value)
}

private func requireStatus(_ response: TestingHTTPResponse, _ status: HTTPStatus) throws {
    guard response.status == status else {
        var body = response.body
        let text = body.readString(length: body.readableBytes) ?? ""
        throw ApprovalTestFailure(description: "expected \(status.code), got \(response.status.code): \(text)")
    }
}

private func failureReason(_ response: TestingHTTPResponse) throws -> String {
    try response.content.decode(Problem.self, as: .json).detail
}
