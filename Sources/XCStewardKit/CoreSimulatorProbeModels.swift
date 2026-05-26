import Foundation

struct CoreSimulatorRuntimeListProbe: Decodable {
    var runtimes: [CoreSimulatorRuntimeProbe]
}

struct CoreSimulatorRuntimeProbe: Decodable {
    var identifier: String?
    var name: String?
    var isAvailableFlag: Bool?
    var availability: String?
    var availabilityError: String?
    var error: String?
    var state: String?

    var isIOSRuntime: Bool {
        CoreSimulatorRuntime.isIOSRuntime(identifier: identifier, name: name)
    }

    var isAvailable: Bool {
        if let isAvailableFlag {
            return isAvailableFlag
        }
        if let availability {
            if CoreSimulatorAvailability.textIndicatesUnavailable(availability) {
                return false
            }
            if CoreSimulatorAvailability.textIndicatesAvailable(availability) {
                return true
            }
        }
        return false
    }

    var availabilityText: String {
        [
            availability,
            availabilityError,
            error,
            state,
        ]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    var displayName: String {
        name ?? identifier ?? "unknown runtime"
    }

    var normalizedVersion: String? {
        DoctorOutputParsers.normalizedVersion(from: [name, identifier].compactMap { $0 }.joined(separator: " "))
    }

    enum CodingKeys: String, CodingKey {
        case identifier
        case name
        case isAvailableFlag = "isAvailable"
        case availability
        case availabilityError
        case availabilityErrorSnake = "availability_error"
        case error
        case state
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try container.decodeIfPresent(String.self, forKey: .identifier)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        isAvailableFlag = CoreSimulatorAvailability.decodeFlag(from: container, forKey: .isAvailableFlag)
        availability = try container.decodeIfPresent(String.self, forKey: .availability)
        availabilityError = try container.decodeIfPresent(String.self, forKey: .availabilityError)
            ?? container.decodeIfPresent(String.self, forKey: .availabilityErrorSnake)
        error = try container.decodeIfPresent(String.self, forKey: .error)
        state = try container.decodeIfPresent(String.self, forKey: .state)
    }
}

struct CoreSimulatorDeviceListProbe: Decodable {
    var devices: [String: [CoreSimulatorDeviceProbe]]

    enum CodingKeys: String, CodingKey {
        case devices
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        devices = try container.decodeIfPresent([String: [CoreSimulatorDeviceProbe]].self, forKey: .devices) ?? [:]
    }
}

struct CoreSimulatorDeviceProbe: Decodable {
    var name: String?
    var udid: String?
    var state: String?
    var isAvailableFlag: Bool?
    var availability: String?
    var availabilityError: String?
    var error: String?

    var isUnavailable: Bool {
        if let isAvailableFlag, !isAvailableFlag {
            return true
        }
        if let state, state.localizedCaseInsensitiveContains("unavailable") {
            return true
        }
        if let availability, CoreSimulatorAvailability.textIndicatesUnavailable(availability) {
            return true
        }
        return !errorText.isEmpty
    }

    var displayName: String {
        [name, udid].compactMap { $0 }.joined(separator: " ")
    }

    private var errorText: String {
        [
            availabilityError,
            error,
        ]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    enum CodingKeys: String, CodingKey {
        case name
        case udid
        case state
        case isAvailableFlag = "isAvailable"
        case availability
        case availabilityError
        case availabilityErrorSnake = "availability_error"
        case error
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        udid = try container.decodeIfPresent(String.self, forKey: .udid)
        state = try container.decodeIfPresent(String.self, forKey: .state)
        isAvailableFlag = CoreSimulatorAvailability.decodeFlag(from: container, forKey: .isAvailableFlag)
        availability = try container.decodeIfPresent(String.self, forKey: .availability)
        availabilityError = try container.decodeIfPresent(String.self, forKey: .availabilityError)
            ?? container.decodeIfPresent(String.self, forKey: .availabilityErrorSnake)
        error = try container.decodeIfPresent(String.self, forKey: .error)
    }
}
