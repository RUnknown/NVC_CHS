# Enable / disable / inspect the NVC_CHS localisation.
# Only configs and the payload DLL are added next to the exes; the exes are never modified.
# Every NVCleanstall*.exe gets its own <exe filename>.config: the CLR ignores a config whose
# name does not match the executable, so renamed portable builds need one each.
param(
    [switch] $Rollback,
    [switch] $Status
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$app  = Split-Path -Parent $here
$dll  = Join-Path $app 'NvcChs.dll'
$cfgSource = Join-Path $here 'NVCleanstall.exe.config'

$exes = @(Get-ChildItem -LiteralPath $app -Filter 'NVCleanstall*.exe' -File -ErrorAction SilentlyContinue)
if ($exes.Count -eq 0) { throw "No NVCleanstall*.exe found in: $app" }

function Get-TargetConfig([string] $exePath) { return $exePath + '.config' }

function Test-OurConfig([string] $cfgPath)
{
    if (-not (Test-Path -LiteralPath $cfgPath)) { return $false }
    return (Get-Content -LiteralPath $cfgPath -Raw) -match 'appDomainManagerType'
}

if ($Status)
{
    foreach ($e in $exes)
    {
        $c = Get-TargetConfig $e.FullName
        "EXE            : $($e.Name)"
        "  Hash         : $((Get-FileHash -LiteralPath $e.FullName -Algorithm SHA256).Hash)"
        "  Signature    : $((Get-AuthenticodeSignature -LiteralPath $e.FullName).Status)"
        "  Config       : $(Test-Path -LiteralPath $c) ($c)"
    }
    "PayloadDll     : $(Test-Path -LiteralPath $dll) ($dll)"
    "Dictionary     : $(Join-Path $app 'zh-CN.txt') / $(Join-Path $here 'zh-CN.txt')"
    "RootFiles      : $((Get-ChildItem -LiteralPath $app -File | Select-Object -ExpandProperty Name) -join ', ')"
    return
}

if ($Rollback)
{
    foreach ($e in $exes)
    {
        $c = Get-TargetConfig $e.FullName
        if (Test-OurConfig $c)
        {
            Remove-Item -LiteralPath $c -Force
            "Removed: $c"
        }
    }
    if (Test-Path -LiteralPath $dll) { Remove-Item -LiteralPath $dll -Force; "Removed: $dll" }
    "Localisation fully reverted. The NVCleanstall executables were never modified."
    return
}

foreach ($f in @($cfgSource, $dll, (Join-Path $here 'zh-CN.txt')))
{
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing required file: $f (run build.ps1 first)" }
}

foreach ($e in $exes)
{
    $c = Get-TargetConfig $e.FullName
    if ((Test-Path -LiteralPath $c) -and -not (Test-OurConfig $c))
    {
        throw "An unrelated config already exists at $c -- refusing to overwrite it."
    }
    Copy-Item -LiteralPath $cfgSource -Destination $c -Force
    "Installed config : $c"
}

"Payload DLL      : $dll (appbase, no probing required)"
"Dictionary       : $(Join-Path $app 'zh-CN.txt') or $(Join-Path $here 'zh-CN.txt')"
foreach ($e in $exes)
{
    "EXE unchanged    : $($e.Name) $((Get-FileHash -LiteralPath $e.FullName -Algorithm SHA256).Hash)"
}
""
"To disable:  & '$($MyInvocation.MyCommand.Path)' -Rollback"