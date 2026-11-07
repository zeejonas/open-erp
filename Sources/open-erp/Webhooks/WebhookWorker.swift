import Fluent
import Foundation
import SQLKit
import Vapor

struct WebhookWorker: Sendable {
    let database: any Database
    let logger: Logger
    let sender: WebhookSender
    let transport: @Sendable (String, Data, HTTPHeaders) async throws -> WebhookHTTPResult
    let metrics = WebhookWorkerMetrics()

    func run() async {
        await withTaskGroup(of: Void.self) { group in
            group.addTask { await dispatchLoop() }
            group.addTask { await sendLoop() }
            group.addTask { await summaryLoop() }
            await group.waitForAll()
        }
    }

    private func dispatchLoop() async {
        while !Task.isCancelled {
            do {
                if try await WebhookDispatcher.dispatchBatch(on: database) > 0 { continue }
            } catch {
                if Task.isCancelled { return }
                logger.error("Webhook dispatch failed", metadata: ["error_type": "\(type(of: error))"])
            }
            await idle()
        }
    }

    private func sendLoop() async {
        await withTaskGroup(of: Void.self) { group in
            var inFlight = 0
            var afterOrganizationID: UUID?
            while !Task.isCancelled {
                if inFlight == sender.settings.concurrency {
                    _ = await group.next()
                    inFlight -= 1
                }
                do {
                    let start = Date()
                    let attempt = try await sender.claim(on: database, afterOrganizationID: afterOrganizationID)
                    await metrics.recordClaim(Date().timeIntervalSince(start))
                    if let attempt {
                        afterOrganizationID = attempt.organizationID
                        inFlight += 1
                        await metrics.started()
                        group.addTask {
                            do { try await sender.send(attempt, on: database, transport: transport) }
                            catch {
                                if !Task.isCancelled {
                                    logger.error("Webhook attempt persistence failed; lease retained for recovery", metadata: ["attempt_id": "\(attempt.id)"])
                                }
                            }
                            await metrics.finished()
                        }
                        continue
                    }
                } catch {
                    if Task.isCancelled { break }
                    logger.error("Webhook claim failed", metadata: ["error_type": "\(type(of: error))"])
                }
                if inFlight > 0 {
                    _ = await group.next()
                    inFlight -= 1
                } else {
                    await idle()
                }
            }
            group.cancelAll()
            await group.waitForAll()
        }
    }

    private func idle() async {
        try? await Task.sleep(for: .milliseconds(sender.settings.pollIntervalMilliseconds))
    }

    private func summaryLoop() async {
        while !Task.isCancelled {
            do { try await Task.sleep(for: .seconds(60)) } catch { return }
            do { try await logSummary() }
            catch { logger.warning("Webhook summary unavailable") }
        }
    }

    func logSummary() async throws {
        let sample = await metrics.snapshot()
        let row = try await database.requireSQL().raw("""
            SELECT
                (SELECT COALESCE(EXTRACT(EPOCH FROM clock_timestamp() - MIN(created_at)), 0)::double precision
                    FROM business_event_dispatches) AS dispatch_lag,
                (SELECT COALESCE(EXTRACT(EPOCH FROM clock_timestamp() - MIN(created_at)), 0)::double precision
                    FROM webhook_deliveries WHERE state IN ('pending', 'retrying') AND next_attempt_at <= clock_timestamp()) AS queue_age
            """).first()
        let lag = try row?.decode(column: "dispatch_lag", as: Double.self) ?? 0
        let queue = try row?.decode(column: "queue_age", as: Double.self) ?? 0
        logger.info("Webhook worker summary", metadata: [
            "in_flight": "\(sample.inFlight)", "dispatch_lag_seconds": "\(lag)", "oldest_due_seconds": "\(queue)",
            "median_claim_ms": "\(sample.median * 1000)", "max_claim_ms": "\(sample.maximum * 1000)",
        ])
        if lag > 300 || queue > 300 { logger.warning("Webhook backlog age exceeds five minutes") }
    }
}

actor WebhookWorkerMetrics {
    private var inFlight = 0
    private var claims: [Double] = []
    func started() { inFlight += 1 }
    func finished() { inFlight -= 1 }
    func recordClaim(_ seconds: Double) {
        if claims.count < 10_000 { claims.append(seconds) }
    }
    func snapshot() -> (inFlight: Int, median: Double, maximum: Double) {
        let sorted = claims.sorted()
        let median = sorted.isEmpty ? 0 : (sorted[(sorted.count - 1) / 2] + sorted[sorted.count / 2]) / 2
        claims.removeAll(keepingCapacity: true)
        return (inFlight, median, sorted.last ?? 0)
    }
}
