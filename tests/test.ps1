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

    # ---- a dictionary beside the exe wins; the data subdir is the fallback ----
    $probeBase = Join-Path $env:TEMP ('nvcchs-base-' + [guid]::NewGuid().ToString('N'))
    $probeSub  = Join-Path $probeBase 'NVC_CHS'
    try
    {
        [void][IO.Directory]::CreateDirectory($probeSub)
        [IO.File]::WriteAllText((Join-Path $probeSub 'zh-CN.txt'), "Echo=SUB`r`n", $utf8)
        SetField '_baseDir' $probeBase
        SetField '_dictPath' $null
        SetField '_dictStamp' ([datetime]::MinValue)
        $fresh.Invoke($null, $null)
        $v = $tr.Invoke($null, @('Echo'))
        Check 'subdir dictionary used when nothing is beside the exe' ($v -eq 'SUB') "Translate(Echo) returned [$v]"

        $beside = Join-Path $probeBase 'zh-CN.txt'
        [IO.File]::WriteAllText($beside, "Echo=ROOT`r`n", $utf8)
        $fresh.Invoke($null, $null)
        $v = $tr.Invoke($null, @('Echo'))
        Check 'dictionary beside the exe wins' ($v -eq 'ROOT') "Translate(Echo) returned [$v]"
        Check 'dictionaryPath reports the file actually read' ((GetField '_dictPath') -eq $beside) "_dictPath is [$(GetField '_dictPath')]"

        Remove-Item -LiteralPath $beside -Force
        $fresh.Invoke($null, $null)
        $v = $tr.Invoke($null, @('Echo'))
        Check 'removing the root dictionary falls back to the subdir' ($v -eq 'SUB') "Translate(Echo) returned [$v]"
    }
    finally
    {
        SetField '_baseDir' $null
        SetField '_dictPath' $tmp
        SetField '_dictStamp' ([datetime]::MinValue)
        Remove-Item -LiteralPath $probeBase -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ---- a healthy run leaves no files; only a failure may create the data subdir ----
    $quietRoot = Join-Path $env:TEMP ('nvcchs-quiet-' + [guid]::NewGuid().ToString('N'))
    $quietDir  = Join-Path $quietRoot 'NVC_CHS'
    try
    {
        $diagOn = [bool](GetField 'Diagnostics')
        # Create the folder in both modes. If it were missing, a write regression would
        # throw into Flush's catch and this test would pass anyway.
        [void][IO.Directory]::CreateDirectory($quietDir)
        SetField '_dir' $quietDir
        $type.GetMethod('Flush', $f).Invoke($null, $null)

        $files = @(Get-ChildItem -LiteralPath $quietDir -Force | ForEach-Object { $_.Name })
        if ($diagOn)
        {
            Check 'diagnostics build writes status.txt' ($files -contains 'status.txt') "files: $($files -join ', ')"
        }
        else
        {
            Check 'release build writes no files' ($files.Count -eq 0) "wrote: $($files -join ', ')"
        }

        # A failure is the one case allowed to leave a trace, in either mode.
        $type.GetField('RecordedOnce', $f).GetValue($null).Clear()
        $type.GetMethod('RecordOnce', $f).Invoke($null, @('TEST_FAILURE'))
        $log = Join-Path $quietDir 'error.log'
        $text = if (Test-Path -LiteralPath $log) { Get-Content -LiteralPath $log -Raw } else { '' }
        Check 'a failure writes error.log' ($text -match 'TEST_FAILURE') "error.log is [$text]"
    }
    finally
    {
        SetField '_dir' $null
        Remove-Item -LiteralPath $quietRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ---- startup cleanup drops stale dumps but keeps the dictionary ----
    $cleanRoot = Join-Path $env:TEMP ('nvcchs-clean-' + [guid]::NewGuid().ToString('N'))
    $cleanDir  = Join-Path $cleanRoot 'NVC_CHS'
    try
    {
        [void][IO.Directory]::CreateDirectory($cleanDir)
        foreach ($n in @('error.log', 'status.txt', 'seen.txt', 'missing.txt'))
        {
            [IO.File]::WriteAllText((Join-Path $cleanDir $n), 'stale')
        }
        SetField '_dir' $cleanDir
        $type.GetMethod('CleanDataDir', $f).Invoke($null, $null)

        $survivors = @('error.log', 'status.txt', 'seen.txt', 'missing.txt' |
            Where-Object { Test-Path -LiteralPath (Join-Path $cleanDir $_) })
        Check 'cleanup removes every dump' ($survivors.Count -eq 0) "survived: $($survivors -join ', ')"
        Check 'cleanup removes the emptied dir' (-not (Test-Path -LiteralPath $cleanDir)) 'dir still exists'

        # The dictionary is user data; a cleanup must never take it.
        [void][IO.Directory]::CreateDirectory($cleanDir)
        [IO.File]::WriteAllText((Join-Path $cleanDir 'zh-CN.txt'), "A=B`r`n", $utf8)
        [IO.File]::WriteAllText((Join-Path $cleanDir 'status.txt'), 'stale')
        SetField '_dir' $cleanDir
        $type.GetMethod('CleanDataDir', $f).Invoke($null, $null)
        Check 'cleanup keeps the dictionary' (Test-Path -LiteralPath (Join-Path $cleanDir 'zh-CN.txt')) 'zh-CN.txt was deleted'
        Check 'cleanup removes the dump beside it' (-not (Test-Path -LiteralPath (Join-Path $cleanDir 'status.txt'))) 'status.txt survived'
    }
    finally
    {
        SetField '_dir' $null
        Remove-Item -LiteralPath $cleanRoot -Recurse -Force -ErrorAction SilentlyContinue
    }

    # ---- every Run of one paragraph must be translated in a single pass ----
    [IO.File]::WriteAllText($tmp, "Alpha=AAA`r`nLink=LNK`r`n", $utf8)
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

    # A hyperlink lives in the InlineCollection, not the visual tree. Translating
    # the paragraph must not drop it (the app's "let us know" footer).
    $para = New-Object System.Windows.Controls.TextBlock
    $paraRun = New-Object System.Windows.Documents.Run 'Alpha '
    $link = New-Object System.Windows.Documents.Hyperlink
    $linkRun = New-Object System.Windows.Documents.Run 'Link'
    [void]$link.Inlines.Add($linkRun)
    [void]$para.Inlines.Add($paraRun)
    [void]$para.Inlines.Add($link)
    $type.GetMethod('Walk', $f).Invoke($null, @($para.PSObject.BaseObject, [System.Collections.Generic.HashSet[object]]::new(), 0))
    Check 'hyperlink survives translation' ($para.Inlines.Count -eq 2) "inlines: $($para.Inlines.Count)"
    Check 'run before a hyperlink is translated' ($paraRun.Text -eq 'AAA ') "text is [$($paraRun.Text)]"
    Check 'run inside a hyperlink is translated' ($linkRun.Text -eq 'LNK') "text is [$($linkRun.Text)]"

    # Only content-bearing inlines force the run-by-run path; plain runs keep the
    # smoother whole-paragraph Text translation (the components descriptions).
    $hasEmbedded = $type.GetMethod('HasEmbeddedInline', $f)
    Check 'hyperlink is an embedded inline' ([bool]$hasEmbedded.Invoke($null, @($para.PSObject.BaseObject, 0)))
    $plainRoot = New-Object System.Windows.Controls.TextBlock
    [void]$plainRoot.Inlines.Add((New-Object System.Windows.Documents.Run 'Alpha'))
    [void]$plainRoot.Inlines.Add((New-Object System.Windows.Documents.Run 'Link'))
    Check 'plain runs are not embedded' (-not [bool]$hasEmbedded.Invoke($null, @($plainRoot.PSObject.BaseObject, 0)))
    [void]$plainRoot.Inlines.Add((New-Object System.Windows.Documents.LineBreak))
    Check 'line break does not block the Text rewrite' (-not [bool]$hasEmbedded.Invoke($null, @($plainRoot.PSObject.BaseObject, 0)))

    $spanRoot = New-Object System.Windows.Controls.TextBlock
    $span = New-Object System.Windows.Documents.Span
    $spanLink = New-Object System.Windows.Documents.Hyperlink
    [void]$spanLink.Inlines.Add((New-Object System.Windows.Documents.Run 'Link'))
    [void]$span.Inlines.Add($spanLink)
    [void]$spanRoot.Inlines.Add($span)
    Check 'nested hyperlink is an embedded inline' ([bool]$hasEmbedded.Invoke($null, @($spanRoot.PSObject.BaseObject, 0)))

    # TextBlock.Text and Inlines coexist here; rewriting Text rebuilds the
    # InlineCollection, so the property must be left alone for such elements.
    $mixed = New-Object System.Windows.Controls.TextBlock
    $mixed.Text = 'Alpha'
    $mixedLink = New-Object System.Windows.Documents.Hyperlink
    $mixedLinkRun = New-Object System.Windows.Documents.Run 'Link'
    [void]$mixedLink.Inlines.Add($mixedLinkRun)
    [void]$mixed.Inlines.Add($mixedLink)
    $type.GetMethod('Walk', $f).Invoke($null, @($mixed.PSObject.BaseObject, [System.Collections.Generic.HashSet[object]]::new(), 0))
    Check 'inline hyperlink survives a Text value' ($mixed.Inlines.Count -eq 2) "inlines: $($mixed.Inlines.Count)"
    # TextBlock.Text keeps returning the Text DP value once inlines exist, so the
    # rendered text is asserted through the runs instead.
    $mixedRun = @($mixed.Inlines)[0]
    Check 'text beside an inline hyperlink is translated' ($mixedRun.Text -eq 'AAA') "run text is [$($mixedRun.Text)]"

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

    # A translation can be all-ASCII plus full-width punctuation ("ID："); it must
    # count as localised or every scan would list it as missing.
    $contains = $type.GetMethod('ContainsCjk', $f)
    $fullWidth = 'ID' + [string] [char] 0xFF1A
    Check 'full-width punctuation counts as localised' ([bool]$contains.Invoke($null, @($fullWidth)))
    Check 'ascii text is not localised' (-not [bool]$contains.Invoke($null, @('ID:')))

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

    # ---- shipped dictionary sanity ----
    # The loader is last-wins: a duplicated key silently overrides an earlier
    # translation. (An empty value is legitimate: "The" is dropped as an article.)
    $dictKeys = New-Object System.Collections.Generic.HashSet[string] ([System.StringComparer]::Ordinal)
    $dups = New-Object System.Collections.Generic.List[string]
    foreach ($line in [IO.File]::ReadAllLines($dict, $utf8))
    {
        if (-not $line -or $line[0] -eq '#' -or $line[0] -eq ';') { continue }
        $eq = $line.IndexOf('=')
        if ($eq -le 0) { continue }
        $k = $line.Substring(0, $eq)
        if (-not $dictKeys.Add($k)) { $dups.Add($k) }
    }
    Check 'shipped dictionary has no duplicate keys' ($dups.Count -eq 0) ("duplicates: " + ($dups -join ', '))

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
            foreach ($required in @('NvcChs.dll', 'NVCleanstall.exe.config', 'install.cmd', 'zh-CN.txt'))
            {
                Check "release zip contains $required" ($entries -contains $required) "entries: $($entries -join ', ')"
            }
        }
        finally { $archive.Dispose() }
    }
    finally { Remove-Item -LiteralPath $zip -ErrorAction SilentlyContinue }

    # ---- install.cmd gives a renamed portable exe its own config ----
    # The CLR only honours <exe filename>.config, so this is the step that makes
    # NVCleanstall_1.19.0.exe load the patch at all.
    $cmdScript   = Join-Path $repo 'install.cmd'
    $cmdTemplate = Join-Path $repo 'NVCleanstall.exe.config'
    if (-not (Test-Path -LiteralPath $cmdScript)) { throw "install.cmd not found: $cmdScript" }
    $cmdDir = Join-Path $env:TEMP ('nvcchs-cmd-' + [guid]::NewGuid().ToString('N'))
    try
    {
        [void][IO.Directory]::CreateDirectory($cmdDir)
        Copy-Item -LiteralPath $cmdScript -Destination $cmdDir
        Copy-Item -LiteralPath $cmdTemplate -Destination $cmdDir
        Copy-Item -LiteralPath $dll -Destination $cmdDir
        # Only the file name matters to the script, so an empty stand-in is enough.
        $dummy   = Join-Path $cmdDir 'NVCleanstall_9.9.9.exe'
        $renamed = $dummy + '.config'
        # A freshly created .exe in %TEMP% can be held by the antivirus scanner for a moment.
        foreach ($attempt in 1..5)
        {
            try { [IO.File]::WriteAllText($dummy, ''); break }
            catch { Start-Sleep -Milliseconds 100 }
        }
        if (-not (Test-Path -LiteralPath $dummy)) { throw "Could not create $dummy" }

        $out = & cmd /c "`"$cmdDir\install.cmd`" -nopause" 2>&1
        Check 'install.cmd creates the renamed exe config' (Test-Path -LiteralPath $renamed) "output: $out"
        Check 'install.cmd exits 0 on success' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"
        Check 'generated config is the shipped template' ((Get-Content -LiteralPath $renamed -Raw) -eq (Get-Content -LiteralPath $cmdTemplate -Raw)) 'contents differ'

        # A config that names the patch without the DLL stops the host from starting,
        # so the script must refuse instead of writing one.
        Remove-Item -LiteralPath (Join-Path $cmdDir 'NvcChs.dll') -Force
        Remove-Item -LiteralPath $renamed -Force
        $out = & cmd /c "`"$cmdDir\install.cmd`" -nopause" 2>&1
        Check 'install.cmd refuses without NvcChs.dll' ($LASTEXITCODE -ne 0) "exit $LASTEXITCODE"
        Check 'install.cmd writes no config without the dll' (-not (Test-Path -LiteralPath $renamed)) "created $renamed"
        Copy-Item -LiteralPath $dll -Destination $cmdDir

        # A config that is not ours must survive untouched.
        Remove-Item -LiteralPath $renamed -Force -ErrorAction SilentlyContinue
        [IO.File]::WriteAllText($renamed, '<configuration><appSettings/></configuration>')
        $out = & cmd /c "`"$cmdDir\install.cmd`" -nopause" 2>&1
        $kept = (Get-Content -LiteralPath $renamed -Raw) -match 'appSettings'
        Check 'install.cmd leaves an unrelated config alone' $kept "output: $out"
        Check 'install.cmd still exits 0 when skipping' ($LASTEXITCODE -eq 0) "exit $LASTEXITCODE"

        # Finding no exe is an error, not a silent no-op.
        Remove-Item -LiteralPath $dummy -Force
        $out = & cmd /c "`"$cmdDir\install.cmd`" -nopause" 2>&1
        Check 'install.cmd fails when no exe is present' ($LASTEXITCODE -ne 0) "exit $LASTEXITCODE"
    }
    finally { Remove-Item -LiteralPath $cmdDir -Recurse -Force -ErrorAction SilentlyContinue }
}
finally
{
    Remove-Item -LiteralPath $tmp -ErrorAction SilentlyContinue
}

''
if ($script:failed -gt 0) { "FAILED: $script:failed check(s)"; exit 1 }
'ALL CHECKS PASSED'
exit 0
