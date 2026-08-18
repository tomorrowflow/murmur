import XCTest
@testable import SharedModels

/// Covers the session state machine — the part that runs before any microphone is touched.
/// The engine bring-up itself needs real audio hardware and is not exercised here; these
/// tests use a `gate` that is never fired, so `AVAudioEngine` is never constructed.
final class AudioEngineRecorderTests: XCTestCase {

    private func makeRecorder() -> AudioEngineRecorder {
        AudioEngineRecorder(configuration: .init(label: "test", targetSampleRate: 16000))
    }

    func testStartFlipsIsRecordingSynchronously() {
        let recorder = makeRecorder()
        XCTAssertFalse(recorder.isRecording)

        // Callers gate their UI and their stop-handling on `isRecording` the instant they
        // call start — it must not wait for the engine to come up on the background queue.
        recorder.start(gate: { _ in /* never launch */ })

        XCTAssertTrue(recorder.isRecording)
        XCTAssertTrue(recorder.isStarting)
    }

    func testSecondStartIsIgnoredWhileStarting() {
        let recorder = makeRecorder()
        var gateCalls = 0
        recorder.start(gate: { _ in gateCalls += 1 })
        recorder.start(gate: { _ in gateCalls += 1 })

        XCTAssertEqual(gateCalls, 1, "a start while one is already coming up must be ignored")
        XCTAssertTrue(recorder.isRecording)
    }

    func testStopDuringGateIsHonouredAndDeliversSamples() {
        let recorder = makeRecorder()
        recorder.start(gate: { _ in /* engine never launches */ })
        XCTAssertTrue(recorder.isRecording)

        // Releasing the key while the engine is still gated must stop the session rather
        // than being dropped — the bug that stranded live recordings.
        let delivered = expectation(description: "samples delivered")
        recorder.stop { samples in
            XCTAssertTrue(samples.isEmpty)
            delivered.fulfill()
        }

        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.isStarting)
        wait(for: [delivered], timeout: 2.0)
    }

    func testLaunchingAfterStopDoesNotReviveTheSession() {
        let recorder = makeRecorder()
        var launch: (() -> Void)?
        recorder.start(gate: { launch = $0 })

        let delivered = expectation(description: "samples delivered")
        recorder.stop { _ in delivered.fulfill() }
        wait(for: [delivered], timeout: 2.0)

        // The gate resolves late — e.g. a media-pause snapshot finishing after the user
        // already released the key. It must not bring a microphone up behind their back.
        launch?()

        XCTAssertEqual(recorder.engineStartAttemptsForTesting(), 0,
                       "an abandoned session must never reach the engine")
        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.isStarting)
    }

    func testGateLaunchStartsTheEngineWhenStillCurrent() {
        // Guards the test above: if the session check were wrong in the other direction,
        // a legitimate launch would silently never start the mic.
        let recorder = makeRecorder()
        var launch: (() -> Void)?
        recorder.start(gate: { launch = $0 })
        launch?()

        XCTAssertEqual(recorder.engineStartAttemptsForTesting(), 1)
        recorder.cancel()
    }

    func testStopWithoutStartIsANoOp() {
        let recorder = makeRecorder()
        var called = false
        recorder.stop { _ in called = true }
        XCTAssertFalse(called)
        XCTAssertFalse(recorder.isRecording)
    }

    func testCancelDuringGateClearsState() {
        let recorder = makeRecorder()
        recorder.start(gate: { _ in })
        recorder.cancel()

        XCTAssertFalse(recorder.isRecording)
        XCTAssertFalse(recorder.isStarting)
    }

    func testStartAfterStopBeginsAFreshSession() {
        let recorder = makeRecorder()
        recorder.start(gate: { _ in })
        let delivered = expectation(description: "samples delivered")
        recorder.stop { _ in delivered.fulfill() }
        wait(for: [delivered], timeout: 2.0)

        var launched = false
        recorder.start(gate: { _ in launched = true })
        XCTAssertTrue(launched, "a new start after a stop must not be blocked by stale state")
        XCTAssertTrue(recorder.isRecording)
    }
}
