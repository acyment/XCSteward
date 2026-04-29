import XCTest
@testable import XCStewardKit

final class DoctorCheckRegistryTests: XCTestCase {
    func testGlobalCheckRegistryHasStableUniqueIDs() {
        XCTAssertEqual(
            DoctorEngine.globalCheckIDs,
            [
                "global.state_root",
                "global.free_disk_space",
                "global.developer_dir_env_override",
                "global.clt_vs_xcode_selection",
                "global.first_launch_components",
                "global.iphonesimulator_sdk_present",
                "global.simulator_runtime_installed",
                "global.simulator_runtime_unavailable",
                "global.runtime_dyld_cache_state",
                "global.unavailable_devices_cleanup",
                "global.coresim_list_json_health",
                "global.concurrent_runner_contention",
                "global.disk_pressure_warning",
                "global.protected_path_warning",
                "global.xcode_cli_alignment",
                "global.worker_lease",
                "global.simulator_leases",
            ]
        )
        XCTAssertEqual(Set(DoctorEngine.globalCheckIDs).count, DoctorEngine.globalCheckIDs.count)
    }

    func testProjectCheckRegistryHasStableUniqueIDs() {
        XCTAssertEqual(
            DoctorEngine.projectCheckIDs,
            [
                "project.repo_root",
                "project.project_path",
                "project.scheme",
                "project.showdestinations_runnable",
                "project.testplan_exists",
                "project.derived_data_isolation",
                "project.xcode_managed_parallel_workers",
                "project.package_resolution_preflight",
                "project.xctestrun_integrity",
                "project.xcresulttool_compat",
                "project.default_simulator_bootstatus",
                "project.managed_simulator",
            ]
        )
        XCTAssertEqual(Set(DoctorEngine.projectCheckIDs).count, DoctorEngine.projectCheckIDs.count)
    }
}
