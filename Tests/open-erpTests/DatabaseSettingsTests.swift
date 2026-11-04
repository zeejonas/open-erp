@testable import open_erp
import Foundation
import Testing

struct DatabaseSettingsTests {
    private let production = [
        "DATABASE_HOST": "database.example",
        "DATABASE_USERNAME": "app",
        "DATABASE_PASSWORD": "configured-secret",
        "DATABASE_NAME": "erp",
    ]

    @Test(arguments: ["DATABASE_HOST", "DATABASE_USERNAME", "DATABASE_PASSWORD", "DATABASE_NAME"])
    func missingProductionSetting(name: String) {
        for value in [nil, ""] as [String?] {
            #expect(throws: MissingEnvironmentVariable.self) {
                do {
                    _ = try DatabaseSettings(testing: false) { $0 == name ? value : production[$0] }
                } catch {
                    #expect(String(describing: error) == "Missing \(name)")
                    throw error
                }
            }
        }
    }

    @Test(arguments: [
        ("DATABASE_PORT", "0"), ("DATABASE_PORT", "65536"), ("DATABASE_PORT", "invalid"),
        ("DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP", "-1"), ("DATABASE_TLS_MODE", "prefer"),
    ])
    func invalidSetting(name: String, value: String) {
        #expect(throws: DatabaseSettings.InvalidValue.self) {
            do {
                _ = try DatabaseSettings(testing: false) { $0 == name ? value : production[$0] }
            } catch {
                #expect(String(describing: error) == "Invalid \(name)")
                throw error
            }
        }
    }

    @Test(arguments: ["require", "disable"], ["garbage", "empty", "directory", "missing"])
    func invalidCAFile(mode: String, kind: String) throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: directory) }

        let path = kind == "directory" ? directory : directory.appendingPathComponent("ca.pem")
        switch kind {
        case "garbage": try Data("not a certificate".utf8).write(to: path)
        case "empty": try Data().write(to: path)
        default: break
        }
        let settings = try DatabaseSettings(testing: false) {
            ["DATABASE_TLS_MODE": mode, "DATABASE_CA_FILE": path.path][$0] ?? production[$0]
        }

        #expect(throws: DatabaseSettings.InvalidValue.self) {
            do {
                _ = try settings.postgresConfiguration()
            } catch {
                #expect(String(describing: error) == "Invalid DATABASE_CA_FILE")
                throw error
            }
        }
    }

    @Test func validCAFile() throws {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: path) }
        let pem = """
        -----BEGIN CERTIFICATE-----
        MIIBaTCCARCgAwIBAgIUG1ChARs9t9pFQdLlRq864elyG6AwCgYIKoZIzj0EAwIw
        GzEZMBcGA1UEAwwQb3Blbi1lcnAtdGVzdC1jYTAeFw0yNjExMDQxMzI1MjhaFw0z
        NjExMDExMzI1MjhaMBsxGTAXBgNVBAMMEG9wZW4tZXJwLXRlc3QtY2EwWTATBgcq
        hkjOPQIBBggqhkjOPQMBBwNCAARxzfSoDY8EAZq88n+bx2ixTuh3OXqcf8BC+70B
        UabDQoSmhdWb5peeoS7vA3U4iON+caAGTFPIKmFsc5lYY/q1ozIwMDAdBgNVHQ4E
        FgQUGO2kiE+8A4ZNGMjIJUV11wOS93EwDwYDVR0TAQH/BAUwAwEB/zAKBggqhkjO
        PQQDAgNHADBEAiByp27VuGMBOMjkTYrEBK4wFi2Hw64JKrGOIT3EwhqIQAIgDCbh
        DAKSnK8NELUKGaUTLVws4PeaRdqxxTctYneKJIU=
        -----END CERTIFICATE-----
        """
        try Data(pem.utf8).write(to: path)
        let settings = try DatabaseSettings(testing: false) {
            ["DATABASE_TLS_MODE": "require", "DATABASE_CA_FILE": path.path][$0] ?? production[$0]
        }
        _ = try settings.postgresConfiguration()
    }

    @Test func defaults() throws {
        let local = try DatabaseSettings(testing: true) { _ in nil }
        #expect(local.hostname == "localhost")
        #expect(local.port == 5432)
        #expect(local.tlsMode == .disable)
        #expect(try DatabaseSettings(testing: false) { production[$0] }.tlsMode == .require)
    }
}
