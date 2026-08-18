// TestEngineGate — proves TranscriptionEngineGate actually serializes.
//
//   swift run TestEngineGate
//
// A plain `actor { await op() }` does NOT serialize (actors are reentrant), so
// this test guards against regressing to that no-op. It pushes concurrent ops
// through the gate and asserts:
//   1. max observed concurrency == 1 (ops never overlap)
//   2. ops run in FIFO (enqueue) order
//   3. a throwing op propagates to its caller but does NOT wedge the chain
//      (later ops still run)
// Prints PASS/FAIL and exits non-zero on any failure.

import Foundation
import SharedModels

/// Records overlap + ordering from inside the ops.
actor Probe {
    private(set) var current = 0
    private(set) var maxConcurrent = 0
    private(set) var order: [Int] = []

    func enter(_ id: Int) {
        order.append(id)
        current += 1
        if current > maxConcurrent { maxConcurrent = current }
    }
    func leave() { current -= 1 }
    func record(_ id: Int) { order.append(id) }
    func snapshot() -> (max: Int, order: [Int]) { (maxConcurrent, order) }
}

enum GateTestError: Error { case boom }

let sem = DispatchSemaphore(value: 0)
var failures: [String] = []

Task {
    defer { sem.signal() }

    // ---- Test 1: serialization + FIFO ---------------------------------------
    // Stagger submission by 10ms so enqueue order is deterministic (0..4); each
    // op holds the critical section for 60ms, so a broken (reentrant) gate would
    // let them overlap and drive maxConcurrent above 1.
    do {
        let gate = TranscriptionEngineGate()
        let probe = Probe()
        let n = 5
        var tasks: [Task<Void, Never>] = []
        for i in 0..<n {
            tasks.append(Task {
                try? await Task.sleep(nanoseconds: UInt64(i) * 10_000_000)
                _ = try? await gate.run { () async throws -> Int in
                    await probe.enter(i)
                    try? await Task.sleep(nanoseconds: 60_000_000)
                    await probe.leave()
                    return i
                }
            })
        }
        for t in tasks { await t.value }

        let (maxC, order) = await probe.snapshot()
        print("Test 1 (serialize+FIFO): maxConcurrent=\(maxC), order=\(order)")
        if maxC != 1 { failures.append("Test 1: maxConcurrent was \(maxC), expected 1 (gate did NOT serialize)") }
        if order != Array(0..<n) { failures.append("Test 1: order was \(order), expected \(Array(0..<n)) (not FIFO)") }
    }

    // ---- Test 2: a throwing op doesn't wedge the chain ----------------------
    // Enqueue A, B(throws), C (staggered). B must throw to its caller; A and C
    // must both still run.
    do {
        let gate = TranscriptionEngineGate()
        let probe = Probe()

        func submit(_ id: Int, delayMs: UInt64, throwing: Bool) -> Task<Bool, Never> {
            Task {
                try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                do {
                    try await gate.run { () async throws -> Void in
                        await probe.record(id)
                        if throwing { throw GateTestError.boom }
                    }
                    return false   // did not throw
                } catch {
                    return true    // threw to caller
                }
            }
        }

        let tA = submit(0, delayMs: 0, throwing: false)
        let tB = submit(1, delayMs: 10, throwing: true)
        let tC = submit(2, delayMs: 20, throwing: false)
        let threwA = await tA.value
        let threwB = await tB.value
        let threwC = await tC.value

        let (_, order) = await probe.snapshot()
        print("Test 2 (throw-recovery): order=\(order), threw A/B/C = \(threwA)/\(threwB)/\(threwC)")
        if !threwB { failures.append("Test 2: throwing op did not propagate its error to the caller") }
        if threwA || threwC { failures.append("Test 2: a non-throwing op reported an error") }
        if !order.contains(0) || !order.contains(2) {
            failures.append("Test 2: chain wedged — A or C did not run after the throwing op (order=\(order))")
        }
    }
}

sem.wait()

if failures.isEmpty {
    print("✅ PASS: TranscriptionEngineGate serializes (max concurrency 1), preserves FIFO order, and survives a throwing op.")
    exit(0)
} else {
    print("❌ FAIL:")
    for f in failures { print("  - \(f)") }
    exit(1)
}
