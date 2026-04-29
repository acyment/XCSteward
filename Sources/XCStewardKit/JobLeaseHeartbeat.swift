import Dispatch
import Foundation

final class JobLeaseHeartbeat: @unchecked Sendable {
    private let environment: AppEnvironment
    private let jobID: String
    private let queue: DispatchQueue
    private var timer: DispatchSourceTimer?

    init(environment: AppEnvironment, jobID: String) {
        self.environment = environment
        self.jobID = jobID
        self.queue = DispatchQueue(label: "XCSteward.JobLeaseHeartbeat.\(jobID)")
    }

    func start() {
        pulse()
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + .milliseconds(500), repeating: .milliseconds(500))
        timer.setEventHandler { [weak self] in
            self?.pulse()
        }
        timer.resume()
        self.timer = timer
    }

    func stop() {
        timer?.cancel()
        timer = nil
    }

    private func pulse() {
        do {
            let store = try StateStore(environment: environment)
            try store.updateLeaseHeartbeat(jobID: jobID)
        } catch {
            return
        }
    }
}
