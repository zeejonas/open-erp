@testable import open_erp
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

    @Test func defaults() throws {
        let local = try DatabaseSettings(testing: true) { _ in nil }
        #expect(local.hostname == "localhost")
        #expect(local.port == 5432)
        #expect(local.tlsMode == .disable)
        #expect(try DatabaseSettings(testing: false) { production[$0] }.tlsMode == .require)
    }
}
