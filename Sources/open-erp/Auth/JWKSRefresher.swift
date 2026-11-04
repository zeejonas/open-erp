import JWT
import NIOConcurrencyHelpers
import Vapor

private struct SigningKeysLoadedKey: StorageKey {
    typealias Value = NIOLockedValueBox<Bool>
}

extension Application {
    func initializeSigningKeyState() {
        storage[SigningKeysLoadedKey.self] = NIOLockedValueBox(false)
    }

    var signingKeysLoaded: Bool {
        get { storage[SigningKeysLoadedKey.self]?.withLockedValue { $0 } ?? false }
        set { storage[SigningKeysLoadedKey.self]?.withLockedValue { $0 = newValue } }
    }
}

struct JWKSRefresher: LifecycleHandler {
    private struct RefreshTask: StorageKey {
        typealias Value = Task<Void, Never>
    }

    /// Decodes each entry separately, because `JWKS` rejects the whole set over one unsupported key.
    private struct KeySet: Decodable {
        struct Entry: Decodable {
            let key: JWK?
            init(from decoder: any Decoder) { key = try? JWK(from: decoder) }
        }
        let keys: [Entry]
    }

    let fetch: @Sendable (Application) async throws -> Data

    func refresh(_ app: Application) async {
        do {
            let entries = try JSONDecoder().decode(KeySet.self, from: await fetch(app)).keys
            let replacement = JWTKeyCollection()
            var loaded = 0
            for entry in entries {
                if let key = entry.key, await add(key, to: replacement) { loaded += 1 }
            }
            guard loaded > 0 else {
                throw AuthenticationConfigurationError(message: "JWKS contains no usable keys")
            }
            try Task.checkCancellation()
            app.jwt.keys = replacement
            app.signingKeysLoaded = true
            if loaded < entries.count {
                app.logger.notice("Ignored unusable JWKS entries", metadata: ["ignored": "\(entries.count - loaded)"])
            }
        } catch {
            if !Task.isCancelled {
                app.logger.error("Signing key refresh failed", metadata: ["error": "\(String(reflecting: error))"])
            }
        }
    }

    private func add(_ key: JWK, to keys: JWTKeyCollection) async -> Bool {
        guard let algorithm = signingAlgorithm(for: key) else { return false }
        do {
            // JWTKit can defer signer construction until verification. Check that the
            // key is usable without fixing the algorithm for keys that omit it.
            let probe = JWTKeyCollection()
            try await probe.add(jwk: key)
            _ = try await probe.getKey(alg: algorithm.rawValue)
            try await keys.add(jwk: key)
            return true
        } catch {
            return false
        }
    }

    private func signingAlgorithm(for key: JWK) -> JWK.Algorithm? {
        if let algorithm = key.algorithm {
            return algorithm == .rsaOAEP ? nil : algorithm
        }
        switch key.keyType {
        case .rsa: return .rs256
        case .octetKeyPair: return .eddsa
        case .ecdsa:
            switch key.curve?.rawValue {
            case "P-256": return .es256
            case "P-384": return .es384
            case "P-521": return .es512
            default: return nil
            }
        default: return nil
        }
    }

    func didBootAsync(_ app: Application) async throws {
        app.storage[RefreshTask.self] = Task {
            while !Task.isCancelled {
                await refresh(app)
                do {
                    try await Task.sleep(for: app.signingKeysLoaded ? .seconds(300) : .seconds(30))
                } catch {
                    return
                }
            }
        }
    }

    func shutdownAsync(_ app: Application) async {
        let task = app.storage[RefreshTask.self]
        task?.cancel()
        await task?.value
        app.storage[RefreshTask.self] = nil
    }
}
