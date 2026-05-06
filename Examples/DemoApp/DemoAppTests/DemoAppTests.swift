import XCTest
@testable import DemoApp

final class DemoAppTests: XCTestCase {
    func testGreetingIsStable() {
        XCTAssertEqual(DemoGreeting.message, "Hello from XCSteward")
    }
}
