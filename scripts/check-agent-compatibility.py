#!/usr/bin/env python3
"""Run the existing agent regression suites and report compatibility by feature."""

import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import re
import signal
import subprocess
import sys
import tempfile
import time


ROOT = Path(__file__).resolve().parent.parent
# Exact suite boundaries: SessionRenameTests must not also select the installed-CLI suite.
GROUPS = {
    "state-routing": ["AgentDiagnosticTests", "AgentHookEventTests", "HookAgentDetectionTests", "HookAgentEndToEndTests", "AgentSessionRouteTests",
                      "CodexSessionEventsTests", "CodexSessionRouterTests", "CodexDaemonReconnectTests", "ClaudeAgentViewTests",
                      "SessionModelTests", "SessionPresenceModelTests"],
    "handoff": ["HookHandoffTests", "HandoffProtocolTests", "AgentCommandHandoffTests",
                "HandoffSkillAvailabilityTests"],
    "sessions-titles": ["AgentLaunchContextTests", "AgentSessionTests", "AgentSessionProviderTests",
                        "ClaudeSessionCatalogTests", "SessionAssociationTests", "SessionRenameTests",
                        "SessionDeletionTests", "AgentTerminalTitleTests", "CodexAppServerTests"],
    "output-speed": ["TranscriptSpeedTests"],
    "plugins-config": ["HookInstallerTests", "HookMarketplaceTests", "PluginCatalogTests", "MCPCatalogTests"],
    "installed-contracts": ["AgentContractTests", "AgentSessionMetadataIntegrationTests",
                            "CodexSessionDeletionIntegrationTests"],
}


def run(command, log, env, timeout):
    started = time.monotonic()
    print(f"Running {log.stem}…", flush=True)
    with log.open("w") as output:
        try:
            process = subprocess.Popen(command, cwd=ROOT, env=env, stdout=output,
                                       stderr=subprocess.STDOUT, start_new_session=True)
        except OSError as error:
            output.write(str(error) + "\n")
            return {"status": "failed", "exit_code": None, "seconds": 0, "log": str(log)}
        try:
            code = process.wait(timeout=timeout)
            status = "passed" if code == 0 else "failed"
        except (subprocess.TimeoutExpired, KeyboardInterrupt) as error:
            # Terminate the test process group, including helper subprocesses.
            try:
                os.killpg(process.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
            process.wait()
            if isinstance(error, KeyboardInterrupt):
                raise
            output.write(f"\nTimed out after {timeout}s\n")
            code, status = None, "timed-out"
    return {"status": status, "exit_code": code,
            "seconds": round(time.monotonic() - started, 2), "log": str(log)}


def summarize(result, content, suites):
    # Each XCTest bundle emits its own repeated summaries (including empty
    # bundles). Count case results, not the last bundle or all summary lines.
    xctest = re.findall(r"^Test Case .* (?:passed|failed|skipped) \(", content, re.MULTILINE)
    swift_testing = re.findall(r"Test run with (\d+) tests?", content)
    result["tests"] = len(xctest) + sum(map(int, swift_testing))
    skipped = [line for line in content.splitlines()
               if re.search(r"(?:Test|Suite|test case).*\bskipped\b", line, re.IGNORECASE)]
    missing = [suite for suite in suites
               if f"'{suite}' started" not in content and f"Suite {suite} started." not in content]
    if skipped:
        result["skipped"] = skipped
    if missing:
        result["missing_suites"] = missing
    if result["status"] == "passed" and (result["tests"] == 0 or skipped or missing):
        result["status"] = "incomplete"
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--fixtures-only", action="store_true",
                        help="run fixture regressions without checking installed Agent CLIs")
    parser.add_argument("--timeout", type=int, default=600, help="seconds per build/test step (default: 600)")
    args = parser.parse_args()
    if args.timeout <= 0:
        parser.error("--timeout must be positive")

    base = ROOT / ".build" / "agent-compatibility"
    base.mkdir(parents=True, exist_ok=True)
    output = Path(tempfile.mkdtemp(prefix=datetime.now().strftime("%Y%m%d-%H%M%S-"), dir=base))
    env = {key: value for key, value in os.environ.items() if not key.startswith("LIGHTTY_")}
    env["LIGHTTY_REQUIRE_AGENT_CONTRACTS"] = "1"
    report = {
        "schema_version": 1, "started_at": datetime.now(timezone.utc).isoformat(),
        "mode": "fixtures-only" if args.fixtures_only else "installed-and-fixtures",
        "agents": [], "checks": {},
        "scope": "Fixture regressions and installed CLI metadata contracts; not live model/TUI end-to-end validation.",
    }
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    report["revision"] = revision.stdout.strip()
    changes = subprocess.run(["git", "status", "--porcelain"], cwd=ROOT, capture_output=True, text=True)
    report["working_tree_dirty"] = bool(changes.stdout.strip())
    package = json.loads((ROOT / "scripts/claude-session-helper/package.json").read_text())
    report["claude_sdk"] = package["dependencies"]["@anthropic-ai/claude-agent-sdk"]
    print(f"Report directory: {output}", flush=True)

    def save():
        (output / "report.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")

    # Build prerequisites explicitly; no skipped helper tests from an unprepared checkout.
    prerequisites = [
        ("reporter-tests", [sys.executable, "-B", "-m", "unittest", "discover", "-s", "scripts/tests"]),
        ("prepare-helper", ["node", "scripts/prepare-claude-helper.mjs"]),
        ("build", ["swift", "build", "--build-tests"]),
    ]
    for name, command in prerequisites:
        result = run(command, output / f"{name}.log", env, args.timeout)
        report["checks"][name] = result
        save()
        if result["status"] != "passed":
            print(f"{name}: {result['status']} — {result['log']}")
            return 1

    for name, suites in GROUPS.items():
        if name == "installed-contracts" and args.fixtures_only:
            report["checks"][name] = {"status": "not-checked", "reason": "--fixtures-only"}
            continue
        pattern = r"\.(" + "|".join(suites) + r")/"
        log = output / f"{name}.log"
        result = run(["swift", "test", "--skip-build", "--filter", pattern], log, env, args.timeout)
        content = log.read_text(errors="replace")
        summarize(result, content, suites)
        for line in content.splitlines():
            if line.startswith("LIGHTTY_AGENT_VERSION "):
                report["agents"].append(json.loads(line.removeprefix("LIGHTTY_AGENT_VERSION ")))
        if name == "installed-contracts" and result["status"] == "passed":
            if {agent["agent"] for agent in report["agents"]} != {"claude", "codex"}:
                result["status"] = "incomplete"
        report["checks"][name] = result
        save()
        print(f"{name}: {result['status']} ({result['tests']} tests)", flush=True)

    save()
    print(f"Report: {output / 'report.json'}")
    return int(any(check["status"] not in ("passed", "not-checked") for check in report["checks"].values()))


if __name__ == "__main__":
    sys.exit(main())
