import Fluent
import Vapor

private let duplicateCompany = "A company with this code already exists"
private let duplicateOrganization = "An organization with this code already exists"
private let duplicateRole = "A role with this name already exists"
private let duplicateGroup = "A group with this name already exists"
private let duplicateMember = "User is already a member of this group"
private let duplicateGroupRole = "Group already holds this role"
private let duplicateGroupCompany = "Group is already eligible at this company"
private let duplicatePolicy = "An approval policy with this name already exists"

extension ProposedChange {
    func check(on db: any Database, organizationID: UUID) async throws {
        switch self {
        case .organizationUserDelete, .groupMemberDelete, .groupRoleDelete,
             .roleUpdate, .approvalPolicyCreate, .approvalPolicyUpdate:
            _ = try await lockOrganization(organizationID, on: db)
        default:
            break
        }

        switch self {
        case .webhookSubscriptionCreate(let config):
            _ = try await lockOrganization(organizationID, on: db)
            guard !config.enabled else { throw Abort(.badRequest, reason: "Subscriptions must be created disabled") }
            guard try await WebhookSubscription.query(on: db).filter(\.$organization.$id == organizationID).count() < 100 else {
                throw Abort(.conflict, reason: "Organization webhook subscription limit reached")
            }
            try await WebhookSubscriptionService.validate(config, organizationID: organizationID, on: db)
        case .webhookSubscriptionUpdate(let id, let expected, _, let config, _):
            let (subscription, _) = try await WebhookSubscriptionService.require(id, organizationID: organizationID, lock: true, on: db)
            try throwIfStale(subscription.currentRevisionID != expected)
            try await WebhookSubscriptionService.validate(config, organizationID: organizationID, on: db)
        case .webhookSubscriptionDelete(let id, let expected):
            let (subscription, _) = try await WebhookSubscriptionService.require(id, organizationID: organizationID, lock: true, on: db)
            try throwIfStale(subscription.currentRevisionID != expected)
        case .organizationUpdate(let id, let before, let after):
            let organization = try await requireOrganization(id, on: db)
            try throwIfStale(before.code != after.code && organization.code != before.code)
            try throwIfStale(before.name != after.name && organization.name != before.name)
        case .organizationDelete(let id, _):
            _ = try await requireOrganization(id, on: db)
        case .companyCreate:
            break
        case .companyUpdate(let id, let before, let after):
            let company = try await requireCompany(id, organizationID: organizationID, on: db)
            try throwIfStale(before.code != after.code && company.code != before.code)
            try throwIfStale(before.name != after.name && company.name != before.name)
        case .companyDelete(let id, _):
            _ = try await requireCompany(id, organizationID: organizationID, on: db)
            if try await ApprovalPolicy.query(on: db, organizationID: organizationID).filter(\.$company.$id == id).first() != nil {
                throw Abort(.conflict, reason: "Company is the scope of an active approval policy")
            }
        case .organizationUserDelete(let userID):
            _ = try await requireMembership(userID: userID, organizationID: organizationID, on: db)
            try await checkAccessReduction(organizationID: organizationID, on: db, checkPolicies: true) {
                $0.removeMember(userID)
            }
        case .organizationInvitationCreate(let draft):
            if let groupID = draft.groupId {
                try await requireActiveGroup(groupID, organizationID: organizationID, on: db)
            }
            if let invitationID = draft.invitationId {
                guard let invitation = try await OrganizationInvitation.query(on: db, organizationID: organizationID)
                    .filter(\.$id == invitationID)
                    .filter(\.$acceptedAt == nil)
                    .first()
                else {
                    throw Abort(.conflict, reason: "Invitation is no longer pending")
                }
                if let groupID = invitation.$group.id {
                    guard try await AccessGroup.query(on: db, organizationID: organizationID).filter(\.$id == groupID).first() != nil else {
                        throw Abort(.badRequest, reason: "Invitation group is not an active group in this organization")
                    }
                }
            }
        case .organizationInvitationDelete(let id):
            _ = try await requireOpenInvitation(id, organizationID: organizationID, on: db)
        case .roleCreate(let draft):
            _ = try resolvedPermissions(draft.permissions, level: draft.level)
        case .roleUpdate(let id, let before, let after):
            let role = try await requireRole(id, organizationID: organizationID, on: db)
            try await role.$permissionGrants.load(on: db)
            let current = Set(role.permissionGrants.map(\.permission))
            try throwIfStale(before.name != after.name && role.name != before.name)
            try throwIfStale(Set(before.permissions) != Set(after.permissions) && current != Set(before.permissions))
            if Set(before.permissions) != Set(after.permissions) {
                let permissions = try resolvedPermissions(after.permissions, level: role.level)
                if !current.isSubset(of: Set(after.permissions)) {
                    try await checkAccessReduction(organizationID: organizationID, on: db) {
                        $0.replaceRolePermissions(id, with: Set(permissions))
                    }
                }
            }
        case .roleDelete(let id, _):
            let role = try await requireRole(id, organizationID: organizationID, on: db)
            if try await role.isInUse(on: db) {
                throw Abort(.conflict, reason: "Role is attached to an active group")
            }
        case .groupCreate:
            break
        case .groupUpdate(let id, let before, let after):
            let group = try await requireGroup(id, organizationID: organizationID, on: db)
            try throwIfStale(before.name != after.name && group.name != before.name)
        case .groupDelete(let id, _):
            // Locked so onboarding recovery cannot issue an invitation into the group while it is deleted.
            guard let group = try await lockGroup(id, organizationID: organizationID, on: db) else {
                throw Abort(.notFound)
            }
            if try await policyUsesGroup(id, on: db) {
                throw Abort(.conflict, reason: "Group is an approver pool for an active approval policy")
            }
            if try await group.isInUse(on: db) {
                throw Abort(.conflict, reason: "Group has active members or pending invitations")
            }
        case .groupMemberCreate(let draft):
            _ = try await requireGroup(draft.groupId, organizationID: organizationID, on: db)
            _ = try await requireMembership(userID: draft.userId, organizationID: organizationID, on: db)
        case .groupMemberDelete(let draft):
            _ = try await requireGroupMember(draft, organizationID: organizationID, on: db)
            try await checkAccessReduction(organizationID: organizationID, on: db, checkPolicies: true) {
                $0.removeGroupMember(draft.userId, from: draft.groupId)
            }
        case .groupRoleCreate(let draft):
            _ = try await requireGroup(draft.groupId, organizationID: organizationID, on: db)
            guard try await Role.query(on: db, organizationID: organizationID).filter(\.$id == draft.roleId).first() != nil else {
                throw Abort(.badRequest, reason: "Role must belong to this organization")
            }
        case .groupRoleDelete(let draft):
            _ = try await requireGroupRole(draft, on: db)
            try await checkAccessReduction(organizationID: organizationID, on: db) {
                $0.removeGroupRole(draft.roleId, from: draft.groupId)
            }
        case .groupCompanyCreate(let draft):
            _ = try await requireGroup(draft.groupId, organizationID: organizationID, on: db)
            guard try await Company.query(on: db, organizationID: organizationID).filter(\.$id == draft.companyId).first() != nil else {
                throw Abort(.badRequest, reason: "Company must belong to this organization")
            }
        case .groupCompanyDelete(let draft):
            _ = try await requireGroupCompany(draft, on: db)
        case .approvalPolicyCreate(let definition):
            try await validatePolicy(definition, on: db, organizationID: organizationID)
        case .approvalPolicyUpdate(let id, let before, let after):
            let policy = try await requirePolicy(id, organizationID: organizationID, on: db)
            guard after.permission == policy.permission else {
                throw Abort(.badRequest, reason: "A policy's permission cannot change")
            }
            try await policy.$slots.load(on: db)
            let current = policy.currentDefinition()
            let changed = after.changedFields(from: before)
            try throwIfStale(changed.contains("name") && current.name != before.normalized().name)
            try throwIfStale(changed.contains("fields") && Set(current.fields) != Set(before.normalized().fields))
            try throwIfStale(changed.contains("companyId") && current.companyId != before.normalized().companyId)
            try throwIfStale(changed.contains("stages") && current.stages != before.normalized().stages)
            let after = after.normalized()
            var result = current
            if changed.contains("name") { result.name = after.name }
            if changed.contains("fields") { result.fields = after.fields }
            if changed.contains("companyId") { result.companyId = after.companyId }
            if changed.contains("stages") { result.stages = after.stages }
            try await validatePolicy(result, on: db, organizationID: organizationID)
        case .approvalPolicyDelete(let id, _):
            _ = try await requirePolicy(id, organizationID: organizationID, on: db)
        }
    }

    func apply(on db: any Database, actorID: UUID, organizationID: UUID) async throws -> ApprovalWriteResult {
        switch self {
        case .webhookSubscriptionCreate(let config):
            return ApprovalWriteResult(try await WebhookSubscriptionService.create(config, organizationID: organizationID, actorID: actorID, on: db))
        case .webhookSubscriptionUpdate(let id, _, let before, let config, let rotate):
            let (subscription, prior) = try await WebhookSubscriptionService.require(id, organizationID: organizationID, lock: true, on: db)
            subscription.currentRevisionID = UUID()
            let revision = try await WebhookSubscriptionService.append(config, to: subscription, prior: prior, rotate: rotate, actorID: actorID, on: db)
            if config.enabled && (!before.enabled || changedFields().contains("enabled")) {
                subscription.disabledReason = nil
                subscription.disabledAt = nil
                subscription.disabledBy = nil
                subscription.disabledActorType = nil
                subscription.disabledActorName = nil
                subscription.failingSince = nil
            }
            subscription.updatedBy = actorID
            subscription.updatedAt = try await WebhookSubscriptionService.transactionTime(on: db)
            try await subscription.update(on: db)
            try await WebhookRevocation.cancelUnauthorized(subscription: subscription, current: revision, on: db)
            return ApprovalWriteResult(try WebhookSubscriptionDTO(subscription, revision: revision))
        case .webhookSubscriptionDelete(let id, _):
            let (subscription, _) = try await WebhookSubscriptionService.require(id, organizationID: organizationID, lock: true, on: db)
            try await WebhookRevocation.cancelQueued(subscriptionID: id, reason: .subscriptionDeleted, on: db)
            subscription.deletedBy = actorID
            try await subscription.update(on: db)
            try await subscription.delete(on: db)
            return ApprovalWriteResult(HTTPStatus.noContent)
        case .organizationUpdate(let id, let before, let after):
            let organization = try await requireOrganization(id, on: db)
            if before.code != after.code { organization.code = after.code }
            if before.name != after.name { organization.name = after.name }
            organization.$updatedBy.id = actorID
            try await conflictOnDuplicate(duplicateOrganization) {
                try await organization.update(on: db)
            }
            if !changedFields().isEmpty { try await organization.emit(.organizationUpdated, changedFields: changedFields(), on: db) }
            return ApprovalWriteResult(organization.toGetDTO())
        case .organizationDelete(let id, _):
            let organization = try await requireOrganization(id, on: db)
            try await WebhookRevocation.disableOrganization(id, on: db)
            try await organization.softDelete(by: actorID, \.$deletedBy, on: db)
            try await organization.emit(.organizationDeleted, on: db)
            return ApprovalWriteResult(HTTPStatus.noContent)
        case .companyCreate(let snapshot):
            let company = Company(
                code: snapshot.code,
                name: snapshot.name,
                organizationID: organizationID,
                createdBy: nil,
                updatedBy: nil,
                deletedBy: nil
            )
            company.$createdBy.id = actorID
            try await conflictOnDuplicate(duplicateCompany) {
                try await company.save(on: db)
            }
            try await company.emit(.companyCreated, on: db)
            return ApprovalWriteResult(company.toGetDTO())
        case .companyUpdate(let id, let before, let after):
            let company = try await requireCompany(id, organizationID: organizationID, on: db)
            if before.code != after.code { company.code = after.code }
            if before.name != after.name { company.name = after.name }
            company.$updatedBy.id = actorID
            try await conflictOnDuplicate(duplicateCompany) {
                try await company.update(on: db)
            }
            if !changedFields().isEmpty { try await company.emit(.companyUpdated, changedFields: changedFields(), on: db) }
            return ApprovalWriteResult(company.toGetDTO())
        case .companyDelete(let id, _):
            let company = try await requireCompany(id, organizationID: organizationID, on: db)
            let companyID = try company.requireID()
            for link in try await GroupCompany.query(on: db).filter(\.$company.$id == companyID).all() {
                try await link.softDelete(by: actorID, \.$deletedBy, on: db)
                try await link.emit(.groupCompanyDeleted, on: db)
            }
            try await company.softDelete(by: actorID, \.$deletedBy, on: db)
            try await company.emit(.companyDeleted, on: db)
            return ApprovalWriteResult(HTTPStatus.noContent)
        case .organizationUserDelete(let userID):
            let membership = try await requireMembership(userID: userID, organizationID: organizationID, on: db)
            let membershipID = try membership.requireID()
            for groupMembership in try await GroupMember.query(on: db).filter(\.$organizationUser.$id == membershipID).all() {
                try await groupMembership.softDelete(by: actorID, \.$deletedBy, on: db)
                try await groupMembership.emit(.groupMemberDeleted, on: db)
            }
            try await membership.softDelete(by: actorID, \.$deletedBy, on: db)
            try await membership.emit(.organizationUserDeleted, on: db)
            return ApprovalWriteResult(HTTPStatus.noContent)
        case .organizationInvitationCreate(let draft):
            if let invitationID = draft.invitationId {
                guard let invitation = try await OrganizationInvitation.find(invitationID, on: db) else {
                    throw Abort(.conflict, reason: "Invitation is no longer pending")
                }
                invitation.expiresAt = Date().addingTimeInterval(InvitationToken.lifetime)
                try await invitation.update(on: db)
                try await invitation.emit(.invitationIssued, on: db)
                return ApprovalWriteResult(CreateInvitationResponse(invitation: invitation.toGetDTO(), token: ""))
            }
            let (invitation, token) = try await OrganizationInvitation.issue(
                organizationID: organizationID,
                email: draft.email,
                firstName: draft.firstName,
                lastName: draft.lastName,
                groupID: draft.groupId,
                createdByID: actorID,
                on: db
            )
            try await invitation.emit(.invitationIssued, on: db)
            return ApprovalWriteResult(CreateInvitationResponse(invitation: invitation.toGetDTO(), token: token))
        case .organizationInvitationDelete(let id):
            let invitation = try await requireOpenInvitation(id, organizationID: organizationID, on: db)
            try await invitation.softDelete(by: actorID, \.$deletedBy, on: db)
            try await invitation.emit(.invitationRevoked, on: db)
            return ApprovalWriteResult(HTTPStatus.noContent)
        case .roleCreate(let draft):
            let permissions = try resolvedPermissions(draft.permissions, level: draft.level)
            let role = try await conflictOnDuplicate(duplicateRole) {
                let role = Role(
                    organizationID: organizationID,
                    name: draft.name,
                    level: RoleLevel(rawValue: draft.level) ?? .organization,
                    createdByID: actorID
                )
                try await role.save(on: db)
                try await role.setPermissions(permissions, actorID: actorID, on: db)
                return role
            }
            try await role.emit(.roleCreated, on: db)
            return ApprovalWriteResult(role.toGetDTO())
        case .roleUpdate(let id, let before, let after):
            let role = try await requireRole(id, organizationID: organizationID, on: db)
            let saved = try await conflictOnDuplicate(duplicateRole) {
                if Set(before.permissions) != Set(after.permissions) {
                    let permissions = try resolvedPermissions(after.permissions, level: role.level)
                    try await role.setPermissions(permissions, actorID: actorID, on: db)
                } else {
                    try await role.$permissionGrants.load(on: db)
                }
                if before.name != after.name {
                    role.name = after.name
                }
                role.$updatedBy.id = actorID
                try await role.update(on: db)
                return role
            }
            if !changedFields().isEmpty { try await saved.emit(.roleUpdated, changedFields: changedFields(), on: db) }
            return ApprovalWriteResult(saved.toGetDTO())
        case .roleDelete(let id, _):
            let role = try await requireRole(id, organizationID: organizationID, on: db)
            try await role.softDelete(by: actorID, \.$deletedBy, on: db)
            try await role.emit(.roleDeleted, on: db)
            return ApprovalWriteResult(HTTPStatus.noContent)
        case .groupCreate(let name):
            let group = AccessGroup(organizationID: organizationID, name: name, createdByID: actorID)
            try await conflictOnDuplicate(duplicateGroup) {
                try await group.save(on: db)
            }
            try await group.loadAssignments(on: db)
            try await group.emit(.groupCreated, on: db)
            return ApprovalWriteResult(group.toGetDTO())
        case .groupUpdate(let id, let before, let after):
            let group = try await requireGroup(id, organizationID: organizationID, on: db)
            if before.name != after.name {
                group.name = after.name
            }
            group.$updatedBy.id = actorID
            try await conflictOnDuplicate(duplicateGroup) {
                try await group.update(on: db)
            }
            try await group.loadAssignments(on: db)
            if !changedFields().isEmpty { try await group.emit(.groupUpdated, changedFields: changedFields(), on: db) }
            return ApprovalWriteResult(group.toGetDTO())
        case .groupDelete(let id, _):
            let group = try await requireGroup(id, organizationID: organizationID, on: db)
            for link in try await GroupRole.query(on: db).filter(\.$group.$id == id).all() {
                try await link.softDelete(by: actorID, \.$deletedBy, on: db)
                try await link.emit(.groupRoleDeleted, on: db)
            }
            for link in try await GroupCompany.query(on: db).filter(\.$group.$id == id).all() {
                try await link.softDelete(by: actorID, \.$deletedBy, on: db)
                try await link.emit(.groupCompanyDeleted, on: db)
            }
            try await group.softDelete(by: actorID, \.$deletedBy, on: db)
            try await group.emit(.groupDeleted, on: db)
            return ApprovalWriteResult(HTTPStatus.noContent)
        case .groupMemberCreate(let draft):
            let membership = try await requireMembership(userID: draft.userId, organizationID: organizationID, on: db)
            let groupMembership = GroupMember(
                organizationID: organizationID,
                groupID: draft.groupId,
                organizationUserID: try membership.requireID(),
                createdByID: actorID
            )
            try await conflictOnDuplicate(duplicateMember) {
                try await groupMembership.save(on: db)
            }
            try await groupMembership.emit(.groupMemberCreated, on: db)
            return ApprovalWriteResult(groupMembership.toGetDTO(userID: draft.userId))
        case .groupMemberDelete(let draft):
            let groupMembership = try await requireGroupMember(draft, organizationID: organizationID, on: db)
            try await groupMembership.softDelete(by: actorID, \.$deletedBy, on: db)
            try await groupMembership.emit(.groupMemberDeleted, on: db)
            return ApprovalWriteResult(HTTPStatus.noContent)
        case .groupRoleCreate(let draft):
            let link = GroupRole(organizationID: organizationID, groupID: draft.groupId, roleID: draft.roleId, createdByID: actorID)
            try await conflictOnDuplicate(duplicateGroupRole) {
                try await link.save(on: db)
            }
            try await link.emit(.groupRoleCreated, on: db)
            return ApprovalWriteResult(link.toGetDTO())
        case .groupRoleDelete(let draft):
            let link = try await requireGroupRole(draft, on: db)
            try await link.softDelete(by: actorID, \.$deletedBy, on: db)
            try await link.emit(.groupRoleDeleted, on: db)
            return ApprovalWriteResult(HTTPStatus.noContent)
        case .groupCompanyCreate(let draft):
            let link = GroupCompany(organizationID: organizationID, groupID: draft.groupId, companyID: draft.companyId, createdByID: actorID)
            try await conflictOnDuplicate(duplicateGroupCompany) {
                try await link.save(on: db)
            }
            try await link.emit(.groupCompanyCreated, on: db)
            return ApprovalWriteResult(link.toGetDTO())
        case .groupCompanyDelete(let draft):
            let link = try await requireGroupCompany(draft, on: db)
            try await link.softDelete(by: actorID, \.$deletedBy, on: db)
            try await link.emit(.groupCompanyDeleted, on: db)
            return ApprovalWriteResult(HTTPStatus.noContent)
        case .approvalPolicyCreate(let definition):
            let definition = definition.normalized()
            let policy = try await conflictOnDuplicate(duplicatePolicy) {
                let policy = ApprovalPolicy(
                    organizationID: organizationID,
                    name: definition.name,
                    permission: definition.permission,
                    fields: definition.fields,
                    companyID: definition.companyId,
                    currentVersion: 1,
                    createdByID: actorID
                )
                try await policy.save(on: db)
                let policyID = try policy.requireID()
                try await replacePolicySlots(for: policy, stages: definition.stages, actorID: actorID, on: db)
                try await ApprovalPolicyVersion(
                    organizationID: organizationID,
                    policyID: policyID,
                    version: 1,
                    definition: definition,
                    createdByID: actorID
                ).save(on: db)
                try await policy.$slots.load(on: db)
                return policy
            }
            try await policy.emit(.approvalPolicyCreated, on: db)
            return ApprovalWriteResult(policy.toGetDTO())
        case .approvalPolicyUpdate(let id, let before, let after):
            let policy = try await requirePolicy(id, organizationID: organizationID, on: db)
            try await policy.$slots.load(on: db)
            var result = policy.currentDefinition()
            let changed = after.changedFields(from: before)
            let after = after.normalized()
            if changed.contains("name") {
                policy.name = after.name
                result.name = after.name
            }
            if changed.contains("fields") {
                policy.fields = after.fields
                result.fields = after.fields
            }
            if changed.contains("companyId") {
                policy.$company.id = after.companyId
                result.companyId = after.companyId
            }
            if changed.contains("stages") {
                try await replacePolicySlots(for: policy, stages: after.stages, actorID: actorID, on: db)
                result.stages = after.stages
            }
            policy.currentVersion += 1
            policy.$updatedBy.id = actorID
            let saved = try await conflictOnDuplicate(duplicatePolicy) {
                try await policy.save(on: db)
                try await ApprovalPolicyVersion(
                    organizationID: organizationID,
                    policyID: try policy.requireID(),
                    version: policy.currentVersion,
                    definition: result.normalized(),
                    createdByID: actorID
                ).save(on: db)
                try await policy.$slots.load(on: db)
                return policy
            }
            if !changedFields().isEmpty { try await saved.emit(.approvalPolicyUpdated, changedFields: changedFields(), on: db) }
            return ApprovalWriteResult(saved.toGetDTO())
        case .approvalPolicyDelete(let id, _):
            let policy = try await requirePolicy(id, organizationID: organizationID, on: db)
            try await policy.softDelete(by: actorID, \.$deletedBy, on: db)
            try await policy.emit(.approvalPolicyDeleted, on: db)
            return ApprovalWriteResult(HTTPStatus.noContent)
        }
    }
}

private func resolvedPermissions(_ raw: [String], level: String) throws -> [Permission] {
    guard let roleLevel = RoleLevel(rawValue: level) else {
        throw Abort(.badRequest, reason: "level must be organization or company")
    }
    return try permissions(from: raw, level: roleLevel)
}

private func requireOrganization(_ id: UUID, on db: any Database) async throws -> Organization {
    guard let organization = try await Organization.find(id, on: db) else {
        throw Abort(.notFound)
    }
    return organization
}

private func requireCompany(_ id: UUID, organizationID: UUID, on db: any Database) async throws -> Company {
    guard let company = try await Company.query(on: db, organizationID: organizationID).filter(\.$id == id).first() else {
        throw Abort(.notFound)
    }
    return company
}

private func requireRole(_ id: UUID, organizationID: UUID, on db: any Database) async throws -> Role {
    guard let role = try await Role.query(on: db, organizationID: organizationID).filter(\.$id == id).first() else {
        throw Abort(.notFound)
    }
    return role
}

private func requireGroup(_ id: UUID, organizationID: UUID, on db: any Database) async throws -> AccessGroup {
    guard let group = try await AccessGroup.query(on: db, organizationID: organizationID).filter(\.$id == id).first() else {
        throw Abort(.notFound)
    }
    return group
}

private func requirePolicy(_ id: UUID, organizationID: UUID, on db: any Database) async throws -> ApprovalPolicy {
    guard let policy = try await ApprovalPolicy.query(on: db, organizationID: organizationID).filter(\.$id == id).first() else {
        throw Abort(.notFound)
    }
    return policy
}

private func requireMembership(userID: UUID, organizationID: UUID, on db: any Database) async throws -> OrganizationUser {
    guard let membership = try await OrganizationUser.query(on: db, organizationID: organizationID)
        .filter(\.$user.$id == userID)
        .first()
    else {
        throw Abort(.notFound)
    }
    return membership
}

private func requireActiveGroup(_ groupID: UUID, organizationID: UUID, on db: any Database) async throws {
    guard try await AccessGroup.query(on: db, organizationID: organizationID).filter(\.$id == groupID).first() != nil else {
        throw Abort(.badRequest, reason: "Group must be an active group in this organization")
    }
}

private func requireOpenInvitation(_ id: UUID, organizationID: UUID, on db: any Database) async throws -> OrganizationInvitation {
    guard let invitation = try await OrganizationInvitation.query(on: db, organizationID: organizationID)
        .filter(\.$id == id)
        .filter(\.$acceptedAt == nil)
        .first()
    else {
        throw Abort(.notFound)
    }
    return invitation
}

private func requireGroupMember(_ draft: GroupMemberDraft, organizationID: UUID, on db: any Database) async throws -> GroupMember {
    guard let groupMembership = try await GroupMember.query(on: db)
        .join(OrganizationUser.self, on: \GroupMember.$organizationUser.$id == \OrganizationUser.$id)
        .filter(\.$group.$id == draft.groupId)
        .filter(OrganizationUser.self, \.$user.$id == draft.userId)
        .filter(OrganizationUser.self, \.$organization.$id == organizationID)
        .filter(OrganizationUser.self, \.$deletedAt == nil)
        .first()
    else {
        throw Abort(.notFound)
    }
    return groupMembership
}

private func requireGroupRole(_ draft: GroupRoleDraft, on db: any Database) async throws -> GroupRole {
    guard let link = try await GroupRole.query(on: db)
        .filter(\.$group.$id == draft.groupId)
        .filter(\.$role.$id == draft.roleId)
        .first()
    else {
        throw Abort(.notFound)
    }
    return link
}

private func requireGroupCompany(_ draft: GroupCompanyDraft, on db: any Database) async throws -> GroupCompany {
    guard let link = try await GroupCompany.query(on: db)
        .filter(\.$group.$id == draft.groupId)
        .filter(\.$company.$id == draft.companyId)
        .first()
    else {
        throw Abort(.notFound)
    }
    return link
}
