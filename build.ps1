[CmdletBinding()]
param([string]$Compiler)

$ErrorActionPreference = 'Stop'
$p2dRoot = $PSScriptRoot
$p2dTemporary = $null
$p2dStagedExe = Join-Path $p2dRoot 'build\pas2dox.exe.new'
$p2dOwnStagedExe = $false
$p2dExitCode = 1

function Get-P2DHash([string]$Path) {
    $p2dStream = [IO.File]::OpenRead($Path)
    $p2dHash = [Security.Cryptography.SHA256]::Create()
    try { return [BitConverter]::ToString($p2dHash.ComputeHash($p2dStream)) }
    finally { $p2dHash.Dispose(); $p2dStream.Dispose() }
}

try {
    if (-not $Compiler) {
        $p2dCommand = Get-Command dcc64.exe -ErrorAction SilentlyContinue
        if ($p2dCommand) { $Compiler = $p2dCommand.Source }
        else { $Compiler = 'C:\Program Files (x86)\Embarcadero\Studio\22.0\bin\dcc64.exe' }
    }
    if (-not (Test-Path -LiteralPath $Compiler -PathType Leaf)) {
        throw 'Delphi Win64 compiler not found. Use build.cmd -Compiler "C:\path\to\dcc64.exe".'
    }
    $Compiler = (Resolve-Path -LiteralPath $Compiler).ProviderPath
    if ([IO.Path]::GetFileName($Compiler) -ine 'dcc64.exe') {
        throw 'This build creates the Windows x64 filter; select dcc64.exe.'
    }
    $p2dStudio = Split-Path (Split-Path $Compiler -Parent) -Parent
    $p2dLibrary = Join-Path $p2dStudio 'lib\win64\release'
    if (-not (Test-Path -LiteralPath $p2dLibrary -PathType Container)) {
        throw "Win64 RTL library not found: $p2dLibrary"
    }
    $p2dTemporary = Join-Path ([IO.Path]::GetTempPath()) ('Pas2Dox-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $p2dTemporary | Out-Null
    $p2dPasdoc = Join-Path $p2dRoot 'source\pasdoc'
    $p2dSource = Join-Path $p2dRoot 'source\pas2dox.dpr'
    $p2dArguments = @(
        '-B', '-Q', '-NSSystem;Winapi;System.Win;Xml',
        "-U$p2dPasdoc;$p2dLibrary", "-I$p2dPasdoc",
        "-E$p2dTemporary", "-N0$p2dTemporary", $p2dSource
    )
    & $Compiler @p2dArguments
    if ($LASTEXITCODE -ne 0) { throw "Compiler failed with exit code $LASTEXITCODE." }
    $p2dNewExe = Join-Path $p2dTemporary 'pas2dox.exe'
    $p2dVersion = & $p2dNewExe --version
    if ($LASTEXITCODE -ne 0 -or -not $p2dVersion) { throw 'Built filter failed its version check.' }
    $p2dExpected = [regex]::Match([IO.File]::ReadAllText($p2dSource), "const Version = '([^']+)'").Groups[1].Value
    if ($p2dVersion.Trim() -ne $p2dExpected) { throw 'Source and executable versions differ.' }
    $p2dOutput = Join-Path $p2dRoot 'build'
    if (-not (Test-Path -LiteralPath $p2dOutput)) { New-Item -ItemType Directory -Path $p2dOutput | Out-Null }
    if (Test-Path -LiteralPath $p2dStagedExe) { throw "Staged output already exists: $p2dStagedExe" }
    Copy-Item -LiteralPath $p2dNewExe -Destination $p2dStagedExe
    $p2dOwnStagedExe = $true
    if ((Get-P2DHash $p2dNewExe) -ne (Get-P2DHash $p2dStagedExe)) {
        throw 'Copied executable failed its hash check.'
    }
    $p2dFinalExe = Join-Path $p2dOutput 'pas2dox.exe'
    if (Test-Path -LiteralPath $p2dFinalExe) {
        [IO.File]::Replace($p2dStagedExe, $p2dFinalExe, [NullString]::Value)
    } else { Move-Item -LiteralPath $p2dStagedExe -Destination $p2dFinalExe }
    $p2dOwnStagedExe = $false
    [Console]::WriteLine("Built Pas2Dox $p2dVersion (Windows x64): $p2dFinalExe")
    $p2dExitCode = 0
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
} finally {
    if ($p2dOwnStagedExe -and (Test-Path -LiteralPath $p2dStagedExe)) {
        Remove-Item -LiteralPath $p2dStagedExe -Force
    }
    if ($p2dTemporary -and (Test-Path -LiteralPath $p2dTemporary)) {
        $p2dAllowedRoot = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
        $p2dResolvedTemp = (Resolve-Path -LiteralPath $p2dTemporary).ProviderPath
        if (-not $p2dResolvedTemp.StartsWith($p2dAllowedRoot, [StringComparison]::OrdinalIgnoreCase) -or
            [IO.Path]::GetFileName($p2dResolvedTemp) -notmatch '^Pas2Dox-[0-9a-f]{32}$') {
            throw 'Refusing to remove an unexpected temporary directory.'
        }
        Remove-Item -LiteralPath $p2dResolvedTemp -Recurse -Force
    }
}
exit $p2dExitCode
