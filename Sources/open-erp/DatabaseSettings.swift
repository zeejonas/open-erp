import FluentPostgresDriver
import NIOSSL

struct DatabaseSettings {
    enum TLSMode: String {
        case require, disable
    }

    struct InvalidValue: Error, CustomStringConvertible {
        let name: String
        var description: String { "Invalid \(name)" }
    }

    let hostname: String
    let port: Int
    let username: String
    let password: String
    let database: String
    let maxConnectionsPerEventLoop: Int
    let tlsMode: TLSMode
    let caFile: String?

    init(testing: Bool, lookup: (String) -> String?) throws {
        func required(_ name: String, testingDefault: String) throws -> String {
            if let value = lookup(name), !value.isEmpty { return value }
            if testing { return testingDefault }
            throw MissingEnvironmentVariable(name: name)
        }

        func positiveInteger(_ name: String, defaultValue: Int) throws -> Int {
            guard let raw = lookup(name) else { return defaultValue }
            guard let value = Int(raw), value > 0 else { throw InvalidValue(name: name) }
            return value
        }

        hostname = try required("DATABASE_HOST", testingDefault: "localhost")
        username = try required("DATABASE_USERNAME", testingDefault: "vapor_username")
        password = try required("DATABASE_PASSWORD", testingDefault: "vapor_password")
        database = try required("DATABASE_NAME", testingDefault: "vapor_database")
        port = try positiveInteger("DATABASE_PORT", defaultValue: SQLPostgresConfiguration.ianaPortNumber)
        guard port <= 65535 else { throw InvalidValue(name: "DATABASE_PORT") }
        maxConnectionsPerEventLoop = try positiveInteger("DATABASE_MAX_CONNECTIONS_PER_EVENT_LOOP", defaultValue: 4)
        let mode = lookup("DATABASE_TLS_MODE") ?? (testing ? "disable" : "require")
        guard let tlsMode = TLSMode(rawValue: mode) else { throw InvalidValue(name: "DATABASE_TLS_MODE") }
        self.tlsMode = tlsMode
        caFile = lookup("DATABASE_CA_FILE")
    }

    func postgresConfiguration() throws -> SQLPostgresConfiguration {
        var configuration = TLSConfiguration.makeClientConfiguration()
        var customContext: NIOSSLContext?
        if let caFile {
            configuration.trustRoots = .file(caFile)
            do {
                customContext = try NIOSSLContext(configuration: configuration)
            } catch {
                throw InvalidValue(name: "DATABASE_CA_FILE")
            }
        }

        let tls: PostgresConnection.Configuration.TLS
        switch tlsMode {
        case .require:
            tls = .require(try customContext ?? NIOSSLContext(configuration: configuration))
        case .disable:
            tls = .disable
        }
        return .init(hostname: hostname, port: port, username: username, password: password, database: database, tls: tls)
    }
}
