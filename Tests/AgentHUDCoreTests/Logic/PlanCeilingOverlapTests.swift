import AgentHUDSupport
import XCTest
@testable import AgentHUDCore

/// The overlap between a plan whose quota the app reads and the ceiling a transcript logged for a model that goes
/// through it: one limit, one row.
final class PlanCeilingOverlapTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private var pool: BillingPool {
        BillingPool(provider: "GLM", realm: "CN", product: .plan, scope: "scope", evidence: .credential,
                    entitlement: "glm-coding-plan")
    }
    private func window() -> AgentDescriptor {
        AgentDescriptor(id: pool.windowID("rolling"), vendor: "WorkBuddy", model: "5h", source: "", enabled: true,
                        billingPool: pool)
    }
    private func ceiling() -> AgentDescriptor {
        AgentDescriptor(id: "workbuddy:acct/limit:GLM-5.3:5h", vendor: "WorkBuddy", model: "GLM-5.3 · 5-hour usage limit",
                        source: "", enabled: true, billingPool: pool)
    }

    private func report(windowRemaining: Double?) -> UsageReport {
        UsageReport(generatedAt: now,
                    snapshots: [UsageSnapshot(agentId: pool.windowID("rolling"), remainingPct: windowRemaining,
                                              windowDuration: 5 * 3600, updatedAt: now),
                                UsageSnapshot(agentId: "workbuddy:acct/limit:GLM-5.3:5h", remainingPct: 0, updatedAt: now)],
                    sessions: [])
    }

    func testThePlansOwnReadingTakesTheCeilingsPlace() {
        let view = ReportView(report: report(windowRemaining: 90), agents: [window(), ceiling()], settings: Settings(), now: now)
        XCTAssertTrue(view.enabledAgents.contains { $0.id == pool.windowID("rolling") })
        XCTAssertFalse(view.enabledAgents.contains { $0.id.contains("limit:") },
                       "the plan's own 5-hour window is the reading for the model that goes through it")
        XCTAssertFalse(view.rows.contains { $0.id.contains("limit:") })
    }

    func testACeilingNobodyElseReadsStays() {
        // The plan's own window has no value: nothing stands for the ceiling, which is the only reading there is.
        let view = ReportView(report: report(windowRemaining: nil), agents: [window(), ceiling()], settings: Settings(), now: now)
        XCTAssertTrue(view.enabledAgents.contains { $0.id.contains("limit:") })

        // And with no report at all, every row is kept.
        XCTAssertTrue(ReportView(report: nil, agents: [window(), ceiling()], settings: Settings(), now: now)
            .enabledAgents.contains { $0.id.contains("limit:") })
    }

    /// Another pool's ceiling is not affected by this plan's reading.
    func testACeilingOfAnotherPlanIsKept() {
        let other = BillingPool(provider: "Kimi", realm: "CN", product: .plan, scope: "other", evidence: .credential,
                                entitlement: "kimi-code")
        let kimi = AgentDescriptor(id: "workbuddy:acct/limit:Kimi-K3:weekly", vendor: "WorkBuddy",
                                   model: "Kimi-K3 · Weekly usage limit", source: "", enabled: true, billingPool: other)
        let view = ReportView(report: report(windowRemaining: 90), agents: [window(), ceiling(), kimi], settings: Settings(), now: now)
        XCTAssertTrue(view.enabledAgents.contains { $0.id.contains("Kimi-K3") })
        XCTAssertFalse(view.enabledAgents.contains { $0.id.contains("limit:GLM-5.3") })
    }
}
