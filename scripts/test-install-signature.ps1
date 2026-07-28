#!/usr/bin/env pwsh
# Regression tests for install.ps1: its release-signature trust model, the
# release it resolves, the TLS floor it sets, and the registry contract its
# PATH handling depends on.
#
# install.ps1 is an `irm | iex` trust root: like install.sh it is the only
# validation most Windows users ever run, and no Zig test covers it. These
# assertions exist so a regression fails CI rather than shipping.
#
# Sections, each skipped only when its prerequisite genuinely cannot exist on
# the runner:
#
#   1. Signature version binding — needs `minisign`. Exercises the real
#      Test-Signature from the shipped install.ps1 with only the network fetch
#      stubbed. Mirrors scripts/test-install-signature.sh case for case; the two
#      installers must agree. Includes the hostile-`minisign`-function case
#      (#772): tool resolution must find an executable, not a profile-defined
#      function whose "success" would be a stale $LASTEXITCODE.
#   2. Release selection — no external tools. Get-LatestVersion must take the
#      newest `zcli-v*` from the release LIST, so a library tag published ahead
#      of the still-draft CLI tag cannot derail an install (#774).
#   3. TLS floor — no external tools. The protocol set must EXCLUDE TLS 1.0/1.1,
#      not merely include 1.2 (#773).
#   4. Registry value-kind contract — Windows only. Proves the .NET behavior the
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

$minisign = Get-Command minisign -CommandType Application -ErrorAction SilentlyContinue

$work = Join-Path ([System.IO.Path]::GetTempPath()) ("zcli-sigtest-" + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $work | Out-Null
try {
    # =======================================================================
    # Load the real install.ps1. It calls Main on load, so strip that one
    # trailing line and dot-source the rest. install.ps1 itself stays untouched
    # — this must exercise exactly what ships. If the invocation stops being a
    # bare trailing `Main`, fail loudly rather than dot-sourcing a script that
    # would run the installer for real.
    # =======================================================================
    $src = (Get-Content -Path $InstallPs1 -Raw).TrimEnd()
    if (-not $src.EndsWith("`nMain")) {
        Bad "install.ps1 no longer ends with a bare 'Main' invocation — update this harness's strip-and-source before it runs the installer for real"
        exit 1
    }
    $src = $src.Substring(0, $src.Length - 'Main'.Length)

    # install.ps1 computes $InstallDir via Join-Path at load time; on Linux and
    # macOS a 'C:' drive is rejected, so give it a loadable value. Nothing under
    # test touches it.
    if (-not $env:LOCALAPPDATA) { $env:LOCALAPPDATA = $work }

    # Put the process on a deliberately WEAK TLS floor before loading, so
    # section 3 can tell "install.ps1 assigned a modern-only set" apart from
    # "install.ps1 OR-ed TLS 1.2 into whatever was already permitted".
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.SecurityProtocolType]::Tls -bor [Net.SecurityProtocolType]::Tls11

    $shim = Join-Path $work 'installer-under-test.ps1'
    Set-Content -Path $shim -Value $src
    . $shim

    # =======================================================================
    # Section 1 — signature version binding
    # =======================================================================
    if (-not $minisign) {
        if ($env:ZCLI_REQUIRE_MINISIGN) {
            Bad 'ZCLI_REQUIRE_MINISIGN=1 but no minisign binary was found — the install.ps1 signature tests cannot run'
            exit 1
        }
        Note 'SKIP: minisign not installed (set ZCLI_REQUIRE_MINISIGN=1 to make this a failure)'
    } else {
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
        $MinisignPubkey = $pubkey

        # -------------------------------------------------------------------
        # #772: a hostile PowerShell profile defines `minisign` as a FUNCTION.
        #
        # A bare `Get-Command minisign` resolves it, and `& minisign` prefers a
        # function over an executable — so the "verification" would run the
        # hijack, which sets no exit code, leaving $LASTEXITCODE holding
        # whatever an earlier command left there. Seed that with the most
        # likely stale value, 0, and hand Test-Signature a TAMPERED
        # checksums.txt: the only thing that can reject it is a real minisign
        # actually running.
        # -------------------------------------------------------------------
        Note ''
        Note 'install.ps1 Test-Signature — hostile minisign function (#772)'
        function minisign { $script:HijackCalled = $true }
        try {
            $script:HijackCalled = $false
            $global:LASTEXITCODE = 0
            Check 'tampered release still rejected under a minisign function' `
                'reject' 'sig-0.20.0.minisig' 'zcli-v0.20.0' $tampered
            Assert-Result 'install.ps1: hostile minisign function never invoked' `
                'not-called' $(if ($script:HijackCalled) { 'called' } else { 'not-called' })
        } finally {
            Remove-Item -Path 'Function:\minisign' -ErrorAction SilentlyContinue
        }
    }

    # =======================================================================
    # Section 2 — release selection (#774)
    #
    # release.yml publishes two tag families: library tags (`v0.22.0`) go out
    # immediately, CLI tags (`zcli-v0.22.0`) stay drafts until their checksums
    # are signed offline. `/releases/latest` therefore returns the LIBRARY tag
    # for the whole of that window, which happens on every single release.
    # Get-LatestVersion must read the release list and take the newest
    # `zcli-v*` — and when there genuinely isn't one yet, say so in those words.
    #
    # Get-LatestVersion ends its failure paths with `exit`, which would take
    # this harness down with it. Calling it from a separate script FILE with `&`
    # contains that: the exit terminates only that file and surfaces as
    # $LASTEXITCODE here. The driver dot-sources the same shim, so it is still
    # the shipped function under test.
    # =======================================================================
    $driver = Join-Path $work 'run-latest-version.ps1'
    Set-Content -Path $driver -Value @'
param([string]$Shim, [string]$ReleasesFile, [switch]$Fail)
$ErrorActionPreference = 'Stop'
. $Shim
function Invoke-RestMethod {
    param($Uri, $Headers)
    if ($Fail) { throw 'simulated network failure' }
    # Emit an Object[] as ONE pipeline object, which is the shape the real
    # cmdlet produces. A stub that enumerated instead would quietly hide the
    # `@(Invoke-RestMethod …)` bug, where the wrap produces a one-element array
    # holding the whole list and every tag member-enumerates into one string.
    #
    # `@(…)` then `,` — NOT `Write-Output -NoEnumerate`, which since PowerShell
    # 7.4 hands back a List[Object] rather than an Object[]. That is a different
    # wrong shape, and it behaves differently enough that `@(…).Count` on it
    # throws — so the stub would have been testing something the installer will
    # never see.
    $parsed = @(Get-Content -Raw -Path $ReleasesFile | ConvertFrom-Json)
    return ,$parsed
}
Write-Output "version:$(Get-LatestVersion)"
exit 0
'@

    $releasesFile = Join-Path $work 'releases.json'

    # Returns the combined output text; sets $script:LatestVersion to the
    # resolved version, or 'reject' when the driver exited nonzero.
    function Invoke-LatestVersion { param([string]$Json, [switch]$Fail)
        Set-Content -Path $releasesFile -Value $Json
        # 6>&1 folds Write-Host (stream 6) in, so the diagnostics are visible
        # to the caller and not just to the console.
        $out = if ($Fail) { & $driver -Shim $shim -ReleasesFile $releasesFile -Fail 6>&1 }
               else       { & $driver -Shim $shim -ReleasesFile $releasesFile 6>&1 }
        $text = ($out | ForEach-Object { "$_" }) -join "`n"
        $script:LatestVersion = 'reject'
        if ($LASTEXITCODE -eq 0 -and $text -cmatch '(?m)^version:(.+)$') {
            $script:LatestVersion = $Matches[1]
        }
        return $text
    }

    function Check-Version { param([string]$Label, [string]$Expect, [string]$Json)
        Invoke-LatestVersion -Json $Json | Out-Null
        Assert-Result "install.ps1: $Label" $Expect $script:LatestVersion
    }

    Note ''
    Note 'install.ps1 Get-LatestVersion — newest installable zcli-v* release'
    Check-Version 'newest CLI tag wins over the library tag above it' '0.22.0' `
        '[{"tag_name":"v0.22.0"},{"tag_name":"zcli-v0.22.0"},{"tag_name":"v0.21.0"},{"tag_name":"zcli-v0.21.0"}]'
    Check-Version 'library tag published ahead of a draft CLI tag skipped' '0.21.0' `
        '[{"tag_name":"v0.22.0"},{"tag_name":"zcli-v0.21.0"},{"tag_name":"v0.21.0"}]'
    Check-Version 'case-variant tag family not accepted' 'reject' `
        '[{"tag_name":"ZCLI-V0.22.0"}]'
    Check-Version 'path-traversal tag rejected, not skipped over' 'reject' `
        '[{"tag_name":"zcli-v../../evil/releases/download/other-v9.9.9"},{"tag_name":"zcli-v0.21.0"}]'

    # A FULL page with no zcli-v tag is a different condition from a short one:
    # not "nothing is published yet" but "we may not have looked far enough
    # back". Sized from install.ps1's own constant so the fixture cannot drift.
    $fullPage = '[' + ((0..($ReleasesPageSize - 1) | ForEach-Object {
        "{`"tag_name`":`"v0.$_.0`"}" }) -join ',') + ']'
    Check-Version 'full page with no CLI tag rejected' 'reject' $fullPage

    # The two no-release outcomes get different advice, so they have to be told
    # apart: the mid-publish window clears on its own and the user should wait;
    # an exhausted page never will, and telling them to wait sends them after
    # something that is not going to happen.
    function Check-VersionMessage {
        param([string]$Label, [string]$Json, [string]$Want, [string]$Unwanted)
        $text = Invoke-LatestVersion -Json $Json
        $got = if ($text -notmatch [regex]::Escape($Want)) { "does not say '$Want': $text" }
               elseif ($text -match [regex]::Escape($Unwanted)) { "also says '$Unwanted': $text" }
               else { 'explained' }
        Assert-Result "install.ps1: $Label" 'explained' $got
    }

    $text = Invoke-LatestVersion -Json '[{"tag_name":"v0.22.0"},{"tag_name":"v0.21.0"}]'
    Assert-Result 'install.ps1: no zcli-v* release yet rejected' 'reject' $script:LatestVersion
    Check-VersionMessage 'mid-publish window explained to the user' `
        '[{"tag_name":"v0.22.0"},{"tag_name":"v0.21.0"}]' 'mid-publish' 'older than one page'
    Check-VersionMessage 'exhausted page distinguished from mid-publish' `
        $fullPage 'older than one page' 'mid-publish'

    $text = Invoke-LatestVersion -Json '[]' -Fail
    Assert-Result 'install.ps1: unreachable API rejected' 'reject' $script:LatestVersion

    # =======================================================================
    # Section 3 — TLS floor (#773)
    #
    # The load above ran install.ps1's protocol block on top of a deliberately
    # weak floor (TLS 1.0 | 1.1). OR-ing TLS 1.2 in would leave those two
    # enabled; assigning removes them. That difference is the whole issue.
    # =======================================================================
    Note ''
    Note 'install.ps1 TLS floor (set at load)'
    $sp = [Net.ServicePointManager]::SecurityProtocol
    Assert-Result 'install.ps1: TLS 1.2 permitted' 'yes' `
        $(if ($sp.HasFlag([Net.SecurityProtocolType]::Tls12)) { 'yes' } else { "no: $sp" })
    foreach ($weak in @('Ssl3', 'Tls', 'Tls11')) {
        $flag = [Net.SecurityProtocolType]$weak
        Assert-Result "install.ps1: $weak excluded, not merely deprioritized" 'excluded' `
            $(if ($sp.HasFlag($flag)) { "still permitted: $sp" } else { 'excluded' })
    }
} finally {
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
}

# ===========================================================================
# Section 4 — registry value-kind contract (Windows only)
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
