#!/usr/bin/env pwsh
# Regression tests for install.ps1's release-signature trust model, and for the
# registry contract its PATH handling depends on.
#
# install.ps1 is an `irm | iex` trust root: like install.sh it is the only
# validation most Windows users ever run, and no Zig test covers it. These
# assertions exist so a regression fails CI rather than shipping.
#
# Two independent sections, each skipped only when its prerequisite genuinely
# cannot exist on the runner:
#
#   1. Signature version binding — needs `minisign`. Exercises the real
#      Test-Signature from the shipped install.ps1 with only the network fetch
#      stubbed. Mirrors scripts/test-install-signature.sh case for case; the two
#      installers must agree.
#   2. Registry value-kind contract — Windows only. Proves the .NET behavior the
#      %VAR%-preservation fix rests on: that ExpandString round-trips as
#      REG_EXPAND_SZ, that DoNotExpandEnvironmentNames returns the raw text, and
#      that the default read expands it (the bug that flattened user PATHs).
#
# Usage: pwsh -NoProfile -File scripts/test-install-signature.ps1
#   ZCLI_REQUIRE_MINISIGN=1  a missing minisign binary is a hard failure rather
#                            than a skip (CI sets this on the legs that install it).
#   ZCLI_REQUIRE_REGISTRY=1  a non-Windows host is a hard failure rather than a
#                            skip (CI sets this on the Windows leg).
#
# Between them, every CI leg carries at least one of these flags, so no leg can
# quietly degrade to running nothing.

$ErrorActionPreference = 'Stop'

$RepoRoot = Split-Path -Parent (Split-Path -Parent $MyInvocation.MyCommand.Path)
$InstallPs1 = Join-Path $RepoRoot 'install.ps1'

$script:PassCount = 0
$script:FailCount = 0

function Note { param([string]$M) Write-Host $M }
function Bad  { param([string]$M) Write-Host "::error::$M" }

function Assert-Result {
    param([string]$Label, [string]$Expected, [string]$Actual)
    if ($Expected -ceq $Actual) {
        Note "  PASS  $Label"
        $script:PassCount++
    } else {
        Bad "$Label — expected $Expected, got $Actual"
        $script:FailCount++
    }
}

# ===========================================================================
# Section 1 — signature version binding
# ===========================================================================
$minisign = Get-Command minisign -ErrorAction SilentlyContinue
if (-not $minisign) {
    if ($env:ZCLI_REQUIRE_MINISIGN) {
        Bad 'ZCLI_REQUIRE_MINISIGN=1 but no minisign binary was found — the install.ps1 signature tests cannot run'
        exit 1
    }
    Note 'SKIP: minisign not installed (set ZCLI_REQUIRE_MINISIGN=1 to make this a failure)'
} else {
    $work = Join-Path ([System.IO.Path]::GetTempPath()) ("zcli-sigtest-" + [guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $work | Out-Null
    try {
        # -------------------------------------------------------------------
        # Load the real Test-Signature. install.ps1 calls Main on load, so strip
        # that one trailing line and dot-source the rest. install.ps1 itself
        # stays untouched — this must exercise exactly what ships. If the
        # invocation stops being a bare trailing `Main`, fail loudly rather than
        # dot-sourcing a script that would run the installer for real.
        # -------------------------------------------------------------------
        $src = (Get-Content -Path $InstallPs1 -Raw).TrimEnd()
        if (-not $src.EndsWith("`nMain")) {
            Bad "install.ps1 no longer ends with a bare 'Main' invocation — update this harness's strip-and-source before it runs the installer for real"
            exit 1
        }
        $src = $src.Substring(0, $src.Length - 'Main'.Length)

        # install.ps1 computes $InstallDir via Join-Path at load time; on Linux
        # and macOS a 'C:' drive is rejected, so give it a loadable value. The
        # signature path never touches it.
        if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = $work }

        $shim = Join-Path $work 'installer-under-test.ps1'
        Set-Content -Path $shim -Value $src
        . $shim

        # Fixtures: throwaway keypair, genuinely-signed checksums for two tags.
        & minisign -G -W -p (Join-Path $work 'test.pub') -s (Join-Path $work 'test.key') *> $null
        $pubkey = (Get-Content (Join-Path $work 'test.pub'))[1]

        $checksums = Join-Path $work 'checksums.txt'
        $tampered = Join-Path $work 'tampered.txt'
        Set-Content -Path $checksums -Value "abc123  zcli-x86_64-linux`ndef456  zcli-aarch64-macos" -NoNewline
        Set-Content -Path $tampered  -Value "abc123  zcli-x86_64-linux`nBADBAD  zcli-aarch64-macos" -NoNewline

        function New-TestSignature { param([string]$Out, [string]$Tag)
            & minisign -S -W -s (Join-Path $work 'test.key') -m $checksums -x (Join-Path $work $Out) `
                -t "zcli $Tag — signed release checksums" *> $null
        }
        New-TestSignature 'sig-0.20.0.minisig' 'zcli-v0.20.0'
        New-TestSignature 'sig-0.19.0.minisig' 'zcli-v0.19.0'
        New-TestSignature 'sig-0.2.minisig'    'zcli-v0.2'

        # Attacker rewrites the trusted comment to claim the new tag but cannot
        # re-sign it — minisign's global signature still covers the old text.
        $orig = Get-Content (Join-Path $work 'sig-0.19.0.minisig')
        Set-Content -Path (Join-Path $work 'sig-rewritten.minisig') -Value @(
            $orig[0], $orig[1], 'trusted comment: zcli zcli-v0.20.0 — signed release checksums', $orig[3])

        # Line 3 present but missing the `trusted comment: ` prefix.
        $orig20 = Get-Content (Join-Path $work 'sig-0.20.0.minisig')
        Set-Content -Path (Join-Path $work 'sig-noprefix.minisig') -Value @(
            $orig20[0], $orig20[1], 'zcli zcli-v0.20.0 — signed release checksums', $orig20[3])

        # Stub the network: Test-Signature fetches "<url>.minisig" into
        # "<checksums>.minisig". A function shadows the real cmdlet here.
        function Invoke-WebRequest {
            param($Uri, $OutFile, [switch]$UseBasicParsing)
            Copy-Item -Path $script:ServeSig -Destination $OutFile -Force
        }

        $MinisignPubkey = $pubkey

        function Check { param([string]$Label, [string]$Expect, [string]$Sig, [string]$Tag, [string]$Body)
            $script:ServeSig = Join-Path $work $Sig
            $run = Join-Path $work 'run-checksums.txt'
            Copy-Item $Body $run -Force
            try {
                $ok = [bool](Test-Signature -ChecksumsPath $run `
                    -ChecksumUrl 'https://example.invalid/checksums.txt' -ExpectedTag $Tag 6>$null)
            } catch {
                $ok = $false
            }
            Assert-Result "install.ps1: $Label" $Expect $(if ($ok) { 'accept' } else { 'reject' })
        }

        Note 'install.ps1 Test-Signature — version binding'
        Check 'matching tag accepted'                 'accept' 'sig-0.20.0.minisig'   'zcli-v0.20.0' $checksums
        Check 'downgrade replay rejected'             'reject' 'sig-0.19.0.minisig'   'zcli-v0.20.0' $checksums
        Check 'prefix tag rejected (v0.2 vs v0.20.0)' 'reject' 'sig-0.20.0.minisig'   'zcli-v0.2'    $checksums
        Check 'inverse prefix rejected'               'reject' 'sig-0.2.minisig'      'zcli-v0.20.0' $checksums
        Check 'case-only mismatch rejected'           'reject' 'sig-0.20.0.minisig'   'ZCLI-V0.20.0' $checksums
        Check 'rewritten trusted comment rejected'    'reject' 'sig-rewritten.minisig' 'zcli-v0.20.0' $checksums
        Check 'missing comment prefix rejected'       'reject' 'sig-noprefix.minisig' 'zcli-v0.20.0' $checksums
        Check 'tampered checksums rejected'           'reject' 'sig-0.20.0.minisig'   'zcli-v0.20.0' $tampered

        Note ''
        Note 'install.ps1 Test-Signature — pinned-key behavior'
        $MinisignPubkey = ''
        Check 'empty pinned key skips verification'   'accept' 'sig-0.19.0.minisig'   'zcli-v0.20.0' $checksums
    } finally {
        Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    }
}

# ===========================================================================
# Section 2 — registry value-kind contract (Windows only)
#
# Add-ToUserPath reads with DoNotExpandEnvironmentNames and writes ExpandString
# precisely so %VAR% entries survive. That rests on .NET behavior which cannot
# be observed off Windows, so pin it down here against a scratch key rather than
# the real user PATH.
# ===========================================================================
Note ''
if (-not $IsWindows) {
    if ($env:ZCLI_REQUIRE_REGISTRY) {
        Bad 'ZCLI_REQUIRE_REGISTRY=1 but this is not Windows — the registry contract tests cannot run'
        exit 1
    }
    Note 'SKIP: registry value-kind contract (Windows only)'
} else {
    Note 'registry value-kind contract (underpins install.ps1 PATH handling)'
    $testKeyPath = 'Software\zcli-installer-test'
    $raw = $null; $expanded = $null; $kind = $null
    $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($testKeyPath)
    try {
        $key.SetValue('Path', '%USERPROFILE%\bin;C:\literal',
            [Microsoft.Win32.RegistryValueKind]::ExpandString)
        $raw = $key.GetValue('Path', '',
            [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $expanded = $key.GetValue('Path', '')
        $kind = $key.GetValueKind('Path')
    } finally {
        $key.Dispose()
        [Microsoft.Win32.Registry]::CurrentUser.DeleteSubKeyTree($testKeyPath, $false)
    }

    Assert-Result 'ExpandString round-trips as REG_EXPAND_SZ' 'ExpandString' "$kind"
    Assert-Result 'DoNotExpandEnvironmentNames returns raw %VAR%' `
        '%USERPROFILE%\bin;C:\literal' $raw
    # The bug this guards: a default read expands, and writing that back as
    # REG_SZ is what permanently flattened the user's PATH.
    Assert-Result 'default read DOES expand (the flattening bug)' `
        'expanded' $(if ($expanded -ne $raw -and $expanded -notmatch '%USERPROFILE%') { 'expanded' } else { "unexpanded:$expanded" })
}

Note ''
Note "passed: $script:PassCount   failed: $script:FailCount"
if ($script:FailCount -ne 0) { exit 1 }
