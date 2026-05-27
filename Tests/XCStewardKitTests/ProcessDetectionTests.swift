// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 XCSteward Contributors

import XCTest
@testable import XCStewardKit

final class ProcessDetectionTests: XCTestCase {
    func testExecutorDetectsTokenizedXcodebuildTestActions() {
        XCTAssertTrue(RunnerProcessDetector.isCompeting(
            command: "/Applications/Xcode.app/Contents/Developer/usr/bin/xcodebuild -scheme Demo test",
            policy: .executor
        ))
        XCTAssertTrue(RunnerProcessDetector.isCompeting(
            command: "xcodebuild -project Demo.xcodeproj -scheme Demo build-for-testing",
            policy: .executor
        ))
        XCTAssertTrue(RunnerProcessDetector.isCompeting(
            command: "xcodebuild -xctestrun /tmp/Demo.xctestrun test-without-building",
            policy: .executor
        ))
    }

    func testExecutorIgnoresXcodebuildOptionValuesNamedTest() {
        XCTAssertFalse(RunnerProcessDetector.isCompeting(
            command: "xcodebuild -scheme test -project Demo.xcodeproj -list",
            policy: .executor
        ))
        XCTAssertFalse(RunnerProcessDetector.isCompeting(
            command: "xcodebuild -derivedDataPath /tmp/test -showBuildSettings",
            policy: .executor
        ))
    }

    func testExecutorIgnoresQuotedOptionValuesContainingActionWords() {
        XCTAssertFalse(RunnerProcessDetector.isCompeting(
            command: #"xcodebuild -scheme "UITests test" -project Demo.xcodeproj -list"#,
            policy: .executor
        ))
        XCTAssertFalse(RunnerProcessDetector.isCompeting(
            command: #"xcodebuild -derivedDataPath "/tmp/build-for-testing output" -showBuildSettings"#,
            policy: .executor
        ))
    }

    func testExecutorHandlesQuotedAndEscapedExecutablePaths() {
        XCTAssertTrue(RunnerProcessDetector.isCompeting(
            command: #""/Applications/Xcode 16.app/Contents/Developer/usr/bin/xcodebuild" -scheme Demo test"#,
            policy: .executor
        ))
        XCTAssertTrue(RunnerProcessDetector.isCompeting(
            command: #"/Applications/Xcode\ 16.app/Contents/Developer/usr/bin/xcodebuild -scheme Demo test"#,
            policy: .executor
        ))
    }

    func testDoctorStillTreatsAnyXcodebuildOrSimctlAsCompeting() {
        XCTAssertTrue(RunnerProcessDetector.isCompeting(
            command: "xcodebuild -scheme test -list",
            policy: .doctor
        ))
        XCTAssertTrue(RunnerProcessDetector.isCompeting(
            command: "xcrun simctl list devices",
            policy: .doctor
        ))
    }
}
