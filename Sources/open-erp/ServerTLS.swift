import NIOSSL
import Vapor

/// Serves TLS in-process when both PEM files are configured (Vapor docs: Advanced → Server → TLS).
/// Errors name the variable and never include file contents.
func configureServerTLS(_ app: Application, lookup: (String) -> String?) throws {
    func path(_ name: String) -> String? {
        guard let value = lookup(name), !value.isEmpty else { return nil }
        return value
    }

    switch (path("HTTP_TLS_CERT_FILE"), path("HTTP_TLS_KEY_FILE")) {
    case (nil, nil):
        return
    case (_, nil):
        throw MissingEnvironmentVariable(name: "HTTP_TLS_KEY_FILE")
    case (nil, _):
        throw MissingEnvironmentVariable(name: "HTTP_TLS_CERT_FILE")
    case let (certFile?, keyFile?):
        let chain = try? NIOSSLCertificate.fromPEMFile(certFile)
        guard let chain, !chain.isEmpty else { throw DatabaseSettings.InvalidValue(name: "HTTP_TLS_CERT_FILE") }
        guard let key = try? NIOSSLPrivateKey(file: keyFile, format: .pem) else {
            throw DatabaseSettings.InvalidValue(name: "HTTP_TLS_KEY_FILE")
        }
        app.http.server.configuration.tlsConfiguration = .makeServerConfiguration(
            certificateChain: chain.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
    }
}
