@testable import open_erp
import Fluent
import SQLKit
import Testing
import VaporTesting

extension OpenERPTests {
    @Test("Every mapped table and catalog operation has explicit producer coverage")
    func businessEventProducerCoverage() async throws {
        try await withApp { app in
            let tables = try await app.db.requireSQL().raw("SELECT tablename FROM pg_tables WHERE schemaname = 'public' AND tablename <> '_fluent_migrations'").all()
            let actual = try Set(tables.map { try $0.decode(column: "tablename", as: String.self) })
            let eventTables = Set(BusinessEventClassification.eventResourcesByTable.keys)
            let nonEventTables = Set(BusinessEventClassification.nonEventReasonsByTable.keys)
            #expect(eventTables.isDisjoint(with: nonEventTables))
            #expect(actual == eventTables.union(nonEventTables))
            #expect(Set(BusinessEventClassification.eventResourcesByTable.values) == Set(BusinessResourceType.allCases))
            // These sets are asserted by their supported operation tests, not model insert fixtures.
            let tested = Set(BusinessProducerScenario.allCases.flatMap { $0.types })
            #expect(tested == Set(BusinessEventType.allCases))
        }
    }
    @Test("Apply operations emit one transition and ignore no-op updates", arguments: [
        BusinessResourceType.organization, .company, .role, .group, .approvalPolicy,
    ])
    func businessEventApplyOperations(resource: BusinessResourceType) async throws {
        try await withApp { app in
            let orgID = try await createOrganization(on: app.db, code: "PROD", name: "Before").requireID()
            let actorID = try await createUser(on: app.db, email: "producer@example.com").requireID()
            let context = AuditContext(actorType: .user, actorID: actorID, requestID: "producer-test")
            func apply(_ change: ProposedChange) async throws {
                _ = try await app.db.auditedTransaction(context) { db in
                    try await change.apply(on: db, actorID: actorID, organizationID: orgID)
                }
            }
            let id: UUID
            let noop: ProposedChange, update: ProposedChange, delete: ProposedChange
            let prior = CodeNameSnapshot(code: "PROD", name: "Before"), after = CodeNameSnapshot(code: "PROD", name: "After")
            switch resource {
            case .organization:
                id = orgID
                noop = .organizationUpdate(id: id, before: prior, after: prior)
                update = .organizationUpdate(id: id, before: prior, after: after)
                delete = .organizationDelete(id: id, before: after)
            case .company:
                try await apply(.companyCreate(prior))
                id = try #require(try await Company.query(on: app.db).first()).requireID()
                noop = .companyUpdate(id: id, before: prior, after: prior)
                update = .companyUpdate(id: id, before: prior, after: after)
                delete = .companyDelete(id: id, before: after)
            case .role:
                try await apply(.roleCreate(.init(name: "Before", level: "organization", permissions: [])))
                id = try #require(try await Role.query(on: app.db).first()).requireID()
                let before = RoleSnapshot(name: "Before", permissions: []), after = RoleSnapshot(name: "After", permissions: [])
                noop = .roleUpdate(id: id, before: before, after: before)
                update = .roleUpdate(id: id, before: before, after: after)
                delete = .roleDelete(id: id, before: after)
            case .group:
                try await apply(.groupCreate(name: "Before"))
                id = try #require(try await AccessGroup.query(on: app.db).first()).requireID()
                let before = GroupSnapshot(name: "Before"), after = GroupSnapshot(name: "After")
                noop = .groupUpdate(id: id, before: before, after: before)
                update = .groupUpdate(id: id, before: before, after: after)
                delete = .groupDelete(id: id, before: after)
            case .approvalPolicy:
                let group = AccessGroup(organizationID: orgID, name: "Approvers", createdByID: actorID)
                try await group.save(on: app.db)
                let membership = OrganizationUser(organizationID: orgID, userID: actorID)
                try await membership.save(on: app.db)
                try await GroupMember(organizationID: orgID, groupID: group.requireID(), organizationUserID: membership.requireID()).save(on: app.db)
                let before = ApprovalPolicyDefinition(name: "Before", permission: "company:update", fields: [], companyId: nil,
                    stages: [.init(slots: [.init(groupId: try group.requireID(), required: 1)])])
                var after = before
                after.name = "After"
                try await apply(.approvalPolicyCreate(before))
                id = try #require(try await ApprovalPolicy.query(on: app.db).first()).requireID()
                noop = .approvalPolicyUpdate(id: id, before: before, after: before)
                update = .approvalPolicyUpdate(id: id, before: before, after: after)
                delete = .approvalPolicyDelete(id: id, before: after)
            default: Issue.record("Unsupported CRUD fixture"); return
            }
            let beforeCount = try await BusinessEvent.query(on: app.db).count()
            try await apply(noop)
            #expect(try await BusinessEvent.query(on: app.db).count() == beforeCount)
            try await apply(update)
            try await apply(delete)
            let events = try await BusinessEvent.query(on: app.db).filter(\.$resourceID == id).sort(\.$revision).all()
            let transitions = resource == .organization ? ["updated", "deleted"] : ["created", "updated", "deleted"]
            #expect(events.map { $0.type.rawValue } == transitions.map { "\(resource.rawValue).\($0)" })
            #expect(events.map(\.revision) == Array(1...Int64(events.count)))
            #expect(events.allSatisfy { $0.actorID == actorID && $0.requestID == "producer-test" })
            #expect(events.first { $0.type.rawValue.hasSuffix("updated") }?.changedFields == ["name"])
            #expect(events.allSatisfy { ($0.companyID != nil) == (resource == .company) })
            let deletedPayload = try #require(events.last?.payload)
            let object = try #require(JSONSerialization.jsonObject(with: deletedPayload) as? [String: Any])
            #expect((object["data"] as? [String: Any])?["deleted"] as? Bool == true)
            try await expectProducedEvents(BusinessProducerScenario.crudTypes(resource), on: app.db)
        }
    }
}

enum BusinessProducerScenario: CaseIterable {
    case company, organization, role, group, policy, groupMembership, assignments, memberRemoval
    case provisioning, invitations, onboarding, restoration, approvalApply, approvalRequests, approvalOverride

    static func crudTypes(_ resource: BusinessResourceType) -> Set<BusinessEventType> {
        Set(BusinessEventType.allCases.filter { $0.resourceType == resource && (resource != .organization || $0 == .organizationUpdated || $0 == .organizationDeleted) })
    }

    var types: Set<BusinessEventType> {
        switch self {
        case .company: Self.crudTypes(.company)
        case .organization: Self.crudTypes(.organization)
        case .role: Self.crudTypes(.role)
        case .group: Self.crudTypes(.group)
        case .policy: Self.crudTypes(.approvalPolicy)
        case .groupMembership: [.groupMemberCreated, .groupMemberDeleted]
        case .assignments: [.groupRoleCreated, .groupRoleDeleted, .groupCompanyCreated, .groupCompanyDeleted]
        case .memberRemoval: [.organizationUserDeleted]
        case .provisioning: [.organizationCreated, .roleCreated, .groupCreated, .groupRoleCreated, .invitationIssued]
        case .invitations: [.invitationIssued, .invitationAccepted, .invitationRevoked, .organizationUserCreated]
        case .onboarding: [.invitationReissued, .invitationAccepted, .groupMemberCreated]
        case .restoration: [.organizationRestored]
        case .approvalApply: [.approvalRequestCreated, .approvalDecisionRecorded, .approvalRequestApplied, .approvalRequestFailed, .companyUpdated]
        case .approvalRequests: [.approvalRequestRejected, .approvalRequestWithdrawn]
        case .approvalOverride: [.approvalRequestOverridden]
        }
    }
}

func expectProducedEvents(_ scenario: BusinessProducerScenario, on db: any Database) async throws {
    try await expectProducedEvents(scenario.types, on: db)
}

/// Used by API operation tests, so declaring coverage also verifies its producer ran.
func expectProducedEvents(_ types: Set<BusinessEventType>, on db: any Database) async throws {
    let events = try await BusinessEvent.query(on: db).all()
    let produced = Set(events.map(\.type))
    for type in types { #expect(produced.contains(type), "Missing emitting operation for \(type.rawValue)") }
    let counts = Dictionary(grouping: events.filter { $0.type.rawValue.hasSuffix(".created") || $0.type.rawValue.hasSuffix(".deleted") }, by: { "\($0.type.rawValue):\($0.resourceID)" })
    #expect(counts.values.allSatisfy { $0.count == 1 }, "One semantic event per logical transition")
    for event in events {
        switch event.resourceType {
        case .groupMember:
            #expect(try await GroupMember.query(on: db).withDeleted().filter(\.$id == event.resourceID).first() != nil)
        case .groupRole:
            #expect(try await GroupRole.query(on: db).withDeleted().filter(\.$id == event.resourceID).first() != nil)
        case .groupCompany:
            #expect(try await GroupCompany.query(on: db).withDeleted().filter(\.$id == event.resourceID).first() != nil)
        case .organizationUser:
            #expect(try await OrganizationUser.query(on: db).withDeleted().filter(\.$id == event.resourceID).first() != nil)
        default: break
        }
        let json = String(decoding: event.payload, as: UTF8.self)
        #expect(!json.contains("token_hash") && !json.contains("auth_subject") && !json.contains("operatorName"))
    }
}
