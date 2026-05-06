import CSQLite
import Foundation

public struct JobStatePatch {
    public var state: JobState?
    public var resultClass: ResultClass?
    public var summary: JobSummary?
    public var startedAt: Double?
    public var finishedAt: Double?
    public var processID: Int32?
    public var simulatorID: String?
    public var cancelRequested: Bool?

    public init(
        state: JobState? = nil,
        resultClass: ResultClass? = nil,
        summary: JobSummary? = nil,
        startedAt: Double? = nil,
        finishedAt: Double? = nil,
        processID: Int32? = nil,
        simulatorID: String? = nil,
        cancelRequested: Bool? = nil
    ) {
        self.state = state
        self.resultClass = resultClass
        self.summary = summary
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.processID = processID
        self.simulatorID = simulatorID
        self.cancelRequested = cancelRequested
    }
}

public final class StateStore {
    fileprivate let environment: AppEnvironment
    fileprivate let db: OpaquePointer

    var jobs: JobRecordGateway {
        JobRecordGateway(store: self)
    }

    var workerLease: WorkerLeaseGateway {
        WorkerLeaseGateway(store: self)
    }

    var simulatorLeases: SimulatorLeaseGateway {
        SimulatorLeaseGateway(store: self)
    }

    var timings: TestTimingGateway {
        TestTimingGateway(store: self)
    }

    var infrastructureEvents: InfrastructureEventGateway {
        InfrastructureEventGateway(store: self)
    }

    public init(environment: AppEnvironment) throws {
        self.environment = environment
        try environment.fileSystem.createDirectory(environment.paths.stateRoot)
        try environment.fileSystem.createDirectory(environment.paths.jobsRoot)
        try environment.fileSystem.createDirectory(environment.paths.projectsRoot)
        try environment.fileSystem.createDirectory(environment.paths.doctorRoot)
        var handle: OpaquePointer?
        if sqlite3_open(environment.paths.dbURL.path, &handle) != SQLITE_OK {
            throw XCStewardError.commandFailed("Unable to open database")
        }
        guard let handle else {
            throw XCStewardError.commandFailed("Unable to initialize database handle")
        }
        self.db = handle
        sqlite3_busy_timeout(db, 5_000)
        try execute("PRAGMA journal_mode=WAL;")
        try execute("PRAGMA synchronous=NORMAL;")
        try StateStoreSchema.migrate(store: self)
    }

    deinit {
        sqlite3_close(db)
    }

    public func createJob(_ record: JobRecord) throws {
        try jobs.create(record)
    }

    public func fetchJob(id: String) throws -> JobRecord? {
        try jobs.fetch(id: id)
    }

    public func listJobs() throws -> [JobRecord] {
        try jobs.list()
    }

    public func nextQueuedJob() throws -> JobRecord? {
        try jobs.nextQueued()
    }

    public func claimNextQueuedJob() throws -> JobRecord? {
        try jobs.claimNextQueued()
    }

    public func hasQueuedJobs() throws -> Bool {
        try jobs.hasQueued()
    }

    public func updateJob(id: String, patch: JobStatePatch) throws {
        try jobs.update(id: id, patch: patch)
    }

    public func requestCancel(jobID: String) throws {
        try jobs.requestCancel(jobID: jobID)
    }

    public func clearJobProcessID(id: String) throws {
        try jobs.clearProcessID(id: id, processID: nil)
    }

    public func clearJobProcessID(id: String, processID: Int32) throws {
        try jobs.clearProcessID(id: id, processID: processID)
    }

    public func deleteTerminalJob(id: String) throws {
        try jobs.deleteTerminal(id: id)
    }

    public func acquireLease(workerID: String, pid: Int32) throws -> Bool {
        try workerLease.acquire(workerID: workerID, pid: pid)
    }

    public func updateLeaseHeartbeat(jobID: String?) throws {
        try workerLease.updateHeartbeat(jobID: jobID)
    }

    public func currentLease() throws -> WorkerLease? {
        try workerLease.current()
    }

    public func releaseLease() throws {
        try workerLease.release()
    }

    public func acquireSimulatorLease(simulatorID: String, jobID: String, pid: Int32) throws -> Bool {
        try simulatorLeases.acquire(simulatorID: simulatorID, jobID: jobID, pid: pid)
    }

    public func simulatorLease(simulatorID: String) throws -> SimulatorLease? {
        try simulatorLeases.fetch(simulatorID: simulatorID)
    }

    public func listSimulatorLeases() throws -> [SimulatorLease] {
        try simulatorLeases.list()
    }

    public func releaseSimulatorLease(simulatorID: String, jobID: String? = nil) throws {
        try simulatorLeases.release(simulatorID: simulatorID, jobID: jobID)
    }

    public func releaseSimulatorLeases(jobID: String) throws {
        try simulatorLeases.release(jobID: jobID)
    }

    public func countRecentInfrastructureFailures(since timestamp: Double) throws -> Int {
        try infrastructureEvents.countRecentFailures(since: timestamp)
    }

    public func recordInfrastructureEvent(
        jobID: String?,
        simulatorID: String?,
        resultClass: ResultClass,
        message: String?
    ) throws {
        try infrastructureEvents.record(
            jobID: jobID,
            simulatorID: simulatorID,
            resultClass: resultClass,
            message: message
        )
    }

    func testTimingEstimates(project: String, identifiers: [String]) throws -> [String: Double] {
        try timings.estimates(project: project, identifiers: identifiers)
    }

    func recordTestTimings(project: String, samples: [TestTimingSample]) throws {
        try timings.record(project: project, samples: samples)
    }

    @discardableResult
    public func recoverStaleSimulatorLeases() throws -> Int {
        try simulatorLeases.recoverStale()
    }

    public func recoverStaleLeaseIfNeeded() throws -> Bool {
        try workerLease.recoverStaleIfNeeded()
    }

    fileprivate func execute(_ sql: String, values: [SQLiteValue] = []) throws {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw XCStewardError.commandFailed("Failed to prepare SQL: \(sql)")
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        let step = sqlite3_step(statement)
        guard step == SQLITE_DONE || step == SQLITE_ROW else {
            throw XCStewardError.commandFailed("Failed to execute SQL: \(sql)")
        }
    }

    fileprivate func withImmediateTransaction<T>(_ body: () throws -> T) throws -> T {
        try execute("BEGIN IMMEDIATE;")
        do {
            let value = try body()
            do {
                try execute("COMMIT;")
            } catch {
                try? execute("ROLLBACK;")
                throw error
            }
            return value
        } catch {
            try? execute("ROLLBACK;")
            throw error
        }
    }

    fileprivate func changedRowCount() -> Int {
        Int(sqlite3_changes(db))
    }

    fileprivate func query<T>(_ sql: String, values: [SQLiteValue], map: (OpaquePointer?) throws -> T) throws -> [T] {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &statement, nil) == SQLITE_OK else {
            throw XCStewardError.commandFailed("Failed to prepare SQL query")
        }
        defer { sqlite3_finalize(statement) }
        try bind(values, to: statement)
        var results: [T] = []
        while sqlite3_step(statement) == SQLITE_ROW {
            results.append(try map(statement))
        }
        return results
    }

    fileprivate func querySingle<T>(_ sql: String, values: [SQLiteValue], map: (OpaquePointer?) throws -> T) throws -> T? {
        try query(sql, values: values, map: map).first
    }

    private func bind(_ values: [SQLiteValue], to statement: OpaquePointer?) throws {
        for (offset, value) in values.enumerated() {
            let index = Int32(offset + 1)
            switch value {
            case let .text(text):
                if let text {
                    sqlite3_bind_text(statement, index, text, -1, SQLITE_TRANSIENT)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case let .double(value):
                if let value {
                    sqlite3_bind_double(statement, index, value)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            case let .int(value):
                if let value {
                    sqlite3_bind_int64(statement, index, value)
                } else {
                    sqlite3_bind_null(statement, index)
                }
            }
        }
    }
}

enum StateStoreSchema {
    static func migrate(store: StateStore) throws {
        try store.execute("""
        CREATE TABLE IF NOT EXISTS jobs (
            id TEXT PRIMARY KEY,
            project TEXT NOT NULL,
            state TEXT NOT NULL,
            result_class TEXT,
            request_json TEXT NOT NULL,
            summary_json TEXT,
            job_directory TEXT NOT NULL,
            created_at REAL NOT NULL,
            started_at REAL,
            finished_at REAL,
            process_id INTEGER,
            simulator_id TEXT,
            cancel_requested INTEGER NOT NULL DEFAULT 0
        );
        """)
        try store.execute("""
        CREATE TABLE IF NOT EXISTS worker_lease (
            singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
            worker_id TEXT NOT NULL,
            pid INTEGER NOT NULL,
            heartbeat REAL NOT NULL,
            job_id TEXT
        );
        """)
        try store.execute("""
        CREATE TABLE IF NOT EXISTS simulator_leases (
            simulator_id TEXT PRIMARY KEY,
            job_id TEXT NOT NULL,
            pid INTEGER NOT NULL,
            acquired_at REAL NOT NULL,
            heartbeat REAL NOT NULL
        );
        """)
        try store.execute("""
        CREATE TABLE IF NOT EXISTS test_timings (
            project TEXT NOT NULL,
            identifier TEXT NOT NULL,
            duration_seconds REAL NOT NULL,
            samples INTEGER NOT NULL,
            updated_at REAL NOT NULL,
            PRIMARY KEY(project, identifier)
        );
        """)
        try store.execute("""
        CREATE TABLE IF NOT EXISTS infrastructure_events (
            id TEXT PRIMARY KEY,
            job_id TEXT,
            simulator_id TEXT,
            result_class TEXT NOT NULL,
            message TEXT,
            created_at REAL NOT NULL
        );
        """)
        try store.execute("""
        CREATE INDEX IF NOT EXISTS infrastructure_events_created_at_idx
        ON infrastructure_events(created_at);
        """)
    }
}

struct JobRecordGateway {
    private unowned let store: StateStore

    init(store: StateStore) {
        self.store = store
    }

    func create(_ record: JobRecord) throws {
        let requestData = try jsonData(record.request)
        let summaryData = try record.summary.map(jsonData(_:))
        try store.execute(
            """
            INSERT INTO jobs (id, project, state, result_class, request_json, summary_json, job_directory, created_at, started_at, finished_at, process_id, simulator_id, cancel_requested)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
            """,
            values: [
                .text(record.id),
                .text(record.project),
                .text(record.state.rawValue),
                .text(record.resultClass?.rawValue),
                .text(String(data: requestData, encoding: .utf8)),
                .text(summaryData.flatMap { String(data: $0, encoding: .utf8) }),
                .text(record.jobDirectory),
                .double(record.createdAt),
                .double(record.startedAt),
                .double(record.finishedAt),
                .int(record.processID.map(Int64.init)),
                .text(record.simulatorID),
                .int(record.cancelRequested ? 1 : 0),
            ]
        )
    }

    func fetch(id: String) throws -> JobRecord? {
        try store.querySingle("SELECT * FROM jobs WHERE id = ?;", values: [.text(id)], map: mapRow)
    }

    func list() throws -> [JobRecord] {
        try store.query("SELECT * FROM jobs ORDER BY created_at ASC;", values: [], map: mapRow)
    }

    func nextQueued() throws -> JobRecord? {
        try store.querySingle("SELECT * FROM jobs WHERE state = 'queued' ORDER BY created_at ASC LIMIT 1;", values: [], map: mapRow)
    }

    func claimNextQueued() throws -> JobRecord? {
        try store.withImmediateTransaction {
            guard let job = try nextQueued() else {
                return nil
            }
            try store.execute(
                "UPDATE jobs SET state = ? WHERE id = ? AND state = ?;",
                values: [
                    .text(JobState.running.rawValue),
                    .text(job.id),
                    .text(JobState.queued.rawValue),
                ]
            )
            guard store.changedRowCount() == 1 else {
                return nil
            }
            return try fetch(id: job.id)
        }
    }

    func hasQueued() throws -> Bool {
        try store.querySingle(
            "SELECT 1 FROM jobs WHERE state = ? LIMIT 1;",
            values: [.text(JobState.queued.rawValue)]
        ) { _ in true } ?? false
    }

    func update(id: String, patch: JobStatePatch) throws {
        let summaryText = try patch.summary.flatMap { try String(data: jsonData($0), encoding: .utf8) }
        try store.execute(
            """
            UPDATE jobs
            SET state = COALESCE(?, state),
                result_class = COALESCE(?, result_class),
                summary_json = COALESCE(?, summary_json),
                started_at = COALESCE(?, started_at),
                finished_at = COALESCE(?, finished_at),
                process_id = COALESCE(?, process_id),
                simulator_id = COALESCE(?, simulator_id),
                cancel_requested = COALESCE(?, cancel_requested)
            WHERE id = ?;
            """,
            values: [
                .text(patch.state?.rawValue),
                .text(patch.resultClass?.rawValue),
                .text(summaryText),
                .double(patch.startedAt),
                .double(patch.finishedAt),
                .int(patch.processID.map(Int64.init)),
                .text(patch.simulatorID),
                .int(patch.cancelRequested.map { $0 ? 1 : 0 }),
                .text(id),
            ]
        )
    }

    func requestCancel(jobID: String) throws {
        try store.execute("UPDATE jobs SET cancel_requested = 1 WHERE id = ?;", values: [.text(jobID)])
    }

    func clearProcessID(id: String, processID: Int32?) throws {
        if let processID {
            try store.execute(
                "UPDATE jobs SET process_id = NULL WHERE id = ? AND process_id = ?;",
                values: [.text(id), .int(Int64(processID))]
            )
        } else {
            try store.execute("UPDATE jobs SET process_id = NULL WHERE id = ?;", values: [.text(id)])
        }
    }

    func deleteTerminal(id: String) throws {
        try store.execute(
            """
            DELETE FROM jobs
            WHERE id = ?
              AND state NOT IN (?, ?);
            """,
            values: [
                .text(id),
                .text(JobState.queued.rawValue),
                .text(JobState.running.rawValue),
            ]
        )
    }

    func markRunningJobsInterrupted(finishedAt: Double) throws {
        try store.execute(
            """
            UPDATE jobs
            SET state = ?, result_class = ?, finished_at = ?
            WHERE state = ?;
            """,
            values: [
                .text(JobState.interrupted.rawValue),
                .text(ResultClass.internalError.rawValue),
                .double(finishedAt),
                .text(JobState.running.rawValue),
            ]
        )
    }

    private func mapRow(_ statement: OpaquePointer?) throws -> JobRecord {
        guard let statement else {
            throw XCStewardError.commandFailed("Missing row")
        }
        let requestText = String(cString: sqlite3_column_text(statement, 4))
        let request: JobRequest = try decodeJSON(JobRequest.self, from: Data(requestText.utf8))
        let summary: JobSummary?
        if let summaryText = sqliteString(statement, index: 5) {
            summary = try decodeJSON(JobSummary.self, from: Data(summaryText.utf8))
        } else {
            summary = nil
        }
        return JobRecord(
            id: String(cString: sqlite3_column_text(statement, 0)),
            project: String(cString: sqlite3_column_text(statement, 1)),
            state: JobState(rawValue: String(cString: sqlite3_column_text(statement, 2))) ?? .queued,
            resultClass: sqliteString(statement, index: 3).flatMap(ResultClass.init(rawValue:)),
            request: request,
            summary: summary,
            jobDirectory: String(cString: sqlite3_column_text(statement, 6)),
            createdAt: sqlite3_column_double(statement, 7),
            startedAt: sqliteNullableDouble(statement, index: 8),
            finishedAt: sqliteNullableDouble(statement, index: 9),
            processID: sqliteNullableInt(statement, index: 10).map(Int32.init),
            simulatorID: sqliteString(statement, index: 11),
            cancelRequested: sqlite3_column_int(statement, 12) != 0
        )
    }
}

struct WorkerLeaseGateway {
    private unowned let store: StateStore

    init(store: StateStore) {
        self.store = store
    }

    func acquire(workerID: String, pid: Int32) throws -> Bool {
        if let current = try current(), isPIDAlive(current.pid) {
            return false
        }
        try release()
        try store.execute(
            "INSERT INTO worker_lease (singleton, worker_id, pid, heartbeat, job_id) VALUES (1, ?, ?, ?, NULL);",
            values: [.text(workerID), .int(Int64(pid)), .double(store.environment.clock.now().timeIntervalSince1970)]
        )
        return true
    }

    func updateHeartbeat(jobID: String?) throws {
        let heartbeat = store.environment.clock.now().timeIntervalSince1970
        try store.execute(
            "UPDATE worker_lease SET heartbeat = ?, job_id = ? WHERE singleton = 1;",
            values: [.double(heartbeat), .text(jobID)]
        )
        if let jobID {
            try store.simulatorLeases.updateHeartbeat(jobID: jobID, heartbeat: heartbeat)
        }
    }

    func current() throws -> WorkerLease? {
        try store.querySingle("SELECT worker_id, pid, heartbeat, job_id FROM worker_lease WHERE singleton = 1;", values: []) { statement in
            WorkerLease(
                workerID: String(cString: sqlite3_column_text(statement, 0)),
                pid: Int32(sqlite3_column_int(statement, 1)),
                heartbeat: sqlite3_column_double(statement, 2),
                jobID: sqliteString(statement, index: 3)
            )
        }
    }

    func release() throws {
        try store.execute("DELETE FROM worker_lease WHERE singleton = 1;")
    }

    func recoverStaleIfNeeded() throws -> Bool {
        guard let lease = try current(), !isPIDAlive(lease.pid) else {
            return false
        }
        try store.jobs.markRunningJobsInterrupted(finishedAt: store.environment.clock.now().timeIntervalSince1970)
        try release()
        _ = try store.simulatorLeases.recoverStale()
        return true
    }
}

struct SimulatorLeaseGateway {
    private unowned let store: StateStore

    init(store: StateStore) {
        self.store = store
    }

    func acquire(simulatorID: String, jobID: String, pid: Int32) throws -> Bool {
        _ = try recoverStale()
        let now = store.environment.clock.now().timeIntervalSince1970
        try store.execute(
            """
            INSERT OR IGNORE INTO simulator_leases (simulator_id, job_id, pid, acquired_at, heartbeat)
            VALUES (?, ?, ?, ?, ?);
            """,
            values: [.text(simulatorID), .text(jobID), .int(Int64(pid)), .double(now), .double(now)]
        )
        guard let lease = try fetch(simulatorID: simulatorID) else {
            return false
        }
        if lease.jobID == jobID, lease.pid == pid {
            try store.execute(
                "UPDATE simulator_leases SET heartbeat = ? WHERE simulator_id = ? AND job_id = ?;",
                values: [.double(now), .text(simulatorID), .text(jobID)]
            )
            return true
        }
        return false
    }

    func fetch(simulatorID: String) throws -> SimulatorLease? {
        try store.querySingle(
            "SELECT simulator_id, job_id, pid, acquired_at, heartbeat FROM simulator_leases WHERE simulator_id = ?;",
            values: [.text(simulatorID)],
            map: mapRow
        )
    }

    func list() throws -> [SimulatorLease] {
        try store.query(
            "SELECT simulator_id, job_id, pid, acquired_at, heartbeat FROM simulator_leases ORDER BY simulator_id ASC;",
            values: [],
            map: mapRow
        )
    }

    func release(simulatorID: String, jobID: String? = nil) throws {
        if let jobID {
            try store.execute(
                "DELETE FROM simulator_leases WHERE simulator_id = ? AND job_id = ?;",
                values: [.text(simulatorID), .text(jobID)]
            )
        } else {
            try store.execute("DELETE FROM simulator_leases WHERE simulator_id = ?;", values: [.text(simulatorID)])
        }
    }

    func release(jobID: String) throws {
        try store.execute("DELETE FROM simulator_leases WHERE job_id = ?;", values: [.text(jobID)])
    }

    func updateHeartbeat(jobID: String, heartbeat: Double) throws {
        try store.execute(
            "UPDATE simulator_leases SET heartbeat = ? WHERE job_id = ?;",
            values: [.double(heartbeat), .text(jobID)]
        )
    }

    @discardableResult
    func recoverStale() throws -> Int {
        let leases = try list()
        var recovered = 0
        for lease in leases where !isPIDAlive(lease.pid) {
            try release(simulatorID: lease.simulatorID)
            recovered += 1
        }
        return recovered
    }

    private func mapRow(_ statement: OpaquePointer?) throws -> SimulatorLease {
        guard let statement else {
            throw XCStewardError.commandFailed("Missing simulator lease row")
        }
        return SimulatorLease(
            simulatorID: String(cString: sqlite3_column_text(statement, 0)),
            jobID: String(cString: sqlite3_column_text(statement, 1)),
            pid: Int32(sqlite3_column_int(statement, 2)),
            acquiredAt: sqlite3_column_double(statement, 3),
            heartbeat: sqlite3_column_double(statement, 4)
        )
    }
}

struct TestTimingGateway {
    private unowned let store: StateStore

    init(store: StateStore) {
        self.store = store
    }

    func estimates(project: String, identifiers: [String]) throws -> [String: Double] {
        let wanted = Set(identifiers)
        guard !wanted.isEmpty else {
            return [:]
        }
        let rows = try store.query(
            "SELECT identifier, duration_seconds FROM test_timings WHERE project = ?;",
            values: [.text(project)]
        ) { statement in
            (
                identifier: String(cString: sqlite3_column_text(statement, 0)),
                duration: sqlite3_column_double(statement, 1)
            )
        }
        var result: [String: Double] = [:]
        for row in rows where wanted.contains(row.identifier) && row.duration > 0 {
            result[row.identifier] = row.duration
        }
        return result
    }

    func record(project: String, samples: [TestTimingSample]) throws {
        let now = store.environment.clock.now().timeIntervalSince1970
        for sample in samples {
            let identifier = sample.identifier.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !identifier.isEmpty, sample.durationSeconds > 0 else {
                continue
            }
            if let existing = try existingTiming(project: project, identifier: identifier) {
                try update(project: project, identifier: identifier, existing: existing, sample: sample, updatedAt: now)
            } else {
                try insert(project: project, identifier: identifier, sample: sample, updatedAt: now)
            }
        }
    }

    private func existingTiming(project: String, identifier: String) throws -> (duration: Double, samples: Int)? {
        try store.querySingle(
            "SELECT duration_seconds, samples FROM test_timings WHERE project = ? AND identifier = ?;",
            values: [.text(project), .text(identifier)]
        ) { statement in
            (
                duration: sqlite3_column_double(statement, 0),
                samples: Int(sqlite3_column_int(statement, 1))
            )
        }
    }

    private func update(
        project: String,
        identifier: String,
        existing: (duration: Double, samples: Int),
        sample: TestTimingSample,
        updatedAt: Double
    ) throws {
        let weight = Double(min(max(existing.samples, 1), 9))
        let updatedDuration = ((existing.duration * weight) + sample.durationSeconds) / (weight + 1)
        try store.execute(
            """
            UPDATE test_timings
            SET duration_seconds = ?, samples = ?, updated_at = ?
            WHERE project = ? AND identifier = ?;
            """,
            values: [
                .double(updatedDuration),
                .int(Int64(existing.samples + 1)),
                .double(updatedAt),
                .text(project),
                .text(identifier),
            ]
        )
    }

    private func insert(project: String, identifier: String, sample: TestTimingSample, updatedAt: Double) throws {
        try store.execute(
            """
            INSERT INTO test_timings (project, identifier, duration_seconds, samples, updated_at)
            VALUES (?, ?, ?, ?, ?);
            """,
            values: [
                .text(project),
                .text(identifier),
                .double(sample.durationSeconds),
                .int(1),
                .double(updatedAt),
            ]
        )
    }
}

struct InfrastructureEventGateway {
    private unowned let store: StateStore

    init(store: StateStore) {
        self.store = store
    }

    func record(
        jobID: String?,
        simulatorID: String?,
        resultClass: ResultClass,
        message: String?
    ) throws {
        guard resultClass.isInfrastructureFailure else {
            return
        }
        try store.execute(
            """
            INSERT INTO infrastructure_events (id, job_id, simulator_id, result_class, message, created_at)
            VALUES (?, ?, ?, ?, ?, ?);
            """,
            values: [
                .text(store.environment.uuidProvider.makeUUID()),
                .text(jobID),
                .text(simulatorID),
                .text(resultClass.rawValue),
                .text(message),
                .double(store.environment.clock.now().timeIntervalSince1970),
            ]
        )
    }

    func countRecentFailures(since timestamp: Double) throws -> Int {
        try recordedEventCount(since: timestamp) + terminalInfrastructureJobCount(since: timestamp)
    }

    private func recordedEventCount(since timestamp: Double) throws -> Int {
        try store.querySingle(
            """
            SELECT COUNT(*)
            FROM infrastructure_events
            WHERE created_at >= ?;
            """,
            values: [.double(timestamp)]
        ) { statement in
            Int(sqlite3_column_int64(statement, 0))
        } ?? 0
    }

    private func terminalInfrastructureJobCount(since timestamp: Double) throws -> Int {
        try store.querySingle(
            """
            SELECT COUNT(*)
            FROM jobs
            WHERE finished_at >= ?
              AND state = ?
              AND result_class IN (?, ?);
            """,
            values: [
                .double(timestamp),
                .text(JobState.failed.rawValue),
                .text(ResultClass.runnerBootstrapFailure.rawValue),
                .text(ResultClass.artifactFailure.rawValue),
            ]
        ) { statement in
            Int(sqlite3_column_int64(statement, 0))
        } ?? 0
    }
}

private enum SQLiteValue {
    case text(String?)
    case double(Double?)
    case int(Int64?)
}

private func sqliteString(_ statement: OpaquePointer?, index: Int32) -> String? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL,
          let pointer = sqlite3_column_text(statement, index) else {
        return nil
    }
    return String(cString: pointer)
}

private func sqliteNullableDouble(_ statement: OpaquePointer?, index: Int32) -> Double? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_double(statement, index)
}

private func sqliteNullableInt(_ statement: OpaquePointer?, index: Int32) -> Int64? {
    guard sqlite3_column_type(statement, index) != SQLITE_NULL else { return nil }
    return sqlite3_column_int64(statement, index)
}

private let SQLITE_TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
