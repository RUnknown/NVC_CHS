# Enable / disable / inspect the NVC_CHS localisation.
# Only the config and the payload DLL are added next to the exe; the exe is never modified.
param(
    [switch] $Rollback,
    [switch] $Status
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$app  = Split-Path -Parent $here
$exe  = Join-Path $app 'NVCleanstall.exe'
$cfg  = Join-Path $app 'NVCleanstall.exe.config'
$dll  = Join-Path $app 'NvcChs.dll'
$cfgSource = Join-Path $here 'NVCleanstall.exe.config'

if (-not (Test-Path -LiteralPath $exe)) { throw "NVCleanstall.exe not found: $exe" }

if ($Status)
{
    "EXE            : $((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash)"
    "Signature      : $((Get-AuthenticodeSignature -LiteralPath $exe).Status)"
    "ConfigPresent  : $(Test-Path -LiteralPath $cfg)"
    "PayloadDll     : $(Test-Path -LiteralPath $dll)"
    "Dictionary     : $(Test-Path -LiteralPath (Join-Path $here 'zh-CN.txt'))"
    "RootFiles      : $((Get-ChildItem -LiteralPath $app -File | Select-Object -ExpandProperty Name) -join ', ')"
    return
}

if ($Rollback)
{
    foreach ($f in @($cfg, $dll))
    {
        if (Test-Path -LiteralPath $f)
        {
            Remove-Item -LiteralPath $f -Force
            "Removed: $f"
        }
    }
    "Localisation fully reverted. NVCleanstall.exe was never modified."
    return
}

foreach ($f in @($cfgSource, $dll, (Join-Path $here 'zh-CN.txt')))
{
    if (-not (Test-Path -LiteralPath $f)) { throw "Missing required file: $f (run build.ps1 first)" }
}

# Refuse to clobber an unrelated application config.
if (Test-Path -LiteralPath $cfg)
{
    $existing = Get-Content -LiteralPath $cfg -Raw
    if ($existing -notmatch 'appDomainManagerType')
    {
        throw "An unrelated config already exists at $cfg -- refusing to overwrite it."
    }
}

Copy-Item -LiteralPath $cfgSource -Destination $cfg -Force
"Installed config : $cfg"
"Payload DLL      : $dll (appbase, no probing required)"
"Dictionary       : $(Join-Path $here 'zh-CN.txt')"
"EXE unchanged    : $((Get-FileHash -LiteralPath $exe -Algorithm SHA256).Hash)"
"Signature        : $((Get-AuthenticodeSignature -LiteralPath $exe).Status)"
""
"To disable:  & '$($MyInvocation.MyCommand.Path)' -Rollback"
