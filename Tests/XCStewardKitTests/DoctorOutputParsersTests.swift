import XCTest
@testable import XCStewardKit

final class DoctorOutputParsersTests: XCTestCase {
    func testShowDestinationsIgnoresIneligibleIOSSimulatorDestinations() {
        let output = """
        Available destinations for the "Demo" scheme:
            { platform:macOS, arch:arm64, name:My Mac }

        Ineligible destinations for the "Demo" scheme:
            { platform:iOS Simulator, id:SIM-123, OS:18.0, name:iPhone 17 Pro, error:iOS platform support is not installed }
        """

        XCTAssertFalse(DoctorOutputParsers.showDestinationsOutputExposesIOSSimulator(output))
    }

    func testShowDestinationsAcceptsAvailableIOSSimulatorDestinations() {
        let output = """
        Available destinations for the "Demo" scheme:
            { platform : iOS Simulator, id : SIM-123, OS : 18.0, name : iPhone 17 Pro }

        Ineligible destinations for the "Demo" scheme:
            { platform:macOS, name:Unavailable Mac }
        """

        XCTAssertTrue(DoctorOutputParsers.showDestinationsOutputExposesIOSSimulator(output))
    }

    func testShowsSDKsAcceptsEqualsSeparatedSDKToken() {
        let output = """
        iOS Simulator SDKs:
            Simulator - iOS 18.0          -sdk=iphonesimulator18.0
        """

        XCTAssertTrue(DoctorOutputParsers.showsSDKsOutputExposesIPhoneSimulatorSDK(output))
    }
}
