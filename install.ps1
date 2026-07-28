#!/usr/bin/env pwsh
# zcli installer script for Windows
# Usage: irm https://zcli.sh/install.ps1 | iex
#
# Mirrors install.sh's security properties (see that file for the POSIX
# implementation and rationale):
#   - mandatory SHA-256 checksum verification; abort if unverifiable
#   - exact filename-field match against checksums.txt (no shadow-entry match)
#   - fail-closed minisign signature verification: if a public key is pinned
#     but minisign is unavailable, abort rather than degrade to checksum-only
#   - the signature must name the release tag being installed, as a whole
#     token, so a genuinely-signed OLDER release cannot be replayed under a
#     newer tag (downgrade/replay — CWE-294)
#   - latest-version resolution via the GitHub Releases API (install.sh has
#     no pinned-version mode to mirror; both always install latest)

$ErrorActionPreference = 'Stop'

# Require TLS 1.2 or newer for every request this script makes.
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Configuration
$Repo = 'ryanhair/zcli'
$InstallDir = Join-Path $env:LOCALAPPDATA 'Programs\zcli'
$BinaryName = 'zcli.exe'

# zcli's pinned minisign public key. Kept in sync with install.sh's
# MINISIGN_PUBKEY. The installer verifies checksums.txt against its detached
# signature (checksums.txt.minisig) under this key — closing the gap that
# checksums alone cannot: a compromised release can swap the binary AND its
# checksum, but not forge a signature under a key that never lived in the
# release pipeline (see ADR-0023).
#
# Verification is REQUIRED, never best-effort: while this key is set, a missing
# `minisign` tool aborts the install rather than degrading to checksum-only, and
# the signature must also name the exact release tag being installed (see
# Test-Signature below). Only an empty key — signing not enabled for a project —
# skips verification, leaving the fail-closed SHA-256 checksum check.
#
# Key id 1638B69B8EF680FD. The full key lives at docs/zcli-minisign.pub.
# Rotation/compromise: docs/RELEASE-SIGNING.md.
$MinisignPubkey = 'RWT9gPaOm7Y4Fm5WFqqlWRpI4FgPTIjD5UhUsaZsdKHrWYuWa9jt8ESC'

function Write-Info    { param([string]$Message) Write-Host "==> $Message" -ForegroundColor Blue }
function Write-Success { param([string]$Message) Write-Host "  [ok] $Message" -ForegroundColor Green }
function Write-WarnMsg { param([string]$Message) Write-Host "  !  $Message" -ForegroundColor Yellow }
function Write-ErrorMsg { param([string]$Message) Write-Host "  x  $Message" -ForegroundColor Red }

# Detect architecture. Only x86_64 and aarch64 Windows builds are published
# (see .github/workflows/release.yml's build matrix); anything else aborts.
function Get-Arch {
    switch ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture) {
        'X64'   { return 'x86_64' }
        'Arm64' { return 'aarch64' }
        default { return 'unknown' }
    }
}

# Verify checksums.txt against its detached minisign signature, and bind that
# signature to the exact release tag being installed.
#
# Fail closed: returns $true only when the signature actually verified (or
# signing is not enabled for this project). Signature verification is
# REQUIRED when a key is pinned — a missing `minisign` tool aborts the
# install rather than degrading to checksum-only, so a compromised publisher
# (who can rewrite the same-origin checksums) is defended against on every
# install path, not just `zcli upgrade`.
function Test-Signature {
    param(
        [string]$ChecksumsPath,
        [string]$ChecksumUrl,
        [string]$ExpectedTag
    )

    # Signing not yet enabled for this project — nothing to verify.
    if ([string]::IsNullOrEmpty($MinisignPubkey)) {
        return $true
    }

    if (-not (Get-Command minisign -ErrorAction SilentlyContinue)) {
        Write-ErrorMsg 'minisign is required to verify this release but was not found.'
        Write-ErrorMsg 'Install it and re-run:'
        Write-ErrorMsg '  winget:        winget install minisign'
        Write-ErrorMsg '  scoop:         scoop install minisign'
        Write-ErrorMsg '  Other:         https://jedisct1.github.io/minisign/#installation'
        Write-ErrorMsg "Or upgrade an existing install via 'zcli upgrade', which verifies natively."
        return $false
    }

    $sigPath = "$ChecksumsPath.minisig"
    try {
        Invoke-WebRequest -Uri "$ChecksumUrl.minisig" -OutFile $sigPath -UseBasicParsing | Out-Null
    } catch {
        Write-ErrorMsg "Signature file could not be downloaded ($ChecksumUrl.minisig)"
        Write-ErrorMsg 'This release is unsigned or incomplete; refusing to install.'
        return $false
    }

    & minisign -Vm $ChecksumsPath -x $sigPath -P $MinisignPubkey *> $null
    if ($LASTEXITCODE -ne 0) {
        Write-ErrorMsg 'Signature verification FAILED for checksums.txt'
        Write-ErrorMsg 'The release may have been tampered with. Aborting.'
        return $false
    }

    # Bind the signature to THIS release. The check above only authenticates
    # checksums.txt, which names artifacts but carries no version — so a
    # compromised publisher could serve an OLDER release's binary, checksums.txt
    # and its genuine .minisig under a newer tag and pass every check so far,
    # silently rolling the user back to a previously-signed (possibly vulnerable)
    # build (a downgrade/replay — CWE-294).
    #
    # The signing ceremony defends against this by embedding the release tag in
    # minisign's *trusted* comment (scripts/sign-release.sh: `-t "zcli $TAG —
    # signed release checksums"`). That comment is line 3 of the .minisig and is
    # covered by minisign's second, "global" signature on line 4 — the `-V` above
    # verifies it and exits nonzero ("Comment signature verification failed")
    # when it does not match, so by this point line 3 is authenticated and its
    # tag can be trusted. Reading it unverified would defeat the point.
    #
    # Kept in step with install.sh's verify_signature and with
    # verifyTrustedComment in
    # packages/core/src/plugins/zcli_github_upgrade/minisign.zig.
    $sigLines = @(Get-Content -Path $sigPath)
    if ($sigLines.Count -lt 3) {
        Write-ErrorMsg "Signature carries no trusted comment to bind $ExpectedTag."
        Write-ErrorMsg 'Refusing to install a release whose version cannot be verified.'
        return $false
    }

    $commentPrefix = 'trusted comment: '
    $commentLine = $sigLines[2].TrimEnd("`r")
    if (-not $commentLine.StartsWith($commentPrefix, [StringComparison]::Ordinal)) {
        Write-ErrorMsg "Signature carries no trusted comment to bind $ExpectedTag."
        Write-ErrorMsg 'Refusing to install a release whose version cannot be verified.'
        return $false
    }
    $trustedComment = $commentLine.Substring($commentPrefix.Length)

    # Whole-token match, not substring, so a shorter tag can never be satisfied
    # by a longer one (`zcli-v0.2` must not match `zcli-v0.20.0`, nor the
    # reverse). `-ceq` is the case-sensitive comparison — PowerShell's `-eq`
    # ignores case, which would not match the byte equality the Zig verifier and
    # install.sh both use.
    $tagBound = $false
    if (-not [string]::IsNullOrEmpty($ExpectedTag)) {
        foreach ($token in ($trustedComment -split '\s+')) {
            if ($token -ceq $ExpectedTag) {
                $tagBound = $true
                break
            }
        }
    }

    if (-not $tagBound) {
        Write-ErrorMsg "Signature does not name $ExpectedTag."
        Write-ErrorMsg "Trusted comment: $trustedComment"
        Write-ErrorMsg 'This looks like an older, genuinely-signed release replayed'
        Write-ErrorMsg 'under a newer tag. Refusing a possible downgrade. Aborting.'
        return $false
    }

    Write-Success "Signature verified (binds $ExpectedTag)"
    return $true
}

# Get latest release version from GitHub
function Get-LatestVersion {
    $headers = @{ 'User-Agent' = 'zcli-installer' }
    try {
        $release = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases/latest" -Headers $headers
    } catch {
        Write-ErrorMsg "Failed to get latest version: $($_.Exception.Message)"
        exit 1
    }

    # Defense-in-depth: validate the version against a strict charset before it
    # is interpolated into download URLs, mirroring the in-binary isValidVersionArg
    # check. Rejects '/', '..' and other path-traversal characters.
    if ($release.tag_name -notmatch '^zcli-v([A-Za-z0-9._-]+)$') {
        Write-ErrorMsg "Unexpected release tag format: $($release.tag_name)"
        exit 1
    }

    return $Matches[1]
}

# Download binary, verify it, and return the local path to the verified file.
function Get-ZcliBinary {
    param(
        [string]$Version,
        [string]$Arch
    )

    $target = "$Arch-windows"
    $url = "https://github.com/$Repo/releases/download/zcli-v$Version/zcli-$target.exe"
    $checksumUrl = "https://github.com/$Repo/releases/download/zcli-v$Version/checksums.txt"
    $tmpDir = Join-Path ([System.IO.Path]::GetTempPath()) ("zcli-install-" + [System.Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null
    $binaryPath = Join-Path $tmpDir 'zcli.exe'

    Write-Info "Downloading zcli $Version for $target..."

    try {
        Invoke-WebRequest -Uri $url -OutFile $binaryPath -UseBasicParsing | Out-Null
    } catch {
        Write-ErrorMsg "Failed to download binary from $url"
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        exit 1
    }

    # Verify the download. Verification is mandatory — if the checksums
    # can't be fetched, abort rather than install an unverified binary.
    Write-Info 'Verifying checksum...'
    $checksumsPath = Join-Path $tmpDir 'checksums.txt'
    try {
        Invoke-WebRequest -Uri $checksumUrl -OutFile $checksumsPath -UseBasicParsing | Out-Null
    } catch {
        Write-ErrorMsg "Failed to download checksums from $checksumUrl"
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        exit 1
    }

    # Authenticate checksums.txt against its signature before trusting it, and
    # require that signature to name the tag we are installing. Fail closed: a
    # signature failure, a version mismatch, or a missing minisign tool when a
    # key is pinned all abort the install.
    if (-not (Test-Signature -ChecksumsPath $checksumsPath -ChecksumUrl $checksumUrl -ExpectedTag "zcli-v$Version")) {
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        exit 1
    }

    # Exact filename-field match so e.g. a "zcli-${target}-debug.exe" entry
    # can never shadow the real one.
    $expectedChecksum = $null
    foreach ($line in Get-Content -Path $checksumsPath) {
        $fields = $line -split '\s+', 2
        if ($fields.Length -ge 2 -and $fields[1].TrimStart('*') -eq "zcli-$target.exe") {
            $expectedChecksum = $fields[0]
            break
        }
    }
    if ([string]::IsNullOrEmpty($expectedChecksum)) {
        Write-ErrorMsg "No checksum entry for zcli-$target.exe in checksums.txt"
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        exit 1
    }

    $actualChecksum = (Get-FileHash -Algorithm SHA256 -Path $binaryPath).Hash.ToLowerInvariant()

    if ($expectedChecksum.ToLowerInvariant() -ne $actualChecksum) {
        Write-ErrorMsg 'Checksum verification failed!'
        Remove-Item -Recurse -Force $tmpDir -ErrorAction SilentlyContinue
        exit 1
    }
    Write-Success 'Checksum verified'

    return $binaryPath
}

# Install binary to $InstallDir
function Install-ZcliBinary {
    param([string]$BinaryPath)

    Write-Info "Installing to $InstallDir..."

    if (-not (Test-Path -Path $InstallDir)) {
        New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
        Write-Success "Created $InstallDir"
    }

    $dest = Join-Path $InstallDir $BinaryName
    Copy-Item -Path $BinaryPath -Destination $dest -Force

    Write-Success "Installed $BinaryName to $InstallDir"
}

# Check if a directory is in the current session's PATH
function Test-InPath {
    param([string]$Dir)

    $normalized = $Dir.TrimEnd('\')
    foreach ($entry in ($env:Path -split ';')) {
        if ($entry.TrimEnd('\') -ieq $normalized) {
            return $true
        }
    }
    return $false
}

# Tell the shell (and Explorer) that the environment block changed.
#
# DO NOT DELETE THIS AS REDUNDANT. It is not belt-and-braces; it repairs a
# regression that Add-ToUserPath's registry fix would otherwise introduce.
# [Environment]::SetEnvironmentVariable used to broadcast WM_SETTINGCHANGE for us
# as a side effect. Add-ToUserPath no longer calls it (see the comment there: that
# API flattens %VAR% references), and a raw registry write broadcasts nothing — so
# without this, a terminal started from the running Explorer session inherits a
# stale environment block and keeps the old PATH until the user logs out, making
# this script's own "restart your terminal, then run zcli --help" advice wrong.
#
# Best effort: PATH is already persisted by the time this runs, so a failure here
# is a warning, not an aborted install.
function Send-EnvironmentChange {
    try {
        if (-not ('ZcliNative.Win32' -as [type])) {
            Add-Type -Namespace 'ZcliNative' -Name 'Win32' -MemberDefinition @'
[DllImport("user32.dll", SetLastError = true, CharSet = CharSet.Auto)]
public static extern IntPtr SendMessageTimeout(
    IntPtr hWnd, uint Msg, UIntPtr wParam, string lParam,
    uint fuFlags, uint uTimeout, out UIntPtr lpdwResult);
'@
        }
        $result = [UIntPtr]::Zero
        # HWND_BROADCAST, WM_SETTINGCHANGE, SMTO_ABORTIFHUNG, 5s timeout.
        [void][ZcliNative.Win32]::SendMessageTimeout(
            [IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 0x2, 5000, [ref]$result)
    } catch {
        Write-WarnMsg 'Could not notify running programs of the PATH change; log out and back in if a new terminal cannot find zcli.'
    }
}

# Add a directory to the persistent per-user PATH (if not already present).
#
# This goes through the registry rather than [Environment]::GetEnvironmentVariable
# / SetEnvironmentVariable on purpose: the getter EXPANDS %VAR% references and the
# setter writes the result back as REG_SZ, so a user PATH containing (say)
# `%USERPROFILE%\bin` would be permanently flattened to today's literal path and
# stop tracking the variable. Reading with DoNotExpandEnvironmentNames and writing
# RegistryValueKind.ExpandString leaves those references exactly as the user wrote
# them.
function Add-ToUserPath {
    param([string]$Dir)

    $normalized = $Dir.TrimEnd('\')

    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    if ($null -eq $key) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
    }

    try {
        $current = $key.GetValue(
            'Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        $entries = @()
        if (-not [string]::IsNullOrEmpty($current)) {
            $entries = $current -split ';'
        }

        # Entries are raw now, so compare both the literal text and its expansion —
        # otherwise an existing `%LOCALAPPDATA%\Programs\zcli` would no longer be
        # recognized and we would append a duplicate.
        foreach ($entry in $entries) {
            if ([string]::IsNullOrWhiteSpace($entry)) { continue }
            $expanded = [Environment]::ExpandEnvironmentVariables($entry)
            if (($entry.TrimEnd('\') -ieq $normalized) -or ($expanded.TrimEnd('\') -ieq $normalized)) {
                Write-Success 'PATH already configured for future sessions'
                return
            }
        }

        $new = if ($entries.Length -eq 0) { $Dir } else { "$current;$Dir" }
        $key.SetValue('Path', $new, [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally {
        if ($null -ne $key) { $key.Dispose() }
    }

    Send-EnvironmentChange
    Write-Success "Added $Dir to your user PATH"
}

# Main installation flow
function Main {
    Write-Info 'Installing zcli...'
    Write-Host ''

    $arch = Get-Arch
    if ($arch -eq 'unknown') {
        $osArch = [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture
        Write-ErrorMsg "Unsupported platform: Windows $osArch"
        exit 1
    }

    Write-Info "Detected platform: $arch-windows"

    $version = Get-LatestVersion
    if ([string]::IsNullOrEmpty($version)) {
        Write-ErrorMsg 'Failed to get latest version'
        exit 1
    }

    $binaryPath = Get-ZcliBinary -Version $version -Arch $arch

    Install-ZcliBinary -BinaryPath $binaryPath

    Remove-Item -Recurse -Force (Split-Path -Parent $binaryPath) -ErrorAction SilentlyContinue

    Write-Host ''
    Write-Success "zcli $version installed successfully!"
    Write-Host ''

    if (Test-InPath $InstallDir) {
        Write-Success "$InstallDir is already in your PATH"
        Write-Host '==> You can now use: zcli --help' -ForegroundColor Blue
    } else {
        Write-WarnMsg "$InstallDir is not in your PATH"

        Add-ToUserPath $InstallDir

        Write-Host ''
        Write-Info 'To use zcli immediately in this session, run:'
        Write-Host ''
        Write-Host "    `$env:Path += ';$InstallDir'" -ForegroundColor Green
        Write-Host ''
        Write-Info 'Or restart your terminal, then run:'
        Write-Host ''
        Write-Host '    zcli --help' -ForegroundColor Green
        Write-Host ''
    }
}

Main
