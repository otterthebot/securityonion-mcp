import os
import stat
import subprocess
import textwrap
from pathlib import Path


def _write_executable(path: Path, content: str) -> None:
    path.write_text(content, encoding="utf-8")
    path.chmod(path.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _make_fake_repo(tmp_path: Path) -> tuple[Path, Path, Path]:
    repo = tmp_path / "repo"
    scripts_dir = repo / "scripts"
    logs_dir = repo / "logs"
    tests_dir = repo / "tests"
    fake_bin = tmp_path / "fake_bin"

    scripts_dir.mkdir(parents=True)
    logs_dir.mkdir(parents=True)
    tests_dir.mkdir(parents=True)
    fake_bin.mkdir(parents=True)

    source_script = Path(__file__).resolve().parents[1] / "scripts" / "weekly_security_audit.sh"
    target_script = scripts_dir / "weekly_security_audit.sh"
    target_script.write_text(source_script.read_text(encoding="utf-8"), encoding="utf-8")
    target_script.chmod(target_script.stat().st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

    requirements = textwrap.dedent(
        """\
        # Header line 1
        # Header line 2
        # Header line 3
        # Header line 4
        Requests>=2.0
        -r constraints.txt
        """
    )
    (repo / "requirements.txt").write_text(requirements, encoding="utf-8")
    (repo / "constraints.txt").write_text("urllib3<3\n", encoding="utf-8")
    (tests_dir / "test_placeholder.py").write_text("def test_placeholder():\n    assert True\n", encoding="utf-8")
    command_log = tmp_path / "command_log.txt"
    command_log.write_text("", encoding="utf-8")
    return repo, fake_bin, command_log


def _install_fake_commands(fake_bin: Path) -> None:
    _write_executable(
        fake_bin / "git",
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            echo "git $*" >> "${COMMAND_LOG}"
            args=("$@")
            if [[ "${args[0]:-}" == "-C" ]]; then
              args=("${args[@]:2}")
            fi
            case "${args[0]:-}" in
              fetch) exit 0 ;;
              rev-parse) echo "${GIT_BRANCH:-feature/testing}"; exit 0 ;;
              merge)
                if [[ "${GIT_MERGE_FAIL:-0}" == "1" ]]; then exit 1; fi
                exit 0
                ;;
              checkout) exit 0 ;;
              add) exit 0 ;;
              diff)
                if [[ "${GIT_DIFF_HAS_CHANGES:-1}" == "1" ]]; then exit 1; else exit 0; fi
                ;;
              commit) exit 0 ;;
              push) exit 0 ;;
              *) exit 0 ;;
            esac
            """
        ),
    )

    _write_executable(
        fake_bin / "pip",
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            echo "pip $*" >> "${COMMAND_LOG}"
            if [[ "${1:-}" == "freeze" ]]; then
              printf "%b\\n" "${PIP_FREEZE_OUTPUT:-requests==2.31.0}"
              exit 0
            fi
            exit 0
            """
        ),
    )

    _write_executable(
        fake_bin / "pip-audit",
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            echo "pip-audit $*" >> "${COMMAND_LOG}"
            exit "${PIP_AUDIT_EXIT:-0}"
            """
        ),
    )

    _write_executable(
        fake_bin / "python",
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            echo "python $*" >> "${COMMAND_LOG}"
            if [[ "${1:-}" == "-m" && "${2:-}" == "pytest" ]]; then
              exit "${PYTEST_EXIT:-0}"
            fi
            exit 0
            """
        ),
    )

    _write_executable(
        fake_bin / "gpg",
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            echo "gpg $*" >> "${COMMAND_LOG}"
            if [[ "${GPG_HAS_KEY:-0}" == "1" ]]; then
              echo "sec rsa4096/ABC1234567890"
            fi
            exit 0
            """
        ),
    )

    _write_executable(
        fake_bin / "gh",
        textwrap.dedent(
            """\
            #!/usr/bin/env bash
            set -euo pipefail
            echo "gh $*" >> "${COMMAND_LOG}"
            exit 0
            """
        ),
    )


def _run_audit_script(repo: Path, fake_bin: Path, command_log: Path, extra_env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    env = os.environ.copy()
    env.update(
        {
            "PATH": f"{fake_bin}:{env.get('PATH', '')}",
            "COMMAND_LOG": str(command_log),
            "GIT_DIFF_HAS_CHANGES": "1",
            "PIP_FREEZE_OUTPUT": "requests==2.31.0",
            "PYTEST_EXIT": "0",
            "PIP_AUDIT_EXIT": "0",
            "GPG_HAS_KEY": "0",
            "GIT_BRANCH": "feature/testing",
            "GIT_MERGE_FAIL": "0",
        }
    )
    env.update(extra_env)
    return subprocess.run(
        [str(repo / "scripts" / "weekly_security_audit.sh")],
        cwd=repo,
        env=env,
        text=True,
        capture_output=True,
        check=False,
    )


def test_weekly_audit_logs_and_falls_back_to_unsigned_commit(tmp_path: Path) -> None:
    repo, fake_bin, command_log = _make_fake_repo(tmp_path)
    _install_fake_commands(fake_bin)

    result = _run_audit_script(
        repo,
        fake_bin,
        command_log,
        {"GIT_BRANCH": "feature/testing", "GIT_MERGE_FAIL": "1", "GPG_HAS_KEY": "0"},
    )

    assert result.returncode == 0
    log_file = repo / "logs" / "weekly_security_audit.log"
    assert log_file.exists()
    log_text = log_file.read_text(encoding="utf-8")
    assert "WARNING: Could not fast-forward to origin/main" in log_text
    assert "WARNING: No GPG secret key found" in log_text
    assert "Weekly Security Audit" in log_text

    req_text = (repo / "requirements.txt").read_text(encoding="utf-8")
    assert "requests==2.31.0" in req_text
    assert "-r constraints.txt" in req_text

    commands = command_log.read_text(encoding="utf-8")
    assert "git -C" in commands
    assert "git -C" in commands and "fetch origin main" in commands
    assert "git -C" in commands and "commit -m chore: weekly security audit dependency update" in commands
    assert "commit -S -m chore: weekly security audit dependency update" not in commands
    assert "gh pr create" in commands


def test_weekly_audit_uses_signed_commit_when_gpg_key_exists(tmp_path: Path) -> None:
    repo, fake_bin, command_log = _make_fake_repo(tmp_path)
    _install_fake_commands(fake_bin)

    result = _run_audit_script(
        repo,
        fake_bin,
        command_log,
        {"GIT_BRANCH": "main", "GPG_HAS_KEY": "1"},
    )

    assert result.returncode == 0
    commands = command_log.read_text(encoding="utf-8")
    assert "commit -S -m chore: weekly security audit dependency update" in commands
    assert "commit -m chore: weekly security audit dependency update" not in commands


def test_weekly_audit_fails_when_tests_fail_and_keeps_log(tmp_path: Path) -> None:
    repo, fake_bin, command_log = _make_fake_repo(tmp_path)
    _install_fake_commands(fake_bin)

    result = _run_audit_script(
        repo,
        fake_bin,
        command_log,
        {"PYTEST_EXIT": "1"},
    )

    assert result.returncode != 0
    log_file = repo / "logs" / "weekly_security_audit.log"
    assert log_file.exists()
    log_text = log_file.read_text(encoding="utf-8")
    assert "ERROR: Test suite failed." in log_text
    assert "Skipping commit/push/PR because tests failed." in log_text

    commands = command_log.read_text(encoding="utf-8")
    assert "git -C" in commands and "checkout -b" not in commands
    assert "gh pr create" not in commands
