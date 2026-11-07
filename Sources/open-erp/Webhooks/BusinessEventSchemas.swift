import VaporToOpenAPI

enum BusinessEventSchemas {
    static func summary(_ resource: BusinessResourceType) -> SchemaObject {
        var fields: ComponentsMap<SchemaObject> = [:]
        for field in resource.summaryFields {
            switch field {
            case "deleted": fields[field] = .boolean
            case "currentVersion": fields[field] = .integer
            case "expiresAt": fields[field] = .string(format: "date-time")
            case "level": fields[field] = .enum(RoleLevel.self)
            case "decisionKind": fields[field] = .enum(ApprovalDecisionKind.self).with(\.nullable, true)
            case "status":
                fields[field] = resource == .approvalRequest ? .enum(ApprovalRequestStatus.self) : .enum(cases: ["pending", "accepted", "revoked"])
            default:
                if field.hasSuffix("Id") {
                    let nullable = field == "targetId" || field == "decisionId" || (field == "groupId" && resource == .invitation)
                    fields[field] = .string(format: "uuid").with(\.nullable, nullable)
                } else { fields[field] = .string }
            }
        }
        return closedObject(fields)
    }

    static var envelope: SchemaObject {
        .init(context: .composition(.one(of: BusinessEventType.allCases.map { .value(envelope($0)) })))
    }

    private static func envelope(_ event: BusinessEventType) -> SchemaObject {
        closedObject([
            "id": .string(format: "uuid"), "type": .enum(cases: [.string(event.rawValue)]),
            "schemaVersion": .enum(of: .integer, cases: [.int(1)]), "occurredAt": .string(format: "date-time"),
            "organizationId": .string(format: "uuid"), "companyId": .string(format: "uuid").with(\.nullable, true),
            "resource": .value(closedObject(["type": .enum(cases: [.string(event.resourceType.rawValue)]), "id": .string(format: "uuid"), "revision": .integer])),
            "actor": .value(closedObject(["type": .enum(AuditActorType.self), "id": .string(format: "uuid").with(\.nullable, true)])),
            "requestedById": .string(format: "uuid").with(\.nullable, true),
            "requestId": .string.with(\.nullable, true), "approvalRequestId": .string(format: "uuid").with(\.nullable, true),
            "changedFields": .array(of: .string), "data": .value(summary(event.resourceType)),
        ])
    }

    private static func closedObject(_ properties: ComponentsMap<SchemaObject>) -> SchemaObject {
        .init(context: .object(.init(properties: properties, additionalProperties: false, required: Set(properties.keys))))
    }
}
