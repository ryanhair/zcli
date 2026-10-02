#!/usr/bin/env python3
"""Build the generated-registry fixture and check real process exit semantics."""
from pathlib import Path
import os
import subprocess
import sys

root = Path(__file__).resolve().parents[3]
fixture = root / "packages/core/test/fixtures/invocation"
zig = sys.argv[1] if len(sys.argv) > 1 else "zig"
subprocess.run([zig, "build", "-j2"], cwd=fixture, check=True)
exe = fixture / "zig-out/bin" / ("invocation-fixture.exe" if os.name == "nt" else "invocation-fixture")

def run(args, code, contains=None, **kwargs):
    result = subprocess.run([str(exe), *args], capture_output=True, **kwargs)
    assert result.returncode == code, (args, result.returncode, result.stderr)
    if contains is not None:
        assert contains in result.stderr, (args, result.stderr)
    return result

run(["check", "--bogus"], 64, b"Unknown option")
for flag, value in [("--ports", "bad"), ("-p", "70000"), ("--tags", "a,,b"), ("-t", "a,")]:
    invalid = run(["check", "output", flag, value], 64, value.encode())
    assert b"for usage" in invalid.stderr, invalid.stderr
    assert invalid.stderr.count(b"Invalid value") == 1, invalid.stderr
    assert b"error:" not in invalid.stderr, invalid.stderr
    assert b".zig:" not in invalid.stderr, invalid.stderr
    assert invalid.stdout == b"", invalid.stdout
run(["check"], 64, b"Missing required argument")
run(["absent"], 65, b"Unknown command")
assert run(["check", "mapped"], 9).stderr == b"record missing\n"
assert run(["check", "reported"], 7).stderr == b"reported failure\n"
unexpected = run(["check", "unexpected"], 1, b"UnexpectedFixtureFailure")
assert b"check.zig" in unexpected.stderr, unexpected.stderr
if os.name != "nt":
    run(["check", "--bogus"], 64, preexec_fn=lambda: os.close(2))
    read_fd, write_fd = os.pipe()
    os.close(read_fd)
    try:
        broken = subprocess.run([str(exe), "check", "output"], stdout=write_fd, stderr=subprocess.PIPE)
    finally:
        os.close(write_fd)
    assert broken.returncode == 141, (broken.returncode, broken.stderr)
    assert broken.stderr == b"", broken.stderr
    with open(__file__, "rb") as unwritable:
        failed_write = subprocess.run([str(exe), "check", "output"], stdout=unwritable, stderr=subprocess.PIPE)
    assert failed_write.returncode == 1, failed_write
    assert b"failed to write output" in failed_write.stderr, failed_write.stderr
print("Generated invocation policy: statuses, diagnostics, original trace, and output failures passed")
