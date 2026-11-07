@testable import open_erp
import Foundation
import Testing
import VaporTesting

@Suite("OpenAPI export")
struct OpenAPIExportTests {
    @Test("Offline command exports deterministic JSON matching the HTTP contract")
    func export() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        var exports: [Data] = []
        for name in ["first.json", "second.json"] {
            let destination = directory.appendingPathComponent(name)
            let app = try await Application.make(Environment(name: "production", arguments: [
                "open-erp", "export-openapi", destination.path,
            ]))
            do {
                try configureAPI(app)
                try await app.execute()
                let data = try Data(contentsOf: destination)
                exports.append(data)
                let document = try #require(JSONSerialization.jsonObject(with: data) as? NSDictionary)
                let paths = try #require(document["paths"] as? [String: [String: Any]])
                #expect(paths.values.reduce(0) { $0 + $1.count } == 76)
                let components = try #require(document["components"] as? [String: Any])
                let schemas = try #require(components["schemas"] as? [String: [String: Any]])
                let audit = try #require(schemas["AuditEventDTO"])
                let properties = try #require(audit["properties"] as? [String: Any])
                #expect(Set(properties.keys) == Set([
                    "id", "createdAt", "organizationId", "table", "recordId", "operation",
                    "changedFields", "oldValues", "newValues", "actorType", "actorId", "actorName",
                    "ipAddress", "requestId", "approvalRequestId", "databaseUser", "transactionId",
                ]))
                #expect((audit["required"] as? [String])?.contains("transactionId") == true)
                #expect(schemas["AuditActorType"]?["enum"] as? [String] == [
                    "user", "platform_admin", "operator", "system", "database",
                ])
                try await app.testing().test(.GET, "openapi.json", afterResponse: { response async throws in
                    #expect(response.status == .ok)
                    let http = try #require(JSONSerialization.jsonObject(with: Data(response.body.readableBytesView)) as? NSDictionary)
                    #expect(document == http)
                })
            } catch {
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
        }
        #expect(exports[0] == exports[1])
    }

    @Test("Missing and unwritable destinations fail without leaving partial files")
    func invalidDestination() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        // A directory cannot be replaced by JSON; a missing parent cannot accept a file.
        for arguments in [[], [directory.path], [directory.appendingPathComponent("missing/openapi.json").path]] {
            let app = try await Application.make(Environment(name: "production", arguments: [
                "open-erp", "export-openapi",
            ] + arguments))
            do {
                try configureAPI(app)
                await #expect(throws: (any Error).self) {
                    try await app.execute()
                }
            } catch {
                try await app.asyncShutdown()
                throw error
            }
            try await app.asyncShutdown()
            #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        }
    }
}
