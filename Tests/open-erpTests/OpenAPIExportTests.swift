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
