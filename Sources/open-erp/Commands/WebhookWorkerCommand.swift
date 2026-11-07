@preconcurrency import Dispatch
import Foundation
import Fluent
import Vapor
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

struct WebhookWorkerCommand: AsyncCommand {
    struct Signature: CommandSignature {}
    var help: String { "Dispatch and deliver durable organization webhooks without an HTTP listener or OIDC." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        try await checkServingDatabaseRole(on: app.db, environment: app.environment, logger: app.logger)
        let settings = try WebhookWorkerSettings(lookup: Environment.get)
        let key = try WebhookEncryptionKey.load()
        let transport = WebhookTransport(eventLoopGroup: app.eventLoopGroup, threadPool: app.threadPool)
        let worker = WebhookWorker(database: app.db, logger: app.logger, sender: WebhookSender(settings: settings, key: key),
            transport: { try await transport.send(url: $0, body: $1, headers: $2) })
        let task = Task { await worker.run() }
        var sources: [any DispatchSourceSignal] = []
        if app.environment != .testing {
            let queue = DispatchQueue(label: "open-erp.webhook-worker.shutdown")
            for code in [SIGTERM, SIGINT] {
                #if canImport(Darwin)
                signal(code, SIG_IGN)
                #endif
                let source = DispatchSource.makeSignalSource(signal: code, queue: queue)
                source.setEventHandler { task.cancel() }
                source.resume()
                sources.append(source)
            }
        }
        defer { sources.forEach { $0.cancel() } }
        await withTaskCancellationHandler {
            await task.value
        } onCancel: {
            task.cancel()
        }
    }
}
