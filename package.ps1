# Package the release zip. Run build.ps1 first: the payload DLL is emitted next to the exe.
param(
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$app  = Split-Path -Parent $here
$dll  = Join-Path $app 'NvcChs.dll'

if (-not (Test-Path -LiteralPath $dll)) { throw "NvcChs.dll not found: $dll (run build.ps1 first)" }
if (-not $OutputPath) { $OutputPath = Join-Path $here 'NvcChs.zip' }

# Entry name => source file. Names are relative to the install directory and mirror its
# layout, so extracting the zip there is the whole install: the DLL reads its dictionary
# from <appbase>\NVC_CHS, never from beside the exe. Forward slashes are required by the
# ZIP spec; Compress-Archive on PowerShell 5.1 emits backslashes, so entries are written
# directly instead.
$manifest = [ordered]@{
    'NvcChs.dll'              = $dll
    'NVCleanstall.exe.config' = Join-Path $here 'NVCleanstall.exe.config'
    'NVC_CHS/zh-CN.txt'       = Join-Path $here 'zh-CN.txt'
    'README.md'               = Join-Path $here 'README.md'
}

foreach ($name in $manifest.Keys)
{
    if (-not (Test-Path -LiteralPath $manifest[$name]))
    {
        throw "Missing required file: $($manifest[$name])"
    }
}

$outParent = Split-Path -Parent $OutputPath
if ($outParent -and -not (Test-Path -LiteralPath $outParent))
{
    New-Item -ItemType Directory -Force -Path $outParent | Out-Null
}

Add-Type -AssemblyName System.IO.Compression
# FileMode.Create truncates an existing zip; ZipFile.Open(..., Create) refuses to.
$fs = [IO.File]::Open($OutputPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
try
{
    $zip = [System.IO.Compression.ZipArchive]::new($fs, [System.IO.Compression.ZipArchiveMode]::Create)
    try
    {
        foreach ($name in $manifest.Keys)
        {
            $stream = $zip.CreateEntry($name).Open()
            try
            {
                $bytes = [IO.File]::ReadAllBytes($manifest[$name])
                $stream.Write($bytes, 0, $bytes.Length)
            }
            finally { $stream.Dispose() }
        }
    }
    finally { $zip.Dispose() }
}
finally { $fs.Dispose() }

"Packaged: $OutputPath ($((Get-Item -LiteralPath $OutputPath).Length) bytes)"
"SHA256: $((Get-FileHash -LiteralPath $OutputPath -Algorithm SHA256).Hash)"
