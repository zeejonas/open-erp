@testable import open_erp
import Foundation
import NIOCore
import NIOHTTP1
import NIOPosix
import NIOSSL
import Testing
import Vapor
import Dispatch

@Suite("Webhook destination transport")
struct WebhookTransportTests {
    @Test("Cancellation releases an attempt while native DNS resolution remains blocked")
    func cancellationDuringDNS() async throws {
        let app = try await Application.make(.testing)
        let release = DispatchSemaphore(value: 0)
        let started = NIOLockedValueBox(false)
        var transport = WebhookTransport(eventLoopGroup: app.eventLoopGroup, threadPool: app.threadPool)
        transport.resolveAddresses = { _ in
            started.withLockedValue { $0 = true }
            release.wait()
            return ["8.8.8.8"]
        }
        let configured = transport
        let task = Task { try await configured.send(url: "https://receiver.example", body: Data(), headers: [:]) }
        while !started.withLockedValue({ $0 }) { await Task.yield() }
        let began = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(began) < 2)
        release.signal()
        try await app.asyncShutdown()
    }
    @Test("Non-public and metadata addresses are blocked", arguments: [
        "0.0.0.0", "10.1.2.3", "127.0.0.1", "100.64.0.1", "100.100.100.200", "169.254.169.254",
        "172.16.0.1", "172.31.255.255", "192.168.1.1", "192.0.0.1", "192.0.2.1", "192.88.99.1",
        "198.18.0.1", "198.51.100.1", "203.0.113.1", "224.0.0.1", "255.255.255.255", "168.63.129.16",
        "::", "::1", "::ffff:127.0.0.1", "fc00::1", "fd00:ec2::254", "fe80::1", "ff02::1",
        "64:ff9b::7f00:1", "2001::1", "2001:db8::1", "2002:7f00:1::", "3fff::1", "invalid",
    ])
    func blocked(address: String) { #expect(!WebhookTransport.isPublicAddress(address)) }

    @Test("Ordinary global unicast addresses pass", arguments: ["1.1.1.1", "8.8.8.8", "93.184.216.34", "2606:4700:4700::1111", "2001:4860:4860::8888"])
    func publicAddress(address: String) { #expect(WebhookTransport.isPublicAddress(address)) }

    @Test("Vetted DNS override preserves original-host TLS, refuses redirects and shuts down")
    func tlsFixture() async throws {
        let app = try await Application.make(.testing)
        let certURL = try #require(Bundle.module.url(forResource: "receiver-cert", withExtension: "pem", subdirectory: "Webhooks"))
        let keyURL = try #require(Bundle.module.url(forResource: "receiver-key", withExtension: "pem", subdirectory: "Webhooks"))
        let certs = try NIOSSLCertificate.fromPEMFile(certURL.path)
        let privateKey = try NIOSSLPrivateKey(file: keyURL.path, format: .pem)
        let context = try NIOSSLContext(configuration: .makeServerConfiguration(certificateChain: certs.map(NIOSSLCertificateSource.certificate), privateKey: .privateKey(privateKey)))
        let requests = WebhookTLSCapture()
        let server = try await ServerBootstrap(group: app.eventLoopGroup)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NIOSSLServerHandler(context: context)).flatMap {
                    channel.pipeline.configureHTTPServerPipeline()
                }.flatMap { channel.pipeline.addHandler(WebhookTLSReceiver(capture: requests)) }
            }.bind(host: "127.0.0.1", port: 0).get()
        do {
            let port = try #require(server.localAddress?.port)
            let transport = WebhookTransport(eventLoopGroup: app.eventLoopGroup, threadPool: app.threadPool)
            var trust = TLSConfiguration.makeClientConfiguration()
            trust.trustRoots = .certificates(certs)
            let began = Date()
            let result = try await transport.sendVetted(url: "https://receiver.example:\(port)/redirect", address: "127.0.0.1",
                body: Data("exact bytes".utf8), headers: ["Content-Type": "application/json"], deadline: .now() + .seconds(10), tlsConfiguration: trust)
            #expect(result.status == 307)
            #expect(Date().timeIntervalSince(began) < 2, "Response headers and client shutdown should not wait for the deadline")
            // The fixture's DNS name cannot resolve normally: success requires the pinned address.
            #expect(requests.heads.count == 1)
            #expect(requests.heads.first?.headers.first(name: "Host") == "receiver.example:\(port)")
            await #expect(throws: WebhookTransportError.self) {
                try await transport.sendVetted(url: "https://wrong.example:\(port)/", address: "127.0.0.1",
                    body: Data(), headers: [:], deadline: .now() + .seconds(1), tlsConfiguration: trust)
            }
            #expect(requests.heads.count == 1) // Hostname verification failed before HTTP.
            var blockedTransport = transport
            blockedTransport.resolveAddresses = { _ in ["8.8.8.8", "127.0.0.1"] }
            await #expect(throws: WebhookTransportError.unsafeDestination) {
                try await blockedTransport.send(url: "https://receiver.example", body: Data(), headers: [:])
            }
            // Each client's bounded shutdown closes its accepted TLS connection.
            #expect(requests.closedCount >= 1)
        } catch {
            try? await server.close().get()
            try await app.asyncShutdown()
            throw error
        }
        try await server.close().get()
        try await app.asyncShutdown()
    }
}

import NIOConcurrencyHelpers

private final class WebhookTLSCapture: Sendable {
    private let state = NIOLockedValueBox((heads: [HTTPRequestHead](), closed: 0))
    var heads: [HTTPRequestHead] { state.withLockedValue { $0.heads } }
    var closedCount: Int { state.withLockedValue { $0.closed } }
    func append(_ head: HTTPRequestHead) { state.withLockedValue { $0.heads.append(head) } }
    func closed() { state.withLockedValue { $0.closed += 1 } }
}

private final class WebhookTLSReceiver: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart
    let capture: WebhookTLSCapture
    init(capture: WebhookTLSCapture) { self.capture = capture }
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let head): capture.append(head)
        case .end:
            let head = HTTPResponseHead(version: .http1_1, status: .temporaryRedirect,
                headers: ["Location": "https://127.0.0.1/internal", "Content-Length": "0"])
            context.write(wrapOutboundOut(.head(head)), promise: nil)
            context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
        case .body: break
        }
    }
    func channelInactive(context: ChannelHandlerContext) {
        capture.closed()
        context.fireChannelInactive()
    }
    func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}
