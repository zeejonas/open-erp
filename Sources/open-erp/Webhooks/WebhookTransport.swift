import AsyncHTTPClient
import Foundation
import NIOCore
import NIOConcurrencyHelpers
import NIOPosix
import NIOSSL
import Vapor
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

enum WebhookTransportError: Error, Equatable { case unsafeDestination, resolutionFailed, network }

struct WebhookHTTPResult: Sendable {
    let status: Int
    let retryAfter: String?
}

/// Native resolver results are all vetted; the HTTP client receives one numeric address, not a
/// second hostname lookup. The original URL continues to control Host, TLS verification and SNI.
struct WebhookTransport: Sendable {
    let eventLoopGroup: any EventLoopGroup
    let threadPool: NIOThreadPool
    var resolveAddresses: @Sendable (String) throws -> [String] = WebhookTransport.resolve

    func send(url: String, body: Data, headers: HTTPHeaders) async throws -> WebhookHTTPResult {
        try Task.checkCancellation()
        _ = try WebhookDestination.validate(url)
        guard let host = URL(string: url)?.host else { throw WebhookTransportError.unsafeDestination }
        let deadline = NIODeadline.now() + .seconds(10)
        let addresses = try await resolve(host, deadline: deadline)
        try Task.checkCancellation()
        guard !addresses.isEmpty else { throw WebhookTransportError.resolutionFailed }
        guard addresses.allSatisfy(Self.isPublicAddress) else { throw WebhookTransportError.unsafeDestination }
        guard NIODeadline.now() < deadline else { throw WebhookTransportError.network }
        return try await sendVetted(url: url, address: addresses[0], body: body, headers: headers, deadline: deadline)
    }

    /// A slow native resolver must not retain an attempt slot after its deadline or cancellation.
    /// The shared bounded thread pool owns the native call until it returns; no unchecked result is used later.
    private func resolve(_ host: String, deadline: NIODeadline) async throws -> [String] {
        let loop = eventLoopGroup.next()
        let promise = loop.makePromise(of: [String].self)
        let completed = NIOLockedValueBox(false)
        let finish: @Sendable (Result<[String], any Error>) -> Void = { result in
            let first = completed.withLockedValue { value in
                if value { return false }
                value = true
                return true
            }
            if first { promise.completeWith(result) }
        }
        let timeout = loop.scheduleTask(deadline: deadline) { finish(.failure(WebhookTransportError.network)) }
        threadPool.runIfActive(eventLoop: loop) { try resolveAddresses(host) }.whenComplete(finish)
        return try await withTaskCancellationHandler {
            defer { timeout.cancel() }
            return try await promise.futureResult.get()
        } onCancel: {
            finish(.failure(CancellationError()))
        }
    }

    /// Separated for a local TLS fixture. Production callers can only enter through send's vetting.
    func sendVetted(url: String, address: String, body: Data, headers: HTTPHeaders, deadline: NIODeadline, tlsConfiguration: TLSConfiguration? = nil) async throws -> WebhookHTTPResult {
        guard let host = URL(string: url)?.host else { throw WebhookTransportError.unsafeDestination }
        var config = HTTPClient.Configuration(tlsConfiguration: tlsConfiguration, redirectConfiguration: .disallow, timeout: .init(connect: .seconds(10), read: .seconds(10)))
        config.dnsOverride = [host: address]
        let client = HTTPClient(eventLoopGroupProvider: .shared(eventLoopGroup), configuration: config)
        do {
            var request = HTTPClientRequest(url: url)
            request.method = .POST
            request.headers = headers
            request.body = .bytes(body)
            let result = try await responseHead(client, request: request, deadline: deadline)
            // No arbitrary response body or headers are retained. Shutdown cancels unread streaming data.
            try await client.shutdown()
            return result
        } catch {
            try? await client.shutdown()
            if Task.isCancelled { throw CancellationError() }
            throw WebhookTransportError.network
        }
    }

    private func responseHead(_ client: HTTPClient, request: HTTPClientRequest, deadline: NIODeadline) async throws -> WebhookHTTPResult {
        let response = try await client.execute(request, deadline: deadline)
        // Releasing the streaming response cancels unconsumed body data before client shutdown.
        return WebhookHTTPResult(status: Int(response.status.code), retryAfter: response.headers.first(name: "Retry-After"))
    }

    static func resolve(_ host: String) throws -> [String] {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = Int32(SOCK_STREAM.rawValueForPlatform)
        var result: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &result) == 0, let head = result else {
            throw WebhookTransportError.resolutionFailed
        }
        defer { freeaddrinfo(head) }
        var cursor: UnsafeMutablePointer<addrinfo>? = head
        var addresses: Set<String> = []
        while let current = cursor {
            var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(current.pointee.ai_addr, current.pointee.ai_addrlen, &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST) == 0 else {
                throw WebhookTransportError.resolutionFailed
            }
            addresses.insert(String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
            cursor = current.pointee.ai_next
        }
        return addresses.sorted()
    }

    static func isPublicAddress(_ address: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, address, &v4) == 1 {
            let bytes = withUnsafeBytes(of: v4) { Array($0) }
            let a = Int(bytes[0]), b = Int(bytes[1]), c = Int(bytes[2])
            if a == 0 || a == 10 || a == 127 || a >= 224 { return false }
            if a == 100 && (64...127).contains(b) { return false }
            if a == 169 && b == 254 || a == 172 && (16...31).contains(b) { return false }
            if a == 192 && (b == 168 || b == 0 && (c == 0 || c == 2) || b == 88 && c == 99) { return false }
            if a == 198 && (b == 18 || b == 19 || b == 51 && c == 100) { return false }
            if a == 203 && b == 0 && c == 113 { return false }
            if address == "168.63.129.16" { return false } // Azure platform virtual address.
            return true
        }
        var v6 = in6_addr()
        guard inet_pton(AF_INET6, address, &v6) == 1 else { return false }
        let bytes = withUnsafeBytes(of: v6) { Array($0) }
        guard bytes[0] & 0xe0 == 0x20 else { return false } // Only global unicast, 2000::/3.
        if bytes[0] == 0x20 && bytes[1] == 0x01 {
            if bytes[2] < 2 { return false } // IETF special-use 2001::/23.
            if bytes[2] == 0x0d && bytes[3] == 0xb8 { return false }
        }
        if bytes[0] == 0x20 && bytes[1] == 0x02 { return false } // 6to4 embeds IPv4.
        if bytes[0] == 0x3f && bytes[1] == 0xff && bytes[2] & 0xf0 == 0 { return false }
        return true
    }
}

#if canImport(Darwin)
private extension Int32 { var rawValueForPlatform: Int32 { self } }
#else
private extension __socket_type { var rawValueForPlatform: UInt32 { rawValue } }
#endif
