import XCTest

@testable import SystemUtils

final class SystemUtilsTests: XCTestCase {
    func test_get_xcode_version() async throws {
        guard let version = SystemUtils.xcodeVersion else {
            XCTFail("The Xcode version should not be nil.")
            return
        }
        let versionPattern = "^\\d+(\\.\\d+)*$"
        let versionTest = NSPredicate(format: "SELF MATCHES %@", versionPattern)
        
        XCTAssertTrue(versionTest.evaluate(with: version), "The Xcode version should match the expected format.")
        XCTAssertFalse(version.isEmpty, "The Xcode version should not be an empty string.")
    }
    
    func test_getLoginShellEnvironment() throws {
        // Test with a valid shell path
        let validShellPath = "/bin/zsh"
        let env = SystemUtils.shared.getLoginShellEnvironment(shellPath: validShellPath)
        
        XCTAssertNotNil(env, "Environment should not be nil for valid shell path")
        XCTAssertFalse(env?.isEmpty ?? true, "Environment should contain variables")
        
        // Check for essential environment variables
        XCTAssertNotNil(env?["PATH"], "PATH should be present in environment")
        XCTAssertNotNil(env?["HOME"], "HOME should be present in environment")
        XCTAssertNotNil(env?["USER"], "USER should be present in environment")
        
        // Test with an invalid shell path
        let invalidShellPath = "/nonexistent/shell"
        let invalidEnv = SystemUtils.shared.getLoginShellEnvironment(shellPath: invalidShellPath)
        XCTAssertNil(invalidEnv, "Environment should be nil for invalid shell path")
    }
    
    func test_appendCommonBinPaths() {
        // Test with an empty path
        let appendedEmptyPath = SystemUtils.shared.appendCommonBinPaths(path: "")
        XCTAssertFalse(appendedEmptyPath.isEmpty, "Result should not be empty when starting with empty path")
        XCTAssertTrue(appendedEmptyPath.contains("/usr/bin"), "Common path /usr/bin should be added")
        XCTAssertFalse(appendedEmptyPath.hasPrefix(":"), "Result should not start with ':'")
        
        // Test with a custom path
        let customPath = "/custom/bin:/another/custom/bin"
        let appendedCustomPath = SystemUtils.shared.appendCommonBinPaths(path: customPath)
        
        // Verify original paths are preserved
        XCTAssertTrue(appendedCustomPath.hasPrefix(customPath), "Original paths should be preserved")
        
        // Verify common paths are added
        XCTAssertTrue(appendedCustomPath.contains(":/usr/local/bin"), "Should contain /usr/local/bin")
        XCTAssertTrue(appendedCustomPath.contains(":/usr/bin"), "Should contain /usr/bin")
        XCTAssertTrue(appendedCustomPath.contains(":/bin"), "Should contain /bin")
        
        // Test with a path that already includes some common paths
        let existingCommonPath = "/usr/bin:/custom/bin"
        let appendedExistingPath = SystemUtils.shared.appendCommonBinPaths(path: existingCommonPath)
        
        // Check that /usr/bin wasn't added again
        let pathComponents = appendedExistingPath.split(separator: ":")
        let usrBinCount = pathComponents.filter { $0 == "/usr/bin" }.count
        XCTAssertEqual(usrBinCount, 1, "Common path should not be duplicated")
        
        // Make sure the result is a valid PATH string
        // First component should be the initial path components
        XCTAssertTrue(appendedExistingPath.hasPrefix(existingCommonPath), "Should preserve original path at the beginning")
    }
}
