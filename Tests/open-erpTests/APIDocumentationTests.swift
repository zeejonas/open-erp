@testable import open_erp
import Foundation
import Testing
import VaporTesting

@Suite("API documentation")
struct APIDocumentationTests {
    @Test("Swagger and the complete OpenAPI contract are available without a database")
    func documentation() async throws {
        let app = try await Application.make(.testing)
        do {
            configureProblemMiddleware(app)
            try routes(app)
            try await app.testing().test(.GET, "docs", afterResponse: { res async throws in
                #expect(res.status == .ok)
                #expect(res.headers.contentType == .html)
                #expect(res.body.string.contains("SwaggerUIBundle"))
                #expect(res.body.string.contains("url: '/openapi.json'"))
                #expect(res.body.string.contains("validatorUrl: null"))
            })
            try await app.testing().test(.GET, "openapi.json", afterResponse: { res async throws in
                #expect(res.status == .ok)
                let document = try #require(JSONSerialization.jsonObject(with: Data(res.body.readableBytesView)) as? [String: Any])
                let paths = try #require(document["paths"] as? [String: [String: [String: Any]]])
                #expect(paths["/docs"] == nil)
                #expect(paths["/openapi.json"] == nil)
                #expect(paths["/hello"] == nil)
                #expect(paths["/"] == nil)

                // Catch forgotten annotations and silent schema-generation failures on any route.
                for route in app.routes.all where !["/", "/hello", "/docs", "/openapi.json"].contains("/" + route.path.map(\.description).joined(separator: "/")) {
                    let path = "/" + route.path.map { component in
                        let value = component.description
                        return value.hasPrefix(":") ? "{\(value.dropFirst())}" : value
                    }.joined(separator: "/")
                    let operation = try #require(paths[path]?[route.method.rawValue.lowercased()])
                    #expect(operation["summary"] != nil)
                    #expect(operation["security"] != nil)
                    let responses = try #require(operation["responses"] as? [String: [String: Any]], "Missing responses: \(path)")
                    #expect(!responses.isEmpty)
                    for status in ["401", "500", "503"] + (path == "/auth/logout" ? [] : ["403"]) {
                        #expect(responses[status] != nil, "Missing problem response \(status): \(path)")
                    }
                    for (status, response) in responses where (Int(status) ?? 0) >= 400 {
                        let content = try #require(response["content"] as? [String: [String: Any]])
                        #expect(Set(content.keys) == ["application/problem+json"])
                        let schema = try #require(content["application/problem+json"]?["schema"] as? [String: Any])
                        #expect(schema["$ref"] as? String == "#/components/schemas/Problem")
                    }
                    if route.method != .DELETE && path != "/auth/logout" {
                        #expect(responses["200"]?["content"] != nil, "Missing response schema: \(path)")
                    }
                    if let pending = responses["202"] {
                        #expect(pending["content"] != nil, "Missing approval schema: \(path)")
                    }
                }
                #expect(paths["/platform/organizations"]?["post"]?["summary"] as? String == "Create organization")
                for path in ["/platform/organizations", "/platform/organizations/{organizationID}/admin-invitation/reissue"] {
                    let operation = try #require(paths[path]?["post"])
                    let params = operation["parameters"] as? [[String: Any]] ?? []
                    #expect(!params.contains { $0["name"] as? String == "X-Organization-ID" })
                    #expect(operation["security"] != nil)
                }
                let logout = try #require(paths["/auth/logout"]?["post"])
                #expect(logout["requestBody"] == nil)
                #expect((logout["parameters"] as? [[String: Any]] ?? []).isEmpty)
                let logoutSecurity = try #require(logout["security"] as? [[String: Any]])
                #expect(logoutSecurity.count == 1)
                let componentsForSecurity = try #require(document["components"] as? [String: Any])
                let schemes = try #require(componentsForSecurity["securitySchemes"] as? [String: [String: Any]])
                let schemeName = try #require(logoutSecurity.first?.keys.first)
                #expect(schemes[schemeName]?["type"] as? String == "http")
                #expect(schemes[schemeName]?["scheme"] as? String == "bearer")
                let logoutResponses = try #require(logout["responses"] as? [String: [String: Any]])
                #expect(logoutResponses["204"] != nil)
                #expect(logoutResponses["204"]?["content"] == nil)
                for status in ["400", "401", "503"] { #expect(logoutResponses[status] != nil) }
                #expect(logoutResponses["403"] == nil)
                let list = try #require(paths["/companies"]?["get"])
                let parameters = try #require(list["parameters"] as? [[String: Any]])
                #expect(Set(parameters.compactMap { $0["name"] as? String }) == ["page", "per", "code", "name", "X-Organization-ID"])
                let tenant = try #require(parameters.first { $0["name"] as? String == "X-Organization-ID" })
                #expect(tenant["required"] as? Bool == true)
                #expect(tenant["in"] as? String == "header")
                let meParameters = paths["/me"]?["get"]?["parameters"] as? [[String: Any]] ?? []
                #expect(!meParameters.contains { $0["name"] as? String == "X-Organization-ID" })

                let create = try #require(paths["/companies"]?["post"])
                #expect(create["requestBody"] != nil)
                let responses = try #require(create["responses"] as? [String: Any])
                #expect(responses["200"] != nil)
                #expect(responses["202"] != nil)
                for status in ["400", "409", "413", "415"] { #expect(responses[status] != nil) }
                #expect((paths["/companies/{companyID}"]?["get"]?["responses"] as? [String: Any])?["404"] != nil)
                let deletion = try #require(paths["/companies/{companyID}"]?["delete"]?["responses"] as? [String: [String: Any]])
                #expect(deletion["204"] != nil)
                #expect(deletion["204"]?["content"] == nil)
                #expect(deletion["202"] != nil)

                let components = try #require(document["components"] as? [String: Any])
                let schemas = try #require(components["schemas"] as? [String: [String: Any]])
                let problem = try #require(schemas["Problem"])
                let properties = try #require(problem["properties"] as? [String: Any])
                #expect(Set(properties.keys) == ["type", "title", "status", "detail", "code"])
                #expect(Set(problem["required"] as? [String] ?? []) == Set(properties.keys))
                let approval = try #require(schemas["GetApprovalRequestDTO"]?["properties"] as? [String: Any])
                #expect(Set(approval.keys) == ["id", "permission", "targetId", "status", "failureReason", "requestedBy", "change", "tracks", "decisions", "createdAt", "updatedAt", "invitation"])

                // Every generated local reference must resolve, including nested DTOs and enums.
                func checkReferences(_ value: Any) throws {
                    if let object = value as? [String: Any] {
                        if let reference = object["$ref"] as? String, reference.hasPrefix("#/") {
                            var target: Any = document
                            for part in reference.dropFirst(2).split(separator: "/") {
                                let key = String(part).replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
                                target = try #require((target as? [String: Any])?[key], "Unresolved reference: \(reference)")
                            }
                        }
                        for nested in object.values { try checkReferences(nested) }
                    } else if let array = value as? [Any] {
                        for nested in array { try checkReferences(nested) }
                    }
                }
                try checkReferences(document)
            })
            for path in ["me", "companies", "platform/organizations", "invitations/accept"] {
                let method: HTTPMethod = ["platform/organizations", "invitations/accept"].contains(path) ? .POST : .GET
                try await app.testing().test(method, path, afterResponse: { res async throws in
                    #expect(res.status == .unauthorized)
                    #expect(try res.content.decode(Problem.self, as: .json).code == .unauthorized)
                    #expect(res.headers[.wwwAuthenticate] == ["Bearer"])
                })
            }
        } catch {
            try await app.asyncShutdown()
            throw error
        }
        try await app.asyncShutdown()
    }
}
