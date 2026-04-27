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
    private let environment: AppEnvironment
    private let db: OpaquePointer

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
        try execute("""
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
        try execute("""
        CREATE TABLE IF NOT EXISTS worker_lease (
            singleton INTEGER PRIMARY KEY CHECK(singleton = 1),
            worker_id TEXT NOT NULL,
            pid INTEGER NOT NULL,
            heartbeat REAL NOT NULL,
            job_id TEXT
        );
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    public func createJob(_ record: JobRecord) throws {
        let requestData = try jsonData(record.request)
        let summaryData = try record.summary.map(jsonData(_:))
        let sql = """
        INSERT INTO jobs (id, project, state, result_class, request_json, summary_json, job_directory, created_at, started_at, finished_at, process_id, simulator_id, cancel_requested)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?);
        """
        let values: [SQLiteValue] = [
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
        try execute(sql, values: values)
    }

    public func fetchJob(id: String) throws -> JobRecord? {
        try querySingle("SELECT * FROM jobs WHERE id = ?;", values: [.text(id)], map: mapJobRow)
    }

    public func listJobs() throws -> [JobRecord] {
        try query("SELECT * FROM jobs ORDER BY created_at ASC;", values: [], map: mapJobRow)
    }

    public func nextQueuedJob() throws -> JobRecord? {
        try querySingle("SELECT * FROM jobs WHERE state = 'queued' ORDER BY created_at ASC LIMIT 1;", values: [], map: mapJobRow)
    }

    public func updateJob(id: String, patch: JobStatePatch) throws {
        let sql = """
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
        """
        let summaryText = try patch.summary.flatMap { try String(data: jsonData($0), encoding: .utf8) }
        try execute(sql, values: [
            .text(patch.state?.rawValue),
            .text(patch.resultClass?.rawValue),
            .text(summaryText),
            .double(patch.startedAt),
            .double(patch.finishedAt),
            .int(patch.processID.map(Int64.init)),
            .text(patch.simulatorID),
            .int(patch.cancelRequested.map { $0 ? 1 : 0 }),
            .text(id),
        ])
    }

    public func requestCancel(jobID: String) throws {
        try execute("UPDATE jobs SET cancel_requested = 1 WHERE id = ?;", values: [.text(jobID)])
    }

    public func clearJobProcessID(id: String) throws {
        try execute("UPDATE jobs SET process_id = NULL WHERE id = ?;", values: [.text(id)])
    }

    public func acquireLease(workerID: String, pid: Int32) throws -> Bool {
        if let current = try currentLease(), isPIDAlive(current.pid) {
            return false
        }
        try execute("DELETE FROM worker_lease WHERE singleton = 1;")
        try execute(
            "INSERT INTO worker_lease (singleton, worker_id, pid, heartbeat, job_id) VALUES (1, ?, ?, ?, NULL);",
            values: [.text(workerID), .int(Int64(pid)), .double(environment.clock.now().timeIntervalSince1970)]
        )
        return true
    }

    public func updateLeaseHeartbeat(jobID: String?) throws {
        try execute(
            "UPDATE worker_lease SET heartbeat = ?, job_id = ? WHERE singleton = 1;",
            values: [.double(environment.clock.now().timeIntervalSince1970), .text(jobID)]
        )
    }

    public func currentLease() throws -> WorkerLease? {
        try querySingle("SELECT worker_id, pid, heartbeat, job_id FROM worker_lease WHERE singleton = 1;", values: []) { statement in
            WorkerLease(
                workerID: String(cString: sqlite3_column_text(statement, 0)),
                pid: Int32(sqlite3_column_int(statement, 1)),
                heartbeat: sqlite3_column_double(statement, 2),
                jobID: sqliteString(statement, index: 3)
            )
        }
    }

    public func releaseLease() throws {
        try execute("DELETE FROM worker_lease WHERE singleton = 1;")
    }

    public func recoverStaleLeaseIfNeeded() throws -> Bool {
        guard let lease = try currentLease(), !isPIDAlive(lease.pid) else {
            return false
        }
        if let running = try querySingle("SELECT * FROM jobs WHERE state = 'running' LIMIT 1;", values: [], map: mapJobRow) {
            try updateJob(
                id: running.id,
                patch: JobStatePatch(
                    state: .interrupted,
                    resultClass: .internalError,
                    finishedAt: environment.clock.now().timeIntervalSince1970
                )
            )
        }
        try releaseLease()
        return true
    }

    private func mapJobRow(_ statement: OpaquePointer?) throws -> JobRecord {
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

    private func execute(_ sql: String, values: [SQLiteValue] = []) throws {
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

    private func query<T>(_ sql: String, values: [SQLiteValue], map: (OpaquePointer?) throws -> T) throws -> [T] {
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

    private func querySingle<T>(_ sql: String, values: [SQLiteValue], map: (OpaquePointer?) throws -> T) throws -> T? {
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
