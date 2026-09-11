import XCTest
@testable import HatebuCore

/// Exercise actual pipes/processes, including inherited pipes in tool subprocesses.
final class RunnerTests: XCTestCase {
    var paths: DataPaths!
    var cli: String!
    override func setUpWithError() throws {
        paths = DataPaths(directory: FileManager.default.temporaryDirectory.appendingPathComponent("hatebu-runner-" + UUID().uuidString).path)
        try paths.prepare()
        cli = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/hatebu").path
        XCTAssertTrue(FileManager.default.isExecutableFile(atPath: cli))
    }
    override func tearDownWithError() throws { try FileManager.default.removeItem(at: paths.root) }

    func script(_ body: String) throws -> String {
        let file = paths.root.appendingPathComponent("fake-codex")
        try ("#!/bin/bash\n" + body).write(to: file, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700],ofItemAtPath: file.path)
        return file.path
    }
    func request(_ executable: String) -> CodexRequest {
        CodexRequest(executable: executable,searchCLI: cli,paths: paths,conversation: Conversation(),question: "日本語で探す",candidates: [])
    }
    func testRealPipeStreamingAndLargeStderr() async throws {
        let executable = try script("""
        cat >/dev/null
        printf '%s\\n' '{"type":"thread.started","thread_id":"fake-thread"}'
        head -c 90000 /dev/zero >&2
        printf '%s\\n' '{"type":"item.started","item":{"id":"search-1","type":"command_execution"}}'
        sleep 0.1
        printf '%s\\n' '{"type":"item.completed","item":{"id":"search-1","type":"command_execution","exit_code":0,"aggregated_output":"{\\"query\\":\\"日本語\\",\\"items\\":[],\\"elapsedMilliseconds\\":1,\\"hasMore\\":false}"}}'
        printf '%s\\n' '{"type":"item.completed","item":{"type":"agent_message","text":"{\\"message\\":\\"候補なし。条件を変えましょう\\",\\"bookmarkIDs\\":[]}"}}'
        printf '%s\\n' '{"type":"turn.completed"}'
        """)
        let completed = expectation(description: "completed"), activity = expectation(description: "query and count")
        let runner = CodexRunner()
        runner.start(request(executable),onEvent: { event in
            if case .activity(let value) = event, value.state == .completed {
                XCTAssertEqual(value.title,"「日本語」 · 0 件"); activity.fulfill()
            }
        },completion: { result in
            switch result {
            case .success(let answer): XCTAssertEqual(answer.message,"候補なし。条件を変えましょう"); XCTAssertEqual(answer.bookmarkIDs,[])
            case .failure(let error): XCTFail(error.localizedDescription)
            }
            completed.fulfill()
        })
        await fulfillment(of: [activity,completed],timeout: 8)
    }
    func testStopTerminatesToolChildrenAndCompletes() async throws {
        let executable = try script("""
        cat >/dev/null
        sleep 60 &
        printf '%s\\n' '{"type":"thread.started","thread_id":"cancel-thread"}'
        wait
        """)
        let done = expectation(description: "cancelled")
        let runner = CodexRunner()
        runner.start(request(executable),onEvent: { event in
            if case .thread = event { runner.cancel() }
        },completion: { result in
            if case .failure(let error) = result { XCTAssertTrue(error is CancellationError) }
            else { XCTFail("Cancellation must not produce an answer") }
            done.fulfill()
        })
        await fulfillment(of: [done],timeout: 6)
    }
    func testErrorExitKeepsEventsButDoesNotAcceptAnAnswer() async throws {
        let executable = try script("""
        cat >/dev/null
        printf '%s\\n' '{"type":"thread.started","thread_id":"failed-thread"}'
        printf '%s\\n' '{"type":"error","message":"login expired"}'
        exit 1
        """)
        let done = expectation(description: "failed"), thread = expectation(description: "thread retained")
        CodexRunner().start(request(executable),onEvent: { event in
            if case .thread("failed-thread") = event { thread.fulfill() }
        },completion: { result in
            if case .failure(let error) = result { XCTAssertEqual(error.localizedDescription,"login expired") }
            else { XCTFail("Failed turn must not complete") }
            done.fulfill()
        })
        await fulfillment(of: [thread,done],timeout: 6)
    }
}
