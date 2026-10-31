import Vapor
import VaporToOpenAPI

extension Route {
    /// Every authenticated operation can fail authentication, authorization, or internally.
    @discardableResult
    func problemResponses(_ statuses: HTTPStatus..., excluding excluded: Set<HTTPStatus> = []) -> Route {
        for status in [HTTPStatus.unauthorized, .forbidden, .internalServerError, .serviceUnavailable] + statuses
        where !excluded.contains(status) {
            response(
                statusCode: .code(Int(status.code)),
                body: .type(Problem.self),
                contentType: .init(HTTPMediaType.problemJSON.serialize()),
                description: status.reasonPhrase
            )
        }
        return self
    }
}

func registerAPIDocumentation(_ app: Application) {
    app.get("openapi.json") { req in
        req.application.routes.openAPI(
            info: InfoObject(
                title: "open-erp API",
                description: """
                Enterprise software without the robbery.

                Use Authorize to enter an OIDC bearer access token. Organization endpoints also
                require X-Organization-ID and membership with the stated permission. Authentication
                failures return 401; insufficient access returns 403. Resources outside the selected
                organization are not accessible.

                Approval-controlled writes return 202 with an approval request when held for review.
                Otherwise they return the applied resource (200), or an empty response (204) for deletes.
                """,
                version: "0.1.0"
            )
        )
    }.excludeFromOpenAPI()

    app.get("docs") { _ in
        Response(status: .ok, headers: ["Content-Type": "text/html; charset=utf-8"], body: .init(string: """
        <!doctype html>
        <html lang="en">
        <head>
          <meta charset="utf-8">
          <meta name="viewport" content="width=device-width, initial-scale=1">
          <title>open-erp API</title>
          <link rel="stylesheet" href="https://unpkg.com/swagger-ui-dist@5.32.0/swagger-ui.css">
        </head>
        <body>
          <div id="swagger-ui"></div>
          <script src="https://unpkg.com/swagger-ui-dist@5.32.0/swagger-ui-bundle.js"></script>
          <script>
            SwaggerUIBundle({
              url: '/openapi.json',
              dom_id: '#swagger-ui',
              deepLinking: true,
              validatorUrl: null,
              persistAuthorization: false
            });
          </script>
        </body>
        </html>
        """))
    }.excludeFromOpenAPI()
}

/// A required tenant selector, separate from bearer authentication.
struct OrganizationHeaders: Decodable {
    var organizationID: UUID

    enum CodingKeys: String, CodingKey {
        case organizationID = "X-Organization-ID"
    }
}

// ProposedChange decodes according to its permission, so reflection cannot infer its schema.
extension ProposedChange: OpenAPIType {
    static var openAPISchema: SchemaObject {
        .object(
            properties: [
                "permission": .string,
                "targetId": .string(format: "uuid"),
                "before": .dictionary(of: .any),
                "after": .dictionary(of: .any),
            ],
            required: ["permission"]
        )
    }
}

// The generator's documented example-based fallback avoids running ProposedChange's validating decoder.
extension GetApprovalRequestDTO: WithExample {
    static var example: Self {
        .init(
            id: nil,
            permission: Permission.companyCreate.rawValue,
            targetId: nil,
            status: ApprovalRequestStatus.pending.rawValue,
            failureReason: nil,
            requestedBy: UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)),
            change: .companyCreate(.init(code: "ACME", name: "Example Company")),
            tracks: [],
            decisions: [],
            createdAt: nil,
            updatedAt: nil,
            invitation: nil
        )
    }
}
