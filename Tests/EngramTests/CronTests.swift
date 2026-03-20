import Foundation
import Testing
@testable import Engram

// MARK: - Cron Expression

@Test func cronEveryMinute() throws {
    let expr = try CronExpression("* * * * *")
    #expect(expr.matches(Date()))
}

@Test func cronSpecificTime() throws {
    let expr = try CronExpression("30 9 * * *")
    var comps = DateComponents()
    comps.year = 2026; comps.month = 3; comps.day = 20
    comps.hour = 9; comps.minute = 30
    #expect(expr.matches(Calendar.current.date(from: comps)!))

    comps.minute = 31
    #expect(!expr.matches(Calendar.current.date(from: comps)!))
}

@Test func cronStep() throws {
    let expr = try CronExpression("*/15 * * * *")
    var comps = DateComponents()
    comps.year = 2026; comps.month = 1; comps.day = 1; comps.hour = 12
    comps.minute = 0; #expect(expr.matches(Calendar.current.date(from: comps)!))
    comps.minute = 15; #expect(expr.matches(Calendar.current.date(from: comps)!))
    comps.minute = 30; #expect(expr.matches(Calendar.current.date(from: comps)!))
    comps.minute = 7; #expect(!expr.matches(Calendar.current.date(from: comps)!))
}

@Test func cronWeekday() throws {
    let expr = try CronExpression("0 9 * * 1-5")
    var comps = DateComponents()
    comps.year = 2026; comps.month = 3; comps.day = 23 // Monday
    comps.hour = 9; comps.minute = 0
    #expect(expr.matches(Calendar.current.date(from: comps)!))

    comps.day = 22 // Sunday
    #expect(!expr.matches(Calendar.current.date(from: comps)!))
}

@Test func cronList() throws {
    let expr = try CronExpression("0,30 * * * *")
    var comps = DateComponents()
    comps.year = 2026; comps.month = 1; comps.day = 1; comps.hour = 12
    comps.minute = 0; #expect(expr.matches(Calendar.current.date(from: comps)!))
    comps.minute = 30; #expect(expr.matches(Calendar.current.date(from: comps)!))
    comps.minute = 15; #expect(!expr.matches(Calendar.current.date(from: comps)!))
}

@Test func cronRange() throws {
    let expr = try CronExpression("* 9-17 * * *") // work hours
    var comps = DateComponents()
    comps.year = 2026; comps.month = 1; comps.day = 1; comps.minute = 0
    comps.hour = 9; #expect(expr.matches(Calendar.current.date(from: comps)!))
    comps.hour = 17; #expect(expr.matches(Calendar.current.date(from: comps)!))
    comps.hour = 8; #expect(!expr.matches(Calendar.current.date(from: comps)!))
    comps.hour = 18; #expect(!expr.matches(Calendar.current.date(from: comps)!))
}

@Test func cronInvalidExpression() {
    #expect(throws: CronError.self) { try CronExpression("bad") }
    #expect(throws: CronError.self) { try CronExpression("* * *") }
    #expect(throws: CronError.self) { try CronExpression("* * * * * *") } // 6 fields
}

// MARK: - Cron Store

@Test func cronJobStore() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cron_test_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = CronStore(storeDir: tempDir)
    let job = CronJob(name: "test", schedule: "0 9 * * *", prompt: "hello")
    store.add(job)
    #expect(store.allJobs.count == 1)
    #expect(store.enabledJobs.count == 1)

    store.setEnabled(id: job.id, enabled: false)
    #expect(store.enabledJobs.count == 0)
    #expect(store.allJobs.count == 1)

    store.remove(id: job.id)
    #expect(store.allJobs.count == 0)
}

@Test func cronStorePersistence() throws {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cron_persist_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store1 = CronStore(storeDir: tempDir)
    store1.add(CronJob(name: "persist", schedule: "* * * * *", prompt: "test"))
    store1.save()

    let store2 = CronStore(storeDir: tempDir)
    store2.load()
    #expect(store2.allJobs.count == 1)
    #expect(store2.allJobs[0].name == "persist")
}

@Test func cronStoreMarkRun() {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cron_mark_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = CronStore(storeDir: tempDir)
    let job = CronJob(name: "test", schedule: "* * * * *", prompt: "hi")
    store.add(job)
    #expect(store.allJobs[0].lastRun == nil)

    store.markRun(id: job.id)
    #expect(store.allJobs[0].lastRun != nil)
}

// MARK: - Cron Scheduler

@Test func cronSchedulerFires() {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cron_sched_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = CronStore(storeDir: tempDir)
    store.add(CronJob(name: "every", schedule: "* * * * *", prompt: "fire"))

    let scheduler = CronScheduler(store: store)
    var fired = false
    scheduler.onFire = { _ in fired = true }
    scheduler.tick()
    #expect(fired)
}

@Test func cronSchedulerDedup() {
    let tempDir = FileManager.default.temporaryDirectory
        .appendingPathComponent("cron_dedup_\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let store = CronStore(storeDir: tempDir)
    store.add(CronJob(name: "every", schedule: "* * * * *", prompt: "fire"))

    let scheduler = CronScheduler(store: store)
    var fireCount = 0
    scheduler.onFire = { _ in fireCount += 1 }
    scheduler.tick()
    scheduler.tick()
    #expect(fireCount == 1, "Should not fire twice in same minute")
}
