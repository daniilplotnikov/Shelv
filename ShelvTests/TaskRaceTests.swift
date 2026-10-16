import XCTest

final class TaskRaceTests: XCTestCase {
    func testReturnsValueWhenTaskFinishesBeforeTimeout() async {
        let task = Task<Int?, Never> { 42 }
        let value = await TaskRace.value(of: task, timeout: .seconds(5))
        XCTAssertEqual(value, 42)
    }

    func testReturnsNilOnTimeoutWithoutWaitingForTheSlowTask() async {
        let task = Task<Int?, Never> {
            try? await Task.sleep(for: .seconds(5))
            return 1
        }
        let start = ContinuousClock.now
        let value = await TaskRace.value(of: task, timeout: .milliseconds(100))
        let elapsed = ContinuousClock.now - start
        task.cancel()

        XCTAssertNil(value)
        XCTAssertLessThan(elapsed, .seconds(2))
    }

    func testSlowTaskStillDeliversItsResultAfterTheTimeoutWon() async {
        let task = Task<Int?, Never> {
            try? await Task.sleep(for: .milliseconds(300))
            return 7
        }
        let early = await TaskRace.value(of: task, timeout: .milliseconds(20))
        let late = await task.value

        XCTAssertNil(early)
        XCTAssertEqual(late, 7)
    }

    func testTaskReturningNilYieldsNil() async {
        let task = Task<Int?, Never> { nil }
        let value = await TaskRace.value(of: task, timeout: .seconds(5))
        XCTAssertNil(value)
    }
}
