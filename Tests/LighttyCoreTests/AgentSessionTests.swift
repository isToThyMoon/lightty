import XCTest
@testable import LighttyCore

final class AgentSessionTests: XCTestCase {
    func testLocalArchiveIsIndependentOfAgentAndSourceArchive() throws {
        var organization = SessionOrganization()
        let claude = AgentSession(key: .init(agent: .claude, sourceRoot: "/claude", nativeID: "same"),
            title: "Claude", workingDirectory: "/project", updatedAt: nil)
        let codex = AgentSession(key: .init(agent: .codex, sourceRoot: "/codex", nativeID: "same"),
            title: "Codex", workingDirectory: "/project", updatedAt: nil, sourceArchived: true)
        XCTAssertFalse(organization.isArchived(codex), "Native archive must not become lightty archive")
        organization.setArchived(true, session: claude)
        XCTAssertTrue(organization.isArchived(claude))
        XCTAssertFalse(organization.isArchived(codex), "Same native ID across agents is not the same session")
        organization.setArchived(true, session: codex)
        let decoded = try JSONDecoder().decode(SessionOrganization.self, from: JSONEncoder().encode(organization))
        XCTAssertTrue(decoded.isArchived(claude))
        XCTAssertTrue(decoded.isArchived(codex))
        organization.setArchived(false, session: codex)
        XCTAssertFalse(organization.isArchived(codex))
        XCTAssertTrue(codex.sourceArchived, "Restoring in lightty cannot change original Agent state")
    }

    func testMixedProjectArchiveAndRestorePreservesMembershipAndIndividualArchives() {
        var organization = SessionOrganization()
        let project = SessionProject(name: "Mixed")
        organization.projects = [project]
        let sessions = SessionAgent.allCases.map { agent in
            AgentSession(key: .init(agent: agent, sourceRoot: "/config", nativeID: agent.rawValue),
                title: agent.rawValue, workingDirectory: "/project", updatedAt: nil)
        }
        for session in sessions { organization.move(session, to: project.id) }
        organization.setArchived(true, session: sessions[0])
        organization.setArchived(true, projectID: project.id)
        XCTAssertTrue(sessions.allSatisfy(organization.isArchived))
        organization.setArchived(false, projectID: project.id)
        XCTAssertTrue(organization.isArchived(sessions[0]))
        XCTAssertFalse(organization.isArchived(sessions[1]))
        XCTAssertTrue(sessions.allSatisfy { organization.projectID(for: $0) == project.id })
        let other = SessionProject(name: "Other")
        organization.projects.append(other)
        organization.setArchived(true, projectID: project.id)
        organization.move(sessions[1], to: other.id)
        XCTAssertEqual(organization.projectID(for: sessions[1]), other.id)
        XCTAssertTrue(organization.isArchived(sessions[1]), "Moving a session is not restoring it")
    }

    func testRestoreOneSessionFromArchivedProjectMovesToRecentWithoutRestoringOthers() {
        var organization = SessionOrganization()
        let project = SessionProject(name: "Archived")
        organization.projects = [project]
        let session = AgentSession(key: .init(agent: .claude, sourceRoot: "/config", nativeID: "one"),
            title: "one", workingDirectory: "/project", updatedAt: nil)
        organization.move(session, to: project.id)
        organization.setArchived(true, projectID: project.id)
        organization.setArchived(false, session: session)
        XCTAssertNil(organization.projectID(for: session))
        XCTAssertFalse(organization.isArchived(session))
        XCTAssertTrue(organization.archivedProjects.contains(project.id))
    }

    func testOrganizationWithoutArchiveFieldsRemainsCompatible() throws {
        let old = Data(#"{"format":"lightty.organization","version":1,"projects":[],"assignments":[]}"#.utf8)
        let organization = try JSONDecoder().decode(SessionOrganization.self, from: old)
        XCTAssertTrue(organization.archivedSessions.isEmpty)
        XCTAssertTrue(organization.archivedProjects.isEmpty)
    }

    private func session(_ cwd: String = "/project/app") -> AgentSession {
        AgentSession(key: .init(agent: .codex, sourceRoot: "/config/codex", nativeID: "abc-123"),
                     title: "Example", workingDirectory: cwd, updatedAt: nil)
    }

    func testProjectMembershipIsExplicitAndIndependentOfWorkingDirectory() {
        var state = SessionOrganization()
        let parent = SessionProject(name: "Parent")
        let app = SessionProject(name: "App")
        state.projects = [parent, app]
        XCTAssertNil(state.projectID(for: session()))
        state.move(session(), to: app.id)
        XCTAssertEqual(state.projectID(for: session()), app.id)
        XCTAssertEqual(state.projectID(for: session("/different/directory")), app.id)
        state.assign(session().key, to: nil)
        XCTAssertNil(state.projectID(for: session()))
        state.assign(session().key, to: app.id)
        state.removeProject(app.id)
        XCTAssertNil(state.projectID(for: session()))
    }

    func testOrganizationRoundTripAndProviderIdentity() throws {
        var state = SessionOrganization()
        state.projects = [SessionProject(name: "中文", collapsed: true)]
        state.assign(session().key, to: state.projects[0].id)
        let decoded = try JSONDecoder().decode(SessionOrganization.self, from: JSONEncoder().encode(state))
        XCTAssertEqual(decoded, state)
        XCTAssertNotEqual(session().key, AgentSessionKey(agent: .claude, sourceRoot: "/config/codex", nativeID: "abc-123"))
    }

    func testResumeUsesOriginalAgentAndQuotesPathsWithoutBypass() throws {
        let plan = try SessionResumePlan(session: session(), executable: "/test path/it's codex",
                                        configuration: .custom("/config/codex"), launchArguments: [])
        XCTAssertEqual(plan.arguments, ["resume", "abc-123"])
        XCTAssertEqual(plan.environment, ["CODEX_HOME": "/config/codex"])
        XCTAssertEqual(plan.shellInput, "/usr/bin/env 'CODEX_HOME=/config/codex' '/test path/it'\\''s codex' 'resume' 'abc-123'\n")
        XCTAssertFalse(plan.shellInput.contains("--yolo"))
    }

    /// Resuming must land in the same permission mode as starting fresh, and each CLI accepts the
    /// flags in its own place: after codex's subcommand, before claude's `--resume`.
    func testResumeCarriesConfiguredLaunchFlagsWhereEachCLIAcceptsThem() throws {
        let codex = try SessionResumePlan(session: session(), executable: "/bin/codex",
                                          configuration: .standard, launchArguments: ["--yolo"])
        XCTAssertEqual(codex.arguments, ["resume", "--yolo", "abc-123"])
        XCTAssertTrue(codex.nativePickerInput.hasSuffix("'resume' '--yolo' '--all'\n"))

        let record = AgentSession(key: .init(agent: .claude, sourceRoot: "/config/claude", nativeID: "abc-123"),
                                  title: "", workingDirectory: "/repo", updatedAt: nil)
        let claude = try SessionResumePlan(session: record, executable: "/bin/claude",
                                           configuration: .standard,
                                           launchArguments: ["--permission-mode", "bypassPermissions"])
        XCTAssertEqual(claude.arguments, ["--permission-mode", "bypassPermissions", "--resume", "abc-123"])
        XCTAssertTrue(claude.nativePickerInput.hasSuffix("'--permission-mode' 'bypassPermissions' '--resume'\n"))

        for bad in [[""], ["--yolo\n; rm -rf /"]] {
            XCTAssertThrowsError(try SessionResumePlan(session: session(), executable: "/bin/codex",
                                                       configuration: .standard, launchArguments: bad))
        }
    }

    func testResumeRejectsOptionsAndShellPayloads() {
        for id in ["--help", "$(touch x)", "a\nb", "", "id;bad"] {
            let record = AgentSession(key: .init(agent: .codex, sourceRoot: "/config", nativeID: id),
                                      title: "", workingDirectory: "/repo", updatedAt: nil)
            XCTAssertThrowsError(try SessionResumePlan(session: record, executable: "/bin/codex",
                                                       configuration: .standard, launchArguments: []))
        }
    }

    func testConfigurationProvenanceIsNotInferredFromDirectory() throws {
        for agent in SessionAgent.allCases {
            let home = URL(fileURLWithPath: "/fixture/home")
            let standard = SessionConfigurationLocation.resolve(agent: agent, environment: [:])
            let root = standard.root(for: agent, home: home).path
            let explicit = SessionConfigurationLocation.resolve(agent: agent,
                environment: [agent.configurationVariable: root])
            XCTAssertEqual(standard, .standard)
            XCTAssertEqual(explicit, .custom(root))
            let record = AgentSession(key: .init(agent: agent, sourceRoot: root, nativeID: "abc-123"),
                                      title: "", workingDirectory: "/tmp", updatedAt: nil)
            let plan = try SessionResumePlan(session: record, executable: "/bin/echo",
                                             configuration: standard, launchArguments: [])
            XCTAssertEqual(plan.environment, [:])
            XCTAssertEqual(plan.unsetEnvironment, [agent.configurationVariable])
            XCTAssertTrue(plan.nativePickerInput.contains("-u '\(agent.configurationVariable)'"))
            let custom = try SessionResumePlan(session: record, executable: "/bin/echo",
                                               configuration: explicit, launchArguments: [])
            XCTAssertEqual(custom.environment, [agent.configurationVariable: root])
            XCTAssertEqual(custom.unsetEnvironment, [])
            XCTAssertThrowsError(try SessionResumePlan(session: record, executable: "/bin/echo",
                                                       configuration: .custom("/different/source"), launchArguments: []))
        }
    }

    func testResumeShellEnvironmentAndArgumentsWithoutTouchingUserConfiguration() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("fake agent")
        let script = "#!/bin/sh\nprintf '%s\\n' \"${CLAUDE_CONFIG_DIR-UNSET}\" \"$@\"\n"
        try script.write(to: executable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        let sentinel = directory.appendingPathComponent(".claude.json")
        let original = Data("{\"hasCompletedOnboarding\":true}".utf8)
        try original.write(to: sentinel)
        let record = AgentSession(key: .init(agent: .claude, sourceRoot: directory.path, nativeID: "abc-123"),
                                  title: "", workingDirectory: directory.path, updatedAt: nil)
        for location: SessionConfigurationLocation in [.standard, .custom(directory.path)] {
            let plan = try SessionResumePlan(session: record, executable: executable.path,
                                             configuration: location, launchArguments: [])
            for picker in [false, true] {
                let process = Process()
                process.executableURL = URL(fileURLWithPath: "/bin/sh")
                process.arguments = ["-c", picker ? plan.nativePickerInput : plan.shellInput]
                process.environment = ["PATH": "/usr/bin:/bin", "CLAUDE_CONFIG_DIR": "/wrong/inherited/root"]
                let output = Pipe()
                process.standardOutput = output
                try process.run()
                let data = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
                XCTAssertEqual(process.terminationStatus, 0)
                let expectedRoot = location == .standard ? "UNSET" : directory.path
                XCTAssertEqual(String(decoding: data, as: UTF8.self),
                               expectedRoot + "\n--resume\n" + (picker ? "" : "abc-123\n"))
            }
        }
        XCTAssertEqual(try Data(contentsOf: sentinel), original)
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)),
                       ["fake agent", ".claude.json"])
    }
}
