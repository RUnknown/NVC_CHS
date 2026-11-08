# Build NvcChs.dll with the .NET Framework 4.x C# compiler; no WPF references.
# The CLR resolves AppDomainManager assemblies from the appbase, hence output next to the exe.
$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$app  = Split-Path -Parent $here
$csc  = 'C:\Windows\Microsoft.NET\Framework64\v4.0.30319\csc.exe'
$src  = Join-Path $here 'src\NvcChsManager.cs'
$out  = Join-Path $app 'NvcChs.dll'

if (-not (Test-Path -LiteralPath $csc)) { throw "csc.exe not found: $csc" }
if (-not (Test-Path -LiteralPath $src)) { throw "source not found: $src" }
if (-not (Test-Path -LiteralPath (Join-Path $app 'NVCleanstall.exe')))
{
    throw "NVCleanstall.exe not found next to output path: $app"
}

$outArg = '/out:' + $out
& $csc /nologo /target:library /optimize+ /platform:anycpu /warn:4 $outArg $src 2>&1
if ($LASTEXITCODE -ne 0) { throw "csc failed with exit code $LASTEXITCODE" }

$an = [System.Reflection.AssemblyName]::GetAssemblyName($out)
if ($an.Version.ToString() -ne '1.0.0.0')
{
    throw "Unexpected assembly version $($an.Version); config must match it."
}

$test = Join-Path $here 'tests\test.ps1'
if (-not (Test-Path -LiteralPath $test)) { throw "test not found: $test" }
& powershell.exe -NoProfile -ExecutionPolicy Bypass -File $test
if ($LASTEXITCODE -ne 0) { throw "test.ps1 failed with exit code $LASTEXITCODE" }

"Built: $out ($((Get-Item -LiteralPath $out).Length) bytes)"
"Assembly: $($an.FullName)"
"SHA256: $((Get-FileHash -LiteralPath $out -Algorithm SHA256).Hash)"
