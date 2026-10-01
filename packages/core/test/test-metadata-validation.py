#!/usr/bin/env python3
"""Check declaration diagnostics through a real generated application.

Optional (Python required); builds only, without executing the fixture. The
positive control prevents an unrelated compiler failure from passing negatives.
"""
from pathlib import Path
import subprocess
import sys

fixture = Path(__file__).resolve().parent / "fixtures/metadata"
zig = sys.argv[1] if len(sys.argv) > 1 else "zig"

def build(case):
    return subprocess.run(
        [zig, "build", "-j2", "-Dcase=" + case], cwd=fixture,
        stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
    )

positive = build("valid")
assert positive.returncode == 0, positive.stdout.decode(errors="replace")
cases = {
    "unknown_namespace": "meta.plugins.missing does not name a registered plugin with CommandConfig",
    "unknown_plugin_field": "meta.plugins.audit has unknown field 'typo'",
    "wrong_plugin_value": "expected type 'bool'",
    "missing_default": "CommandConfig field 'record' needs a default",
    "stdin_nontext": "enables `stdin` but must have type []const u8 or ?[]const u8",
    "delimiter_scalar": "declares `delimiter` but is not an array option",
    "unknown_top_level": "unknown meta field 'typo'",
    "unknown_option_field": "unknown option metadata field 'typo'",
}
for case, diagnostic in cases.items():
    result = build(case)
    output = result.stdout.decode(errors="replace")
    assert result.returncode != 0, case + " unexpectedly compiled"
    assert diagnostic in output, (case, diagnostic, output)
    print(case + ": expected declaration diagnostic")
print("Metadata validation: positive control and eight compile-error cases passed")
