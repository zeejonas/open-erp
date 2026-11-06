import Foundation
import NIOCore
import Vapor

struct TrustedProxyCount: StorageKey {
    typealias Value = Int

    static func parse(_ raw: String?) throws -> Int {
        guard let raw else { return 0 }
        guard let count = Int(raw), count >= 0 else {
            throw DatabaseSettings.InvalidValue(name: "TRUSTED_PROXY_COUNT")
        }
        return count
    }
}

extension Request {
    var auditClientIP: String? {
        let count = application.storage[TrustedProxyCount.self] ?? 0
        let remoteIP = remoteAddress?.ipAddress
        guard count > 0 else { return remoteIP }

        let forwarded = headers["X-Forwarded-For"].flatMap {
            $0.split(separator: ",", omittingEmptySubsequences: false)
        }
        guard let hop = forwarded.reversed().dropFirst(count - 1).first else { return remoteIP }
        let address = hop.trimmingCharacters(in: .whitespaces)
        return (try? SocketAddress(ipAddress: address, port: 0))?.ipAddress ?? remoteIP
    }
}
