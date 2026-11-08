# Regression checks for NvcChs.dll. Run build.ps1 first; build.ps1 runs this.
# Windows PowerShell 5.1 only: it needs WPF on an STA thread.
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ge 6)
{
    throw 'Run this with powershell.exe (Windows PowerShell 5.1), not pwsh.'
}
# PresentationFramework alone does not pull in its dependencies here, and the
# loader looks types up by scanning loaded assemblies.
Add-Type -AssemblyName WindowsBase
Add-Type -AssemblyName PresentationCore
Add-Type -AssemblyName PresentationFramework
Add-Type -AssemblyName System.IO.Compression.FileSystem

$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$repo = Split-Path -Parent $here
$app  = Split-Path -Parent $repo
$dll  = Join-Path $app 'NvcChs.dll'
$dict = Join-Path $repo 'zh-CN.txt'
if (-not (Test-Path -LiteralPath $dll)) { throw "NvcChs.dll not found: $dll (run build.ps1 first)" }
if (-not (Test-Path -LiteralPath $dict)) { throw "zh-CN.txt not found: $dict" }

$asm  = [Reflection.Assembly]::LoadFrom($dll)
$type = $asm.GetType('NvcChs.NvcChsManager')
if ($null -eq $type) { throw 'Type NvcChs.NvcChsManager is missing; NVCleanstall.exe.config pins that name.' }

$f     = [Reflection.BindingFlags]'NonPublic,Static'
$utf8  = New-Object System.Text.UTF8Encoding($false)
$tr    = $type.GetMethod('Translate', $f)
$fresh = $type.GetMethod('EnsureDictionaryFresh', $f)

function GetField([string] $name)
{
    $type.GetField($name, $f).GetValue($null)
}

function SetField([string] $name, $value)
{
    $type.GetField($name, $f).SetValue($null, $value)
}

$script:failed = 0
function Check([string] $name, [bool] $ok, [string] $detail)
{
    if ($ok) { "PASS  $name" }
    else { $script:failed++; "FAIL  $name -- $detail" }
}

$tmp = Join-Path $env:TEMP ('nvcchs-' + [guid]::NewGuid().ToString('N') + '.txt')
try
{
    # ---- dictionary parsing ----
    [IO.File]::WriteAllText($tmp, "Alpha=AAA`r`nBeta=BBB`r`n*Speed =SPD ", $utf8)
    SetField '_dictPath' $tmp
    SetField '_dictStamp' ([datetime]::MinValue)
    $fresh.Invoke($null, $null)

    $v = $tr.Invoke($null, @('Alpha'))
    Check 'dictionary loads' ($v -eq 'AAA') "Translate(Alpha) returned [$v]"

    $v = $tr.Invoke($null, @('Speed 42'))
    Check 'prefix rule keeps the tail' ($v -eq 'SPD 42') "Translate(Speed 42) returned [$v]"

    $v = $tr.Invoke($null, @('  Alpha  '))
    Check 'trim keeps the padding' ($v -eq '  AAA  ') "Translate('  Alpha  ') returned [$v]"

    # ---- a save that lands while the file is locked must not wipe the dictionary ----
    [IO.File]::WriteAllText($tmp, "Gamma=CCC`r`n", $utf8)
    $lock = [IO.File]::Open($tmp, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
    try
    {
        SetField '_dictStamp' ([datetime]::MinValue)
        $fresh.Invoke($null, $null)
    }
    finally { $lock.Dispose() }

    $v = $tr.Invoke($null, @('Alpha'))
    Check 'failed reload keeps the old dictionary' ($v -eq 'AAA') "after a blocked reload, Translate(Alpha) returned [$v]"

    $fresh.Invoke($null, $null)
    $v = $tr.Invoke($null, @('Gamma'))
    Check 'reload retries once the file is readable' ($v -eq 'CCC') "Translate(Gamma) returned [$v]"

    # ---- an absent dictionary must not look like a healthy untranslated session ----
    $absent = Join-Path $env:TEMP ('nvcchs-absent-' + [guid]::NewGuid().ToString('N') + '.txt')
    try
    {
        SetField '_dictPath' $absent
        SetField '_dictStamp' ([datetime]::MinValue)
        SetField '_lastError' ''
        $type.GetField('RecordedOnce', $f).GetValue($null).Clear()
        $fresh.Invoke($null, $null)

        $err = GetField '_lastError'
        Check 'missing dictionary is reported' ($err -like 'DICT_MISSING*') "_lastError is [$err]"

        # Reporting it must not disable the hot reload that lets a user drop it in later.
        [IO.File]::WriteAllText($absent, "Delta=DDD`r`n", $utf8)
        $fresh.Invoke($null, $null)
        $v = $tr.Invoke($null, @('Delta'))
        Check 'dictionary added later still loads' ($v -eq 'DDD') "Translate(Delta) returned [$v]"
    }
    finally
    {
        Remove-Item -LiteralPath $absent -ErrorAction SilentlyContinue
        SetField '_dictPath' $tmp
    }

    # ---- every Run of one paragraph must be translated in a single pass ----
    [IO.File]::WriteAllText($tmp, "Alpha=AAA`r`n", $utf8)
    SetField '_dictStamp' ([datetime]::MinValue)
    $fresh.Invoke($null, $null)

    $ok = $type.GetMethod('EnsureReflection', $f).Invoke($null, $null)
    Check 'WPF members resolve' ($ok -eq $true) 'EnsureReflection returned false'

    $panel = New-Object System.Windows.Controls.StackPanel
    $block = New-Object System.Windows.Controls.TextBlock
    $runs  = New-Object System.Collections.ArrayList
    foreach ($i in 1..6)
    {
        $run = New-Object System.Windows.Documents.Run 'Alpha '
        [void]$block.Inlines.Add($run)
        [void]$runs.Add($run)
    }
    [void]$panel.Children.Add($block)

    # PowerShell wraps New-Object results in a PSObject, and the 'object node'
    # parameter would receive the wrapper instead of the element.
    $visited = [System.Collections.Generic.HashSet[object]]::new()
    $type.GetMethod('Walk', $f).Invoke($null, @($panel.PSObject.BaseObject, $visited, 0))
    $done = @($runs | Where-Object { $_.Text -eq 'AAA ' }).Count
    Check 'all inline runs translated in one pass' ($done -eq 6) "translated $done of 6"

    # ToolTipService is reached through its own accessors. A style setter leaves
    # no local value on the element, so only TranslateToolTip can find it.
    $tipped = New-Object System.Windows.Controls.TextBlock
    $setter = New-Object System.Windows.Setter
    $setter.Property = [System.Windows.Controls.ToolTipService]::ToolTipProperty
    $setter.Value = 'Alpha'
    $style = New-Object System.Windows.Style -ArgumentList ([System.Windows.Controls.TextBlock])
    [void]$style.Setters.Add($setter)
    $tipped.Style = $style
    $visitedTip = [System.Collections.Generic.HashSet[object]]::new()
    $type.GetMethod('Walk', $f).Invoke($null, @($tipped.PSObject.BaseObject, $visitedTip, 0))
    $tip = [System.Windows.Controls.ToolTipService]::GetToolTip($tipped)
    Check 'style tooltip is translated' ($tip -eq 'AAA') "tooltip is [$tip]"

    # ---- behaviour the optimisation must not change ----
    $cjk = [string] [char] 0x4E2D
    [IO.File]::WriteAllText($tmp, "Alpha=AAA`r`nLine1\nLine2=ONE-TWO`r`n$cjk=SHOULD-NOT-APPEAR`r`n", $utf8)
    SetField '_dictStamp' ([datetime]::MinValue)
    $fresh.Invoke($null, $null)

    $v = $tr.Invoke($null, @("Line1`r`nLine2"))
    Check 'CRLF in the UI matches a \n key' ($v -eq 'ONE-TWO') "Translate(CRLF) returned [$v]"

    $cjkBlock = New-Object System.Windows.Controls.TextBlock
    $cjkBlock.Text = $cjk
    $type.GetMethod('Walk', $f).Invoke($null, @($cjkBlock.PSObject.BaseObject, [System.Collections.Generic.HashSet[object]]::new(), 0))
    Check 'already translated text is left alone' ($cjkBlock.Text -eq $cjk) "text became [$($cjkBlock.Text)]"

    $named = New-Object System.Windows.Controls.TextBlock
    $named.Name = 'Alpha'
    $named.Text = 'Alpha'
    $type.GetMethod('Walk', $f).Invoke($null, @($named.PSObject.BaseObject, [System.Collections.Generic.HashSet[object]]::new(), 0))
    Check 'control Name is not translated' ($named.Name -eq 'Alpha') "Name became [$($named.Name)]"
    Check 'control Text is still translated' ($named.Text -eq 'AAA') "Text is [$($named.Text)]"

    # Content of an unrendered ContentControl is reachable only through the
    # logical tree, which the optimisation may skip for text elements only.
    $shell = New-Object System.Windows.Controls.ContentControl
    $inner = New-Object System.Windows.Controls.TextBlock
    $inner.Text = 'Alpha'
    $shell.Content = $inner.PSObject.BaseObject
    $type.GetMethod('Walk', $f).Invoke($null, @($shell.PSObject.BaseObject, [System.Collections.Generic.HashSet[object]]::new(), 0))
    Check 'logical-only content is translated' ($inner.Text -eq 'AAA') "text is [$($inner.Text)]"

    # ---- escaping must round-trip for every line of the real dictionary ----
    $un = $type.GetMethod('Unescape', $f)
    $es = $type.GetMethod('Escape', $f)
    $bad = New-Object System.Collections.ArrayList
    foreach ($line in [IO.File]::ReadAllLines($dict, $utf8))
    {
        if ($line.Length -eq 0 -or $line[0] -eq '#' -or $line[0] -eq ';') { continue }
        $eq = $line.IndexOf('=')
        if ($eq -le 0) { continue }
        foreach ($part in @($line.Substring(0, $eq), $line.Substring($eq + 1)))
        {
            $back = $es.Invoke($null, @($un.Invoke($null, @($part))))
            if ($back -ne $part) { [void]$bad.Add($part) }
        }
    }
    Check 'dictionary escape round-trip' ($bad.Count -eq 0) "$($bad.Count) line(s) do not round-trip"

    # ---- the release zip must be a complete, extract-and-run install ----
    # The DLL reads its dictionary from <appbase>\NVC_CHS, so the zip has to carry
    # that subdir. A dictionary at the zip root still leaves the install untranslated.
    $pack = Join-Path $repo 'package.ps1'
    if (-not (Test-Path -LiteralPath $pack)) { throw "package.ps1 not found: $pack" }
    $zip = Join-Path $env:TEMP ('nvcchs-pack-' + [guid]::NewGuid().ToString('N') + '.zip')
    try
    {
        $packOut = & $pack -OutputPath $zip 2>&1
        if (-not (Test-Path -LiteralPath $zip)) { throw "package.ps1 produced no zip: $packOut" }

        # CI and maintainers repackage over an existing zip; a fresh temp path per run
        # would hide a failure to overwrite.
        $repackOk = $true
        try { & $pack -OutputPath $zip 2>&1 | Out-Null } catch { $repackOk = $false }
        Check 'packaging overwrites an existing zip' $repackOk 'second run threw'

        $archive = [IO.Compression.ZipFile]::OpenRead($zip)
        try
        {
            $raw = @($archive.Entries | ForEach-Object { $_.FullName })
            # The ZIP spec requires forward slashes. Compress-Archive on PowerShell 5.1
            # writes backslashes, which some extractors turn into a literal filename
            # instead of the NVC_CHS subdir -- the dictionary then never gets found.
            $badSep = @($raw | Where-Object { $_.Contains('\') })
            Check 'release zip entry paths use forward slashes' ($badSep.Count -eq 0) "backslash entries: $($badSep -join ', ')"

            $entries = @($raw | ForEach-Object { $_.Replace('\', '/') })
            foreach ($required in @('NvcChs.dll', 'NVCleanstall.exe.config', 'NVC_CHS/zh-CN.txt'))
            {
                Check "release zip contains $required" ($entries -contains $required) "entries: $($entries -join ', ')"
            }
        }
        finally { $archive.Dispose() }
    }
    finally { Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue }
}
finally
{
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}

''
if ($script:failed -gt 0) { "FAILED: $script:failed check(s)"; exit 1 }
'ALL CHECKS PASSED'
exit 0
