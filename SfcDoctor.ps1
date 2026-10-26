<# =====================================================================
  SfcDoctor v1.0.0
  Fixes: sfc /scannow reporting - Windows Resource Protection found
  corrupt files but was unable to fix some of them. WITHOUT REBOOTING.

  Pipeline: parse CBS.log - sfc scan - DISM RestoreHealth - live manual
  file replacement (backup + ACL-aware, in-use safe via rename-aside)
  - re-verify with sfc. Live replacements never schedule a reboot.

  Modes:
    -Status       last SFC verdict + reboot-pending info (read-only)
    -CheckOnly    report verdict of newest SFC run in CBS.log (read-only)
    -Repair       full detect-and-repair loop (asks for confirmation)
    -SelfTest     parse gate + fixture tests + live temp-file repair test
    -MakeFixtures write sample CBS logs to tests\fixtures

  Requires: elevated Windows PowerShell 5.1 console.
  License: MIT (see LICENSE file).
 ===================================================================== #>
#requires -RunAsAdministrator
[CmdletBinding()]
param(
    [switch]$Status,
    [switch]$CheckOnly,
    [switch]$Repair,
    [switch]$SelfTest,
    [switch]$MakeFixtures,
    [int]$MaxPasses = 3,
    [string]$SourcePath = '',
    [switch]$SkipDism,
    [switch]$Yes,
    [string]$LogPath = 'C:\Windows\Logs\CBS\CBS.log',
    [string]$WinSxSRoot = 'C:\Windows\WinSxS',
    [string]$WorkRoot = 'C:\Temp\sfcdoctor'
)

$ErrorActionPreference = 'Stop'
$DQ = [char]34

$script:Results = [ordered]@{
    tool = 'SfcDoctor'; version = '1.1.0'
    started = (Get-Date -Format s); passes = @(); repairs = @()
    finalVerdict = $null; runDir = ''
}
$script:Backups = New-Object System.Collections.Generic.List[string]

function Write-Section { param([string]$Text) Write-Host ''; Write-Host ('=== ' + $Text + ' ===') -ForegroundColor Cyan }
function Write-Ok    { param([string]$Text) Write-Host ('  [OK]   ' + $Text) -ForegroundColor Green }
function Write-Bad   { param([string]$Text) Write-Host ('  [FAIL] ' + $Text) -ForegroundColor Red }
function Write-Inf   { param([string]$Text) Write-Host ('  [i]    ' + $Text) -ForegroundColor Gray }

function Get-CbsSrLines {
    param([string]$Path, [int64]$SkipBytes = 0)
    $list = New-Object System.Collections.Generic.List[string]
    $fs = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
    try {
        $sr = New-Object System.IO.StreamReader($fs)
        try {
            if ($SkipBytes -gt 0) {
                $null = $fs.Seek($SkipBytes, [System.IO.SeekOrigin]::Begin)
                $sr.DiscardBufferedData()
            }
            while ($null -ne ($line = $sr.ReadLine())) {
                if ($line.Contains('[SR]') -or $line.Contains('DEPLOY [Pnp]')) { $list.Add($line) }
            }
        } finally { $sr.Dispose() }
    } finally { $fs.Dispose() }
    return $list
}

function Split-SfcRuns {
    param($Lines)
    $runs = @()
    $cur = @()
    foreach ($line in $Lines) {
        $cur = @($cur) + $line
        if ($line -match '\[SR\] Repair complete') {
            $runs = @($runs) + ,([pscustomobject]@{ Lines = $cur })
            $cur = @()
        }
    }
    if ((@($cur).Count -gt 0) -and (@($runs).Count -gt 0)) {
        $lastIdx = @($runs).Count - 1
        $runs[$lastIdx].Lines = @($runs[$lastIdx].Lines) + @($cur)
    }
    return $runs
}

function Get-SfcVerdict {
    param($RunLines)
    $v = [pscustomobject]@{ Verdict = 'Unknown'; RepairedCount = 0; Unfixable = @(); PnpOnly = $false }
    if (-not $RunLines) { $v.Verdict = 'NoRun'; return $v }
    $runLines = @($RunLines)
    if ($runLines.Count -eq 0) { $v.Verdict = 'NoRun'; return $v }
    $complete = @($runLines | Where-Object { $_ -match '\[SR\] Repair complete' })
    if ($complete.Count -eq 0) { $v.Verdict = 'IncompleteRun'; return $v }

    $sq = [char]39
    $reCannotModern = 'Cannot repair member file \[l:\d+\]' + $sq + '([^' + $sq + ']+)' + $sq + ' of ([^,]+), version ([\d\.]+), arch (\w+)'
    $reCannotLegacy = 'Cannot repair member file \[l:\d+\{\d+}\]' + $DQ + '([^' + $DQ + ']+)' + $DQ + ' of ' + $DQ + '([^' + $DQ + ']+)' + $DQ
    $reProjModern = 'Could not reproject corrupted file \\+\?\?\\([^;]+)'
    $reProjLegacy = 'Could not reproject file \[ml:\d+\{\d+}\]' + $DQ + '\\\?\?\\([^' + $DQ + ']+)' + $DQ

    $projects = @{}
    foreach ($line in $runLines) {
        if ($line -match '\[SR\] Could not reproject') {
            $projPath = $null
            if ($line -match $reProjModern) { $projPath = ($Matches[1].Replace('\\', '\')).Trim() }
            elseif ($line -match $reProjLegacy) { $projPath = $Matches[1].Trim() }
            if ($projPath) {
                $leaf = Split-Path -Leaf $projPath
                if (-not $projects.ContainsKey($leaf)) { $projects[$leaf] = $projPath }
            }
        }
    }

    $unfix = @()
    foreach ($line in $runLines) {
        if ($line -match '\[SR\] Cannot repair member file') {
            $file = ''; $comp = ''
            if ($line -match $reCannotModern) {
                $file = $Matches[1]
                $comp = $Matches[4] + '_' + ($Matches[2].Trim().ToLower()).Replace(' ', '')
            } elseif ($line -match $reCannotLegacy) {
                $file = $Matches[1]; $comp = $Matches[2]
            }
            $tp = $null
            if ($file -and $projects.ContainsKey($file)) { $tp = $projects[$file] }
            $unfix += [pscustomobject]@{ File = $file; Component = $comp; TargetPath = $tp; Line = $line }
        }
    }

    $repN = 0
    foreach ($line in $runLines) {
        if ($line -match '\[SR\] Repairing (\d+) components') { $repN = [int]$Matches[1] }
    }

    if ($unfix.Count -gt 0) { $v.Verdict = 'Unfixable' }
    elseif ($repN -gt 0) { $v.Verdict = 'RepairedAll'; $v.RepairedCount = $repN }
    else { $v.Verdict = 'Clean' }
    $pnpFail = @{}
    foreach ($line in $runLines) {
        if ($line -match 'Failed repairing file: (.+?): \d+$') { $pnpFail[$Matches[1]] = $true }
    }
    foreach ($path in @($pnpFail.Keys)) {
        $unfix += [pscustomobject]@{ File = (Split-Path -Leaf $path); Component = 'PnP/driver-store (SFP)'; TargetPath = $path; Line = 'SFP/DEPLOY flagged' }
    }
    $unfix = @($unfix | Group-Object -Property File, Component | ForEach-Object { $_.Group[0] })
    $v.PnpOnly = ((@($unfix).Count -gt 0) -and (@(@($unfix) | Where-Object { $_.Component -notlike 'PnP*' }).Count -eq 0))
    $v.Unfixable = $unfix
    if (@($v.Unfixable).Count -gt 0) { $v.Verdict = 'Unfixable' }
    return $v
}

function Resolve-TargetPath {
    param($UnfixItem)
    if ($UnfixItem.TargetPath -and (Test-Path -LiteralPath $UnfixItem.TargetPath)) { return $UnfixItem.TargetPath }
    $name = $UnfixItem.File
    if (-not $name) { return $null }
    $roots = @('C:\Windows\System32', 'C:\Windows\SysWOW64', 'C:\Windows\System32\drivers', 'C:\Windows\System', 'C:\Windows\System32\en-US', 'C:\Windows\SysWOW64\en-US', 'C:\Windows\Branding', 'C:\Windows\Web\Wallpaper\Windows', 'C:\Windows')
    if ($UnfixItem.Component -like 'wow64_*' -or $UnfixItem.Component -like 'x86_*') {
        $roots = @('C:\Windows\SysWOW64', 'C:\Windows\System32', 'C:\Windows\System')
    }
    foreach ($r in $roots) {
        $p = Join-Path $r $name
        if (Test-Path -LiteralPath $p) { return $p }
    }
    return $null
}

function Invoke-SfcScan {
    Write-Inf 'Running sfc /scannow (this can take 5-15 minutes) ...'
    $fs = Get-Item -LiteralPath $LogPath
    $base = $fs.Length
    $scanStart = Get-Date
    $null = Start-Process -FilePath 'sfc.exe' -ArgumentList '/scannow' -WindowStyle Hidden -PassThru -Wait
    $after = Get-Item -LiteralPath $LogPath
    $skip = $base
    if ($after.CreationTime -gt $scanStart) { $skip = 0 }
    $lines = $null
    $runs = $null
    $deadline = (Get-Date).AddSeconds(30)
    do {
        $lines = Get-CbsSrLines -Path $LogPath -SkipBytes $skip
        $runs = Split-SfcRuns -Lines $lines
        if (@($runs).Count -gt 0) { break }
        Start-Sleep -Seconds 2
    } while ((Get-Date) -lt $deadline)
    if (@($runs).Count -eq 0) { return (Get-SfcVerdict -RunLines @()) }
    $lastRun = $runs[@($runs).Count - 1]
    return (Get-SfcVerdict -RunLines $lastRun.Lines)
}

function Invoke-DismRestoreHealth {
    Write-Inf 'Running DISM /Online /Cleanup-Image /RestoreHealth /NoRestart (10-30 min) ...'
    $p = Start-Process -FilePath 'dism.exe' -ArgumentList '/Online','/Cleanup-Image','/RestoreHealth','/NoRestart' -WindowStyle Hidden -PassThru -Wait
    $code = $p.ExitCode
    Write-Inf ('DISM exit code: ' + $code)
    return (($code -eq 0) -or ($code -eq 3010))
}

function Get-WinSxsSources {
    param([string]$FileName, [string]$ComponentHint)
    $found = New-Object System.Collections.Generic.List[string]
    if ($ComponentHint) {
        try {
            $dirs = Get-ChildItem -LiteralPath $WinSxSRoot -Directory -ErrorAction SilentlyContinue |
                Where-Object { $_.Name -like ('*' + $ComponentHint + '*') }
            foreach ($d in $dirs) {
                $p = Join-Path $d.FullName $FileName
                if (Test-Path -LiteralPath $p) { $found.Add($p) }
            }
        } catch { }
    }
    if ($found.Count -eq 0 -and $FileName) {
        try {
            $raw = & where.exe /r $WinSxSRoot $FileName 2>$null
            foreach ($r in @($raw)) { if ($r) { $found.Add([string]$r) } }
        } catch { }
    }
    return $found
}

function Get-SourceForTarget {
    param($UnfixItem, [string]$Target)
    if ($SourcePath) {
        if (Test-Path -LiteralPath $SourcePath -PathType Container) {
            $cand = Join-Path $SourcePath $UnfixItem.File
            if (Test-Path -LiteralPath $cand) { return $cand }
        } elseif (Test-Path -LiteralPath $SourcePath) { return $SourcePath }
        return $null
    }
    $targetHash = ''
    try { $targetHash = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash } catch { }
    $sources = Get-WinSxsSources -FileName $UnfixItem.File -ComponentHint $UnfixItem.Component
    foreach ($s in $sources) {
        if ($s -eq $Target) { continue }
        if ($s -like ('*' + $WinSxSRoot + '\Temp\*')) { continue }
        if ($targetHash) {
            try {
                $h = (Get-FileHash -LiteralPath $s -Algorithm SHA256).Hash
                if ($h -eq $targetHash) { continue }
            } catch { continue }
        }
        return $s
    }
    return $null
}

function Repair-ProjectedFileNoReboot {
    param([string]$Target, [string]$Source)
    $res = [pscustomobject]@{ Target = $Target; Source = $Source; Replaced = $false; Method = ''; Backup = ''; AclRestored = $false; Error = '' }
    try {
        if (-not (Test-Path -LiteralPath $Source)) { throw ('source not found: ' + $Source) }
        $srcHash = (Get-FileHash -LiteralPath $Source -Algorithm SHA256).Hash
        if (Test-Path -LiteralPath $Target) {
            $curHash = (Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash
            if ($curHash -eq $srcHash) {
                $res.Replaced = $true; $res.Method = 'already healthy (hash match)'
                return $res
            }
        }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $bak = $Target + '.sfcdoctor-bak-' + $stamp
        $origOwner = ''
        $sddl = ''
        try {
            $origAcl = Get-Acl -LiteralPath $Target
            $origOwner = $origAcl.Owner
            $sddl = $origAcl.Sddl
        } catch { }
        $null = & takeown.exe /f $Target /a
        $null = & icacls.exe $Target /grant '*S-1-5-32-544:F'
        Copy-Item -LiteralPath $Target -Destination $bak -Force
        $res.Backup = $bak
        $script:Backups.Add($bak)
        $direct = $true
        try { Copy-Item -LiteralPath $Source -Destination $Target -Force -ErrorAction Stop }
        catch { $direct = $false }
        if (-not $direct) {
            Move-Item -LiteralPath $Target -Destination ($bak + '.inuse') -Force
            Copy-Item -LiteralPath $Source -Destination $Target -Force
            $res.Method = 'rename-aside + copy (in-use file replaced live, no reboot)'
        } else {
            $res.Method = 'direct copy (no reboot)'
        }
        try {
            if ($sddl) {
                $sd = New-Object System.Security.AccessControl.FileSecurity
                $sd.SetSecurityDescriptorSddlForm($sddl)
                Set-Acl -LiteralPath $Target -AclObject $sd
            } else {
                $null = & icacls.exe $Target /reset
            }
            $res.AclRestored = $true
        } catch { $res.AclRestored = $false }
        if ($origOwner) { try { $null = & icacls.exe $Target /setowner $origOwner } catch { } }
        $res.Replaced = ((Get-FileHash -LiteralPath $Target -Algorithm SHA256).Hash -eq $srcHash)
    } catch { $res.Error = $_.Exception.Message }
    return $res
}

function Test-RebootPending {
    $o = [pscustomobject]@{ CbsRebootPending = $false; WuRebootRequired = $false; PendingRenameCount = 0 }
    try { if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $o.CbsRebootPending = $true } } catch { }
    try { if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $o.WuRebootRequired = $true } } catch { }
    try {
        $pfro = (Get-ItemProperty -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -Name PendingFileRenameOperations -ErrorAction SilentlyContinue).PendingFileRenameOperations
        if ($pfro) { $o.PendingRenameCount = @($pfro).Count }
    } catch { }
    return $o
}

function New-FixtureLines {
    param([string]$Kind)
    $t = '2026-10-26 12:00:00, Info                  CSI    00000001 '
    $clean = @(
        ($t + '[SR] Verifying 100 components'),
        ($t + '[SR] Verify complete'),
        ($t + '[SR] Repairing 0 components'),
        ($t + '[SR] Beginning Verify and Repair Transaction'),
        ($t + '[SR] Repair complete')
    )
    $repaired = @(
        ($t + '[SR] Verifying 100 components'),
        ($t + '[SR] Verify complete'),
        ($t + '[SR] Repairing 2 components'),
        ($t + '[SR] Beginning Verify and Repair Transaction'),
        ($t + '[SR] Repair complete')
    )
    $sq = [char]39
    $unfixable = @(
        ($t + '[SR] Verifying 100 components'),
        ($t + '[SR] Cannot repair member file [l:10]' + $sq + 'whoami.exe' + $sq + ' of Microsoft-Windows-WhoAmI, version 10.0.26100.1882, arch amd64, nonSxS, pkt {l:8 b:31bf3856ad364e35} in the store, hash mismatch'),
        ($t + '[SR] Could not reproject corrupted file \??\C:\Windows\System32\\whoami.exe; source file in store is also corrupted'),
        ($t + '[SR] Repairing 1 components'),
        ($t + '[SR] Beginning Verify and Repair Transaction'),
        ($t + '[SR] Repair complete')
    )
    $unfixableLegacy = @(
        ($t + '[SR] Verifying 100 components'),
        ($t + '[SR] Cannot repair member file [l:8{4}]' + $DQ + 'url.dll' + $DQ + ' of ' + $DQ + 'amd64_microsoft-windows-ie-internetexplorer_31bf3856ad364e35_11.0.26700.1_none_deadbeef' + $DQ),
        ($t + '[SR] Could not reproject file [ml:60{30}]' + $DQ + '\??\C:\Windows\System32\url.dll' + $DQ + '. Source: ' + $DQ + '\??\C:\Windows\WinSxS\amd64_microsoft-windows-i..inetexplorer_31bf3856ad364e35_11.0.1.1_none_abc\url.dll' + $DQ),
        ($t + '[SR] Repairing 1 components'),
        ($t + '[SR] Beginning Verify and Repair Transaction'),
        ($t + '[SR] Repair complete')
    )
    $pnpRun = @(
        ($t + '[SR] Verifying 100 components'),
        ($t + '[SR] Verify complete'),
        ($t + '[SR] Repairing 0 components'),
        ($t + '[SR] Beginning Verify and Repair Transaction'),
        ('2026-10-26 12:00:05, Error DEPLOY [Pnp] Corrupt file: C:\WINDOWS\System32\drivers\testdrv.sys'),
        ('2026-10-26 12:00:05, Error DEPLOY [Pnp] Failed repairing file: C:\WINDOWS\System32\drivers\testdrv.sys: 160'),
        ($t + '[SR] Repair complete')
    )
    if ($Kind -eq 'clean') { return $clean }
    if ($Kind -eq 'repaired') { return $repaired }
    if ($Kind -eq 'unfixable_legacy') { return $unfixableLegacy }
    if ($Kind -eq 'pnp') { return $pnpRun }
    return $unfixable
}

function Invoke-SelfTest {
    $script:PassCount = 0
    $script:FailCount = 0
    function T { param([string]$Name, $Cond) if ($Cond) { $script:PassCount++; Write-Ok $Name } else { $script:FailCount++; Write-Bad $Name } }

    Write-Section 'Self test: parse gate (Windows PowerShell 5.1)'
    $tokens = $null
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($PSCommandPath, [ref]$tokens, [ref]$errors)
    T ('file parses with 0 syntax errors (found: ' + @($errors).Count + ')') (@($errors).Count -eq 0)

    Write-Section 'Self test: verdict parsing from fixture CBS lines'
    $vc = Get-SfcVerdict -RunLines (New-FixtureLines -Kind clean)
    T 'clean fixture gives Clean' ($vc.Verdict -eq 'Clean')
    $vr = Get-SfcVerdict -RunLines (New-FixtureLines -Kind repaired)
    T 'repaired fixture gives RepairedAll with count 2' ($vr.Verdict -eq 'RepairedAll' -and $vr.RepairedCount -eq 2)
    $vu = Get-SfcVerdict -RunLines (New-FixtureLines -Kind unfixable)
    T 'unfixable fixture (modern format) gives Unfixable' ($vu.Verdict -eq 'Unfixable')
    T 'modern unfixable file extracted (whoami.exe)' ($vu.Unfixable.Count -eq 1 -and $vu.Unfixable[0].File -eq 'whoami.exe')
    T 'modern component derived (amd64_microsoft-windows-whoami)' ($vu.Unfixable[0].Component -eq 'amd64_microsoft-windows-whoami')
    T 'modern reproject target path extracted' ($vu.Unfixable[0].TargetPath -eq 'C:\Windows\System32\whoami.exe')
    $vl = Get-SfcVerdict -RunLines (New-FixtureLines -Kind unfixable_legacy)
    T 'unfixable fixture (legacy format) gives Unfixable' ($vl.Verdict -eq 'Unfixable')
    T 'legacy unfixable file extracted (url.dll)' ($vl.Unfixable.Count -eq 1 -and $vl.Unfixable[0].File -eq 'url.dll')
    T 'legacy component extracted' ($vl.Unfixable[0].Component -like 'amd64_microsoft-windows-ie*')
    T 'legacy reproject target path extracted' ($vl.Unfixable[0].TargetPath -eq 'C:\Windows\System32\url.dll')

    $vp = Get-SfcVerdict -RunLines (New-FixtureLines -Kind pnp)
    T 'pnp fixture gives Unfixable despite clean SR lines' ($vp.Verdict -eq 'Unfixable' -and $vp.PnpOnly -eq $true)
    T 'pnp target path extracted' (@($vp.Unfixable).Count -eq 1 -and $vp.Unfixable[0].TargetPath -eq 'C:\WINDOWS\System32\drivers\testdrv.sys')
    T 'incomplete run detected' ((Get-SfcVerdict -RunLines @('2026 x [SR] Verifying 100 components')).Verdict -eq 'IncompleteRun')
    T 'empty run gives NoRun' ((Get-SfcVerdict -RunLines @()).Verdict -eq 'NoRun')

    Write-Section 'Self test: target path resolution'
    $tp = Resolve-TargetPath -UnfixItem $vu.Unfixable[0]
    T 'whoami.exe resolves under System32' ($tp -eq 'C:\Windows\System32\whoami.exe')

    Write-Section 'Self test: run splitting'
    $two = New-Object System.Collections.Generic.List[string]
    foreach ($x in (New-FixtureLines -Kind clean)) { $two.Add($x) }
    foreach ($x in (New-FixtureLines -Kind unfixable)) { $two.Add($x) }
    $runs2 = Split-SfcRuns -Lines $two
    T 'two concatenated runs split into 2' ($runs2.Count -eq 2)

    Write-Section 'Self test: no-reboot repair mechanics on temp files'
    $troot = Join-Path $WorkRoot 'selftest'
    New-Item -ItemType Directory -Force -Path $troot | Out-Null
    $t1 = Join-Path $troot 'target.bin'
    $t2 = Join-Path $troot 'source.bin'
    Set-Content -LiteralPath $t1 -Value 'CORRUPT-PAYLOAD' -Encoding ASCII
    Set-Content -LiteralPath $t2 -Value 'HEALTHY-PAYLOAD' -Encoding ASCII
    $rr = Repair-ProjectedFileNoReboot -Target $t1 -Source $t2
    T 'temp target replaced live' ($rr.Replaced -eq $true)
    T 'backup created' ($rr.Backup -ne '' -and (Test-Path -LiteralPath $rr.Backup))
    T 'target content now equals source' ((Get-FileHash -LiteralPath $t1 -Algorithm SHA256).Hash -eq (Get-FileHash -LiteralPath $t2 -Algorithm SHA256).Hash)
    Remove-Item -LiteralPath $t1, $t2 -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $rr.Backup -Force -ErrorAction SilentlyContinue

    Write-Section ('Self test summary: ' + $script:PassCount + ' passed, ' + $script:FailCount + ' failed')
    return ($script:FailCount -eq 0)
}

function Invoke-MakeFixtures {
    $dir = Join-Path $PSScriptRoot 'tests\fixtures'
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    Set-Content -LiteralPath (Join-Path $dir 'cbs_clean.log') -Value (New-FixtureLines -Kind clean) -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $dir 'cbs_repaired.log') -Value (New-FixtureLines -Kind repaired) -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $dir 'cbs_unfixable.log') -Value (New-FixtureLines -Kind unfixable) -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $dir 'cbs_unfixable_legacy.log') -Value (New-FixtureLines -Kind unfixable_legacy) -Encoding UTF8
    Write-Ok ('fixtures written to ' + $dir)
}

function Get-LastRunVerdict {
    $lines = Get-CbsSrLines -Path $LogPath
    $runs = Split-SfcRuns -Lines $lines
    if ($runs.Count -eq 0) { return $null }
    return (Get-SfcVerdict -RunLines $runs[$runs.Count - 1].Lines)
}

function Show-Help {
    Write-Host ''
    Write-Host 'SfcDoctor - repairs SFC-unrepairable corruption without rebooting.' -ForegroundColor White
    Write-Host ''
    Write-Host 'Usage (elevated Windows PowerShell 5.1):'
    Write-Host '  .\SfcDoctor.ps1 -Status        show last SFC verdict + reboot-pending state'
    Write-Host '  .\SfcDoctor.ps1 -CheckOnly     verdict of newest SFC run in CBS.log'
    Write-Host '  .\SfcDoctor.ps1 -Repair        detect + repair loop (sfc, DISM, live replace)'
    Write-Host '  .\SfcDoctor.ps1 -Repair -Yes   same, no confirmation prompt'
    Write-Host '  .\SfcDoctor.ps1 -Repair -SourcePath D:\goodfiles   use known-good source dir or file'
    Write-Host '  .\SfcDoctor.ps1 -Repair -SkipDism   skip DISM, go straight to manual repair'
    Write-Host '  .\SfcDoctor.ps1 -SelfTest      run built-in test suite'
    Write-Host '  .\SfcDoctor.ps1 -MakeFixtures  write sample CBS logs to tests\fixtures'
    Write-Host ''
    Write-Host 'Exit codes: 0 clean or repaired, 1 still unfixable, 2 unfixable (CheckOnly),'
    Write-Host '            3 no completed run, 4 aborted by user, 5 not elevated.'
}

Write-Host ''
Write-Host 'SfcDoctor v1.1.0 - SFC corruption repair without reboot' -ForegroundColor White

if ($SelfTest) {
    $okAll = Invoke-SelfTest
    if ($okAll) { exit 0 } else { exit 1 }
}

if ($MakeFixtures) { Invoke-MakeFixtures; exit 0 }

if ($Status) {
    Write-Section 'Status (read-only)'
    $v = Get-LastRunVerdict
    if ($null -eq $v) {
        Write-Inf 'no completed SFC run found in CBS log'
    } else {
        Write-Inf ('latest SFC run verdict: ' + $v.Verdict)
        if ($v.Verdict -eq 'Unfixable') {
            foreach ($u in $v.Unfixable) { Write-Bad ($u.File + ' of ' + $u.Component) }
        }
    }
    $rb = Test-RebootPending
    Write-Inf ('reboot pending - CBS: ' + $rb.CbsRebootPending + ', WU: ' + $rb.WuRebootRequired + ', pending renames: ' + $rb.PendingRenameCount)
    Write-Inf 'SfcDoctor repairs are live file replacements: they never require a reboot.'
    exit 0
}

if ($CheckOnly) {
    Write-Section 'CheckOnly (read-only)'
    $v = Get-LastRunVerdict
    if ($null -eq $v) { Write-Bad 'no completed SFC run found'; exit 3 }
    if ($v.Verdict -eq 'Clean') { Write-Ok 'Windows Resource Protection: no integrity violations'; exit 0 }
    if ($v.Verdict -eq 'RepairedAll') { Write-Ok ('SFC repaired all corrupt components (' + $v.RepairedCount + ')'); exit 0 }
    if ($v.Verdict -eq 'Unfixable') {
        Write-Bad ('unfixable files: ' + $v.Unfixable.Count)
        foreach ($u in $v.Unfixable) { Write-Bad ('  ' + $u.File + ' of ' + $u.Component) }
        if ($v.PnpOnly) { Write-Inf 'all unfixable entries are SFP/PnP driver-store flags; [SR] component verification is clean' }
        exit 2
    }
    Write-Inf ('verdict: ' + $v.Verdict)
    exit 3
}

if ($Repair) {
    try {
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
    } catch { $isAdmin = $false }
    if (-not $isAdmin) { Write-Bad 'must run from an elevated console'; exit 5 }
    $runDir = Join-Path $WorkRoot ('runs\' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Force -Path $runDir | Out-Null
    $script:Results.runDir = $runDir
    if (-not $Yes) {
        Write-Host 'About to: run sfc /scannow, possibly DISM RestoreHealth, then replace' -ForegroundColor Yellow
        Write-Host 'unfixable system files live (backup + ACL-aware). Nothing here reboots.' -ForegroundColor Yellow
        $a = Read-Host 'Type YES to continue'
        if ($a -cne 'YES') { Write-Inf 'aborted by user'; exit 4 }
    }
    $dismDone = $false
    $manualDone = $false
    $final = $null
    for ($p = 1; $p -le $MaxPasses; $p++) {
        Write-Section ('pass ' + $p + ' of ' + $MaxPasses + ': sfc scan')
        $v = Invoke-SfcScan
        $script:Results.passes += [pscustomobject]@{ pass = $p; verdict = $v.Verdict; unfixable = @($v.Unfixable).Count }
        Write-Inf ('verdict: ' + $v.Verdict)
        if (($v.Verdict -eq 'Clean') -or ($v.Verdict -eq 'RepairedAll')) { $final = $v; break }
        if ($p -eq $MaxPasses) { $final = $v; break }
        if (-not $SkipDism -and -not $dismDone) {
            $dismDone = $true
            [void](Invoke-DismRestoreHealth)
            continue
        }
        $manualDone = $true
        Write-Section ('pass ' + $p + ': manual live repair of unfixable files')
        foreach ($u in $v.Unfixable) {
            $target = Resolve-TargetPath -UnfixItem $u
            if (-not $target) { Write-Bad ('could not resolve target path for ' + $u.File); continue }
            $src = Get-SourceForTarget -UnfixItem $u -Target $target
            if (-not $src) { Write-Bad ('no healthy source found for ' + $target); continue }
            Write-Inf ('repairing ' + $target + ' from ' + $src)
            $r = Repair-ProjectedFileNoReboot -Target $target -Source $src
            $script:Results.repairs += $r
            if ($r.Replaced) { Write-Ok ('replaced live: ' + $r.Method) } else { Write-Bad ('failed: ' + $r.Error) }
        }
    }
    $script:Results.finalVerdict = $final.Verdict
    $script:Results.finished = Get-Date -Format s
    $script:Results.backups = @($script:Backups)
    $json = Join-Path $runDir 'results.json'
    $script:Results | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $json -Encoding UTF8
    Set-Content -LiteralPath (Join-Path $runDir 'repair.done') -Value $final.Verdict -Encoding ASCII
    Write-Section 'final verdict'
    if ($final.Verdict -eq 'Clean') {
        Write-Ok 'sfc /scannow reports NO integrity violations. Fixed without reboot.'
    } elseif ($final.Verdict -eq 'RepairedAll') {
        Write-Ok ('sfc repaired everything (' + $final.RepairedCount + ' components). No reboot required.')
    } else {
        Write-Bad ('still unfixable: ' + @($final.Unfixable).Count)
        foreach ($u in $final.Unfixable) { Write-Bad ('  ' + $u.File + ' of ' + $u.Component) }
        if ($script:Backups.Count -gt 0) { Write-Inf 'originals kept as .sfcdoctor-bak-* next to targets' }
    }
    Write-Inf ('run log: ' + $json)
    if (($final.Verdict -eq 'Clean') -or ($final.Verdict -eq 'RepairedAll')) { exit 0 }
    exit 1
}

Show-Help
exit 0
