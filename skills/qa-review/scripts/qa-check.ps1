<#
.SYNOPSIS
Run-before-you-push quality gate: hygiene scan plus format, lint, typecheck, tests, build and audit for every detected stack.

.DESCRIPTION
Drop this script into any repo. It runs a fixed sequence of stages and prints PASS / FAIL / WARN / SKIP for each:

  1 Hygiene, 2 Format, 3 Lint, 4 Typecheck, 5 Unit tests            (quick mode)
  ... plus Build, Audit (unless -SkipAudit) and E2E (only with -E2E)   (full mode)

Hygiene is built in (no tools needed) and scans changed files (git) or all text files (non-git):
merge-conflict markers, .only tests, debugger leftovers, likely secrets and .env files are FAIL;
console.log, TODO/FIXME/HACK/XXX and files over 1 MB are WARN.

Detected stacks: Node (npm/pnpm/yarn/bun), Python, Go, Rust, .NET, Java (Maven/Gradle).
Only tools present on PATH are used; missing tools produce SKIP, never a crash.

The script is read-only on the project except for writing <Path>/.qa/ (logs and qa-report.md).
Exit code: 0 if no stage FAILed, 1 if any FAILed. WARN and SKIP never fail.
Works on Windows PowerShell 5.1 and PowerShell 7+ (Windows, Linux, macOS).

.PARAMETER Path
Project root to check. Default: current directory.

.PARAMETER Mode
quick (default): Hygiene, Format, Lint, Typecheck, Unit tests.
full: also Build, Audit and (with -E2E) E2E; unit tests run with coverage when available.

.PARAMETER Base
Branch used to find changed files (git diff Base...HEAD). Default: first of origin/main, main, origin/master, master that resolves.

.PARAMETER E2E
Also run end-to-end tests. Only applies with -Mode full.

.PARAMETER SkipAudit
Skip the dependency audit stage.

.PARAMETER FailFast
Stop at the first FAIL.

.PARAMETER ShowOutput
Stream command output live to the console (it is always written to the log files as well).

.EXAMPLE
.\qa-check.ps1
Quick check of the current directory.

.EXAMPLE
.\qa-check.ps1 -Mode full -SkipAudit -Base origin/develop
Full check without the dependency audit, comparing against origin/develop.

.EXAMPLE
.\qa-check.ps1 -Path C:\src\myapp -Mode full -E2E -FailFast -ShowOutput
Full check including E2E tests, stop at first failure, stream output.
#>
[CmdletBinding()]
param(
    [string]$Path = '.',
    [ValidateSet('quick', 'full')]
    [string]$Mode = 'quick',
    [string]$Base = '',
    [switch]$E2E,
    [switch]$SkipAudit,
    [switch]$FailFast,
    [switch]$ShowOutput
)

$ErrorActionPreference = 'Continue'

# ---------------------------------------------------------------- environment
$script:IsWin = $true
$iwVar = Get-Variable -Name IsWindows -ErrorAction SilentlyContinue
if ($iwVar) { $script:IsWin = [bool]$iwVar.Value }

if (-not (Test-Path -LiteralPath $Path -PathType Container)) {
    Write-Host "Path not found or not a directory: $Path" -ForegroundColor Red
    exit 1
}
$script:Root = (Resolve-Path -LiteralPath $Path).ProviderPath
$script:LogDir = Join-Path $script:Root '.qa/logs'
$script:ReportPath = Join-Path $script:Root '.qa/qa-report.md'
$script:Results = New-Object System.Collections.Generic.List[object]
$script:Stopped = $false
$script:HygieneDetail = New-Object System.Collections.Generic.List[string]
$script:ToolRoot = $script:Root
$script:ToolNote = ''
$script:ChangedCount = 0
$script:StartTime = Get-Date

function Test-Cmd {
    param([string]$Name)
    return [bool](Get-Command $Name -ErrorAction SilentlyContinue)
}

function Format-Secs {
    param([double]$Seconds)
    return ($Seconds.ToString('0.0', [System.Globalization.CultureInfo]::InvariantCulture) + 's')
}

function Get-GitLines {
    param([string[]]$GitArgs)
    $prev = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try {
        $out = & git -c core.quotepath=false @GitArgs 2>$null
        if ($LASTEXITCODE -ne 0) { return @() }
        return @($out | ForEach-Object { "$_" } | Where-Object { $_ -ne '' })
    }
    catch { return @() }
    finally { $ErrorActionPreference = $prev }
}

function Add-Result {
    param(
        [string]$Stage,
        [string]$Stack,
        [ValidateSet('PASS', 'FAIL', 'WARN', 'SKIP')]
        [string]$Result,
        [double]$Seconds = 0,
        [string]$Note = '',
        [string]$Log = ''
    )
    $color = 'Gray'
    switch ($Result) {
        'PASS' { $color = 'Green' }
        'FAIL' { $color = 'Red' }
        'WARN' { $color = 'Yellow' }
        'SKIP' { $color = 'DarkGray' }
    }
    $label = $Stage
    if ($Stack) { $label = "$Stack / $Stage" }
    $line = "[$Result] $label  ($(Format-Secs $Seconds))"
    if ($Note -and $Result -ne 'PASS') { $line = "$line - $Note" }
    Write-Host $line -ForegroundColor $color
    $script:Results.Add([pscustomobject]@{
            Stage = $Stage; Stack = $Stack; Result = $Result
            Seconds = $Seconds; Note = $Note; Log = $Log
        })
    if ($Result -eq 'FAIL' -and $FailFast) { $script:Stopped = $true }
}

function Get-LogPath {
    param([string]$Stack, [string]$Stage, [string]$Tag)
    $n = "$Stack-$Stage"
    if ($Tag) { $n = "$n-$Tag" }
    $n = $n.ToLower() -replace '\s+', '-'
    $n = $n -replace '[^a-z0-9._-]', ''
    return (Join-Path $script:LogDir ($n + '.log'))
}

function Invoke-Step {
    param(
        [string]$Stage,
        [string]$Stack,
        [string]$Command,
        [string[]]$Requires = @(),
        [string]$Tag = '',
        [switch]$FailIfOutput,
        [string]$FailIfMatch = '',
        [hashtable]$Env = @{},
        [string]$WorkDir = ''
    )
    if ($script:Stopped) { return }
    if (-not $WorkDir) { $WorkDir = $script:ToolRoot }
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $log = Get-LogPath -Stack $Stack -Stage $Stage -Tag $Tag
    $savedEnv = @{}
    $prevEap = $ErrorActionPreference
    $pushed = $false
    try {
        foreach ($tool in $Requires) {
            if (-not (Test-Cmd $tool)) {
                Add-Result $Stage $Stack 'SKIP' 0 "'$tool' not found - install $tool" ''
                return
            }
        }
        New-Item -ItemType Directory -Force -Path $script:LogDir | Out-Null
        foreach ($k in $Env.Keys) {
            $savedEnv[$k] = [Environment]::GetEnvironmentVariable($k)
            [Environment]::SetEnvironmentVariable($k, [string]$Env[$k])
        }
        Push-Location -LiteralPath $WorkDir
        $pushed = $true
        $ErrorActionPreference = 'Continue'
        $lines = New-Object System.Collections.Generic.List[string]
        if ($script:IsWin) { $exe = 'cmd'; $cmdArgs = @('/c', $Command) }
        else { $exe = 'sh'; $cmdArgs = @('-c', $Command) }
        $global:LASTEXITCODE = 0
        & $exe @cmdArgs 2>&1 | ForEach-Object {
            $l = "$_"
            $lines.Add($l)
            if ($ShowOutput) { Write-Host $l }
        }
        $code = $LASTEXITCODE
        [System.IO.File]::WriteAllLines($log, $lines.ToArray())
        $sw.Stop()

        $failed = $false
        $note = ''
        if ($code -ne 0) { $failed = $true; $note = "exit code $code" }
        elseif ($FailIfOutput) {
            $nonEmpty = @($lines | Where-Object { $_.Trim() -ne '' })
            if ($nonEmpty.Count -gt 0) { $failed = $true; $note = "$($nonEmpty.Count) file(s) need formatting" }
        }
        elseif ($FailIfMatch -and (@($lines | Where-Object { $_ -match $FailIfMatch }).Count -gt 0)) {
            $failed = $true; $note = 'vulnerabilities reported'
        }

        if ($failed) {
            Add-Result $Stage $Stack 'FAIL' $sw.Elapsed.TotalSeconds $note $log
            $tail = @($lines | Select-Object -Last 30)
            if (-not $ShowOutput) {
                foreach ($t in $tail) { Write-Host "    $t" -ForegroundColor DarkYellow }
            }
            Write-Host "    log: $log" -ForegroundColor Red
        }
        else {
            $n = $Tag
            Add-Result $Stage $Stack 'PASS' $sw.Elapsed.TotalSeconds $n $log
        }
    }
    catch {
        $sw.Stop()
        $msg = $_.Exception.Message
        Add-Result $Stage $Stack 'FAIL' $sw.Elapsed.TotalSeconds "error: $msg" $log
    }
    finally {
        $ErrorActionPreference = $prevEap
        if ($pushed) { Pop-Location }
        foreach ($k in $savedEnv.Keys) { [Environment]::SetEnvironmentVariable($k, $savedEnv[$k]) }
    }
}

# ---------------------------------------------------------------- git info
$script:IsGit = $false
$script:Branch = '(not a git repo)'
$script:BaseResolved = ''
if (Test-Cmd 'git') {
    $inside = @(Get-GitLines @('-C', $script:Root, 'rev-parse', '--is-inside-work-tree'))
    if ($inside.Count -gt 0 -and $inside[0] -eq 'true') {
        $script:IsGit = $true
        $b = @(Get-GitLines @('-C', $script:Root, 'rev-parse', '--abbrev-ref', 'HEAD'))
        if ($b.Count -gt 0) { $script:Branch = $b[0] } else { $script:Branch = '(no commits yet)' }
        $cands = @('origin/main', 'main', 'origin/master', 'master')
        if ($Base) { $cands = @($Base) }
        foreach ($c in $cands) {
            $r = @(Get-GitLines @('-C', $script:Root, 'rev-parse', '--verify', '--quiet', $c))
            if ($r.Count -gt 0) { $script:BaseResolved = $c; break }
        }
    }
}

# ---------------------------------------------------------------- stack detection
$script:Stacks = New-Object System.Collections.Generic.List[object]

function Test-RootFile { param([string]$Name) return (Test-Path -LiteralPath (Join-Path $script:ToolRoot $Name) -PathType Leaf) }

function Test-StackMarker {
    param([string]$Dir)
    foreach ($m in @('package.json', 'pyproject.toml', 'requirements.txt', 'setup.py', 'setup.cfg', 'go.mod', 'Cargo.toml', 'pom.xml', 'build.gradle', 'build.gradle.kts')) {
        if (Test-Path -LiteralPath (Join-Path $Dir $m) -PathType Leaf) { return $true }
    }
    $d = @(Get-ChildItem -LiteralPath $Dir -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.sln', '.csproj') })
    return ($d.Count -gt 0)
}

if (-not (Test-StackMarker $script:Root)) {
    $stopAt = ''
    if ($script:IsGit) {
        $top = @(Get-GitLines @('-C', $script:Root, 'rev-parse', '--show-toplevel'))
        if ($top.Count -gt 0) { $stopAt = ([System.IO.Path]::GetFullPath(($top[0] -replace '/', '\'))).TrimEnd('\') }
    }
    $cur = $script:Root
    while ($true) {
        if ($stopAt -and ($cur.TrimEnd('\') -ieq $stopAt)) { break }
        $parent = Split-Path -Parent $cur
        if ([string]::IsNullOrEmpty($parent) -or ($parent -eq $cur)) { break }
        $cur = $parent
        if (Test-StackMarker $cur) {
            $script:ToolRoot = $cur
            $script:ToolNote = "No project file in $($script:Root); lint/typecheck/tests run for the whole project at $cur."
            break
        }
    }
}

if (Test-RootFile 'package.json') {
    $pm = 'npm'
    if (Test-RootFile 'pnpm-lock.yaml') { $pm = 'pnpm' }
    elseif (Test-RootFile 'yarn.lock') { $pm = 'yarn' }
    elseif ((Test-RootFile 'bun.lockb') -or (Test-RootFile 'bun.lock')) { $pm = 'bun' }
    $scripts = @{}
    $deps = @{}
    try {
        $pkg = Get-Content -LiteralPath (Join-Path $script:ToolRoot 'package.json') -Raw | ConvertFrom-Json
        if ($pkg.scripts) { foreach ($p in $pkg.scripts.PSObject.Properties) { $scripts[$p.Name] = [string]$p.Value } }
        foreach ($sec in @('dependencies', 'devDependencies')) {
            if ($pkg.$sec) { foreach ($p in $pkg.$sec.PSObject.Properties) { $deps[$p.Name] = $true } }
        }
    }
    catch { Write-Host "WARN: could not parse package.json: $($_.Exception.Message)" -ForegroundColor Yellow }
    $script:Stacks.Add(@{
            Name = 'Node'
            Ctx = @{
                PM = $pm; Scripts = $scripts; Deps = $deps
                HasModules = (Test-Path -LiteralPath (Join-Path $script:ToolRoot 'node_modules') -PathType Container)
                HasTsconfig = (Test-RootFile 'tsconfig.json')
            }
        })
}
if ((Test-RootFile 'pyproject.toml') -or (Test-RootFile 'requirements.txt') -or (Test-RootFile 'setup.py') -or (Test-RootFile 'setup.cfg')) {
    $script:Stacks.Add(@{ Name = 'Python'; Ctx = @{} })
}
if (Test-RootFile 'go.mod') { $script:Stacks.Add(@{ Name = 'Go'; Ctx = @{} }) }
if (Test-RootFile 'Cargo.toml') { $script:Stacks.Add(@{ Name = 'Rust'; Ctx = @{} }) }
$dn = @(Get-ChildItem -LiteralPath $script:ToolRoot -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.sln', '.csproj') })
if ($dn.Count -gt 0) { $script:Stacks.Add(@{ Name = '.NET'; Ctx = @{} }) }
if ((Test-RootFile 'pom.xml') -or (Test-RootFile 'build.gradle') -or (Test-RootFile 'build.gradle.kts')) {
    $jc = @{ Tool = 'gradle'; Cmd = 'gradle'; Req = @('gradle') }
    if (Test-RootFile 'pom.xml') { $jc = @{ Tool = 'maven'; Cmd = 'mvn'; Req = @('mvn') } }
    elseif ((Test-RootFile 'gradlew') -or (Test-RootFile 'gradlew.bat')) {
        $jc.Req = @()
        if ($script:IsWin) { $jc.Cmd = 'gradlew.bat' } else { $jc.Cmd = './gradlew' }
    }
    $script:Stacks.Add(@{ Name = 'Java'; Ctx = $jc })
}

# ---------------------------------------------------------------- header
$stackNames = 'none'
if ($script:Stacks.Count -gt 0) { $stackNames = (($script:Stacks | ForEach-Object { $_.Name }) -join ', ') }
$baseText = $script:BaseResolved
if (-not $baseText) { if ($script:IsGit) { $baseText = '(unresolved)' } else { $baseText = '(n/a)' } }
Write-Host ''
Write-Host '=== qa-check ===' -ForegroundColor Cyan
Write-Host "Project : $script:Root"
if ($script:ToolRoot -ne $script:Root) { Write-Host "Tools at: $script:ToolRoot" }
Write-Host "Mode    : $Mode"
Write-Host "Base    : $baseText"
Write-Host "Stacks  : $stackNames"
Write-Host "Branch  : $script:Branch"
Write-Host ''

# ---------------------------------------------------------------- stage 1: Hygiene
function Get-AllFiles {
    param([string]$RootDir)
    $excl = @('node_modules', '.git', 'dist', 'build', '.next', 'out', 'coverage', '.venv', 'venv', '__pycache__', 'target', 'bin', 'obj', '.qa')
    $res = New-Object System.Collections.Generic.List[string]
    $stk = New-Object System.Collections.Generic.Stack[string]
    $stk.Push('')
    while ($stk.Count -gt 0) {
        $rel = $stk.Pop()
        $dir = $RootDir
        if ($rel -ne '') { $dir = Join-Path $RootDir $rel }
        try {
            foreach ($d in [System.IO.Directory]::GetDirectories($dir)) {
                $n = [System.IO.Path]::GetFileName($d)
                if ($excl -contains $n) { continue }
                if ($rel -eq '') { $stk.Push($n) } else { $stk.Push("$rel/$n") }
            }
            foreach ($f in [System.IO.Directory]::GetFiles($dir)) {
                $n = [System.IO.Path]::GetFileName($f)
                if ($rel -eq '') { $res.Add($n) } else { $res.Add("$rel/$n") }
            }
        }
        catch { }
    }
    return $res.ToArray()
}

function Invoke-Hygiene {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    try {
        $files = @()
        if ($script:IsGit) {
            $set = @{}
            $gl = @()
            if ($script:BaseResolved) {
                $gl += Get-GitLines @('-C', $script:Root, 'diff', '--name-only', '--relative', "$($script:BaseResolved)...HEAD")
            }
            else {
                $m = 'Base branch could not be resolved; using working-tree changes only.'
                Write-Host "WARN: $m" -ForegroundColor Yellow
                $script:HygieneDetail.Add("WARN: $m")
            }
            $gl += Get-GitLines @('-C', $script:Root, 'diff', '--name-only', '--relative', 'HEAD')
            $gl += Get-GitLines @('-C', $script:Root, 'diff', '--name-only', '--relative', '--cached')
            $gl += Get-GitLines @('-C', $script:Root, 'ls-files', '--others', '--exclude-standard')
            foreach ($f in $gl) {
                if ($f.StartsWith('.qa/')) { continue }
                if ($set.ContainsKey($f)) { continue }
                if (Test-Path -LiteralPath (Join-Path $script:Root $f) -PathType Leaf) { $set[$f] = $true; $files += $f }
            }
        }
        else {
            $files = @(Get-AllFiles $script:Root)
        }
        $script:ChangedCount = $files.Count
        if ($files.Count -eq 0) {
            $sw.Stop()
            $msg = 'No changed files'
            if (-not $script:IsGit) { $msg = 'No files to scan' }
            Write-Host "  $msg"
            $script:HygieneDetail.Add($msg)
            Add-Result 'Hygiene' '' 'PASS' $sw.Elapsed.TotalSeconds $msg ''
            return
        }

        $binExt = @('png', 'jpg', 'gif', 'ico', 'pdf', 'zip', 'woff', 'woff2', 'ttf', 'exe', 'dll', 'lock')
        $skipNames = @('package-lock.json', 'pnpm-lock.yaml', 'bun.lock', 'composer.lock')
        $jsExt = @('js', 'jsx', 'ts', 'tsx', 'mjs', 'cjs', 'vue', 'svelte')
        $jsDbg = @('js', 'jsx', 'ts', 'tsx', 'mjs', 'cjs', 'vue', 'svelte')
        function New-Rx { param([string]$P) return (New-Object System.Text.RegularExpressions.Regex($P)) }

        $checks = @(
            @{ Name = 'Merge conflict markers'; Level = 'FAIL'; Rx = @((New-Rx '^(<<<<<<<|>>>>>>>)( |$)')); Exts = $null }
            @{ Name = 'Focused tests (.only / fit / fdescribe)'; Level = 'FAIL'; Rx = @((New-Rx '\b(it|describe|test)\.only\('), (New-Rx '\bf(it|describe)\(')); Exts = $jsDbg }
            @{ Name = 'Debugger statement'; Level = 'FAIL'; Rx = @((New-Rx '^\s*debugger;?\s*$')); Exts = $jsDbg }
            @{ Name = 'Python breakpoint'; Level = 'FAIL'; Rx = @((New-Rx 'breakpoint\(\)'), (New-Rx 'pdb\.set_trace\(')); Exts = @('py') }
            @{
                Name = 'Likely secret'; Level = 'FAIL'; Redact = $true; Exts = $null
                Rx = @(
                    (New-Rx 'AKIA[0-9A-Z]{16}'),
                    (New-Rx '-----BEGIN [A-Z ]*PRIVATE KEY-----'),
                    (New-Rx '(?<![A-Za-z0-9])sk-[A-Za-z0-9_-]{20,}'),
                    (New-Rx 'gh[pousr]_[A-Za-z0-9]{36}'),
                    (New-Rx 'xox[baprs]-[A-Za-z0-9-]{10,}'),
                    (New-Rx '(?i)(api[_-]?key|secret|passw(or)?d|access[_-]?token)\s*[:=]\s*[''"][^''"\s]{8,}[''"]')
                )
            }
            @{ Name = 'console.log in non-test code'; Level = 'WARN'; Rx = @((New-Rx 'console\.log\(')); Exts = $jsExt; NoTests = $true }
            @{ Name = 'TODO/FIXME/HACK/XXX'; Level = 'WARN'; Rx = @((New-Rx '\b(TODO|FIXME|HACK|XXX)\b')); Exts = $null }
        )
        $hits = @{}
        foreach ($c in $checks) { $hits[$c.Name] = New-Object System.Collections.Generic.List[string] }
        $envHits = New-Object System.Collections.Generic.List[string]
        $bigHits = New-Object System.Collections.Generic.List[string]
        $testRx = New-Object System.Text.RegularExpressions.Regex('test|spec|__tests__|e2e', 'IgnoreCase')

        foreach ($f in $files) {
            $full = Join-Path $script:Root $f
            $name = [System.IO.Path]::GetFileName($f)
            $ext = [System.IO.Path]::GetExtension($f).TrimStart('.').ToLower()
            if ($name -match '^\.env(\..+)?$' -and $name -notin @('.env.example', '.env.sample', '.env.template')) {
                $envHits.Add("${f}:1: environment file should not be committed")
            }
            $size = 0
            try { $size = (New-Object System.IO.FileInfo($full)).Length } catch { }
            if ($size -gt 1MB) { $bigHits.Add("${f}:1: $([math]::Round($size / 1MB, 1)) MB"); continue }
            if ($binExt -contains $ext) { continue }
            if ($skipNames -contains $name -or $name.EndsWith('.min.js')) { continue }
            $text = $null
            try { $text = [System.IO.File]::ReadAllText($full) } catch { continue }
            if ($text.IndexOf([char]0) -ge 0) { continue }
            $rel = $f -replace '\\', '/'
            $lineArr = $text -split "\r?\n"
            foreach ($c in $checks) {
                if ($c.Exts -and ($c.Exts -notcontains $ext)) { continue }
                if ($c.NoTests -and $testRx.IsMatch($rel)) { continue }
                for ($i = 0; $i -lt $lineArr.Length; $i++) {
                    $ln = $lineArr[$i]
                    if ($ln.Length -lt 3) { continue }
                    foreach ($rx in $c.Rx) {
                        $mm = $rx.Match($ln)
                        if ($mm.Success) {
                            $shown = $ln.Trim()
                            if ($c.Redact) {
                                $v = $mm.Value
                                $red = $v.Substring(0, [math]::Min(4, $v.Length)) + '****'
                                $shown = $shown.Replace($v, $red)
                            }
                            if ($shown.Length -gt 140) { $shown = $shown.Substring(0, 140) + '...' }
                            $hits[$c.Name].Add("${rel}:$($i + 1): $shown")
                            break
                        }
                    }
                }
            }
        }
        if ($envHits.Count -gt 0) {
            $hits['Environment file (.env)'] = $envHits
            $checks += @{ Name = 'Environment file (.env)'; Level = 'FAIL' }
        }
        if ($bigHits.Count -gt 0) {
            $hits['File larger than 1 MB'] = $bigHits
            $checks += @{ Name = 'File larger than 1 MB'; Level = 'WARN' }
        }

        $anyFail = $false
        $anyWarn = $false
        $failN = 0
        $warnN = 0
        foreach ($c in $checks) {
            $h = $hits[$c.Name]
            if ($h.Count -eq 0) { continue }
            $color = 'Yellow'
            if ($c.Level -eq 'FAIL') { $color = 'Red'; $anyFail = $true; $failN++ } else { $anyWarn = $true; $warnN++ }
            $hdr = "  [$($c.Level)] $($c.Name) ($($h.Count))"
            Write-Host $hdr -ForegroundColor $color
            $script:HygieneDetail.Add($hdr.Trim())
            $shownN = [math]::Min(20, $h.Count)
            for ($i = 0; $i -lt $shownN; $i++) {
                Write-Host "      $($h[$i])"
                $script:HygieneDetail.Add("    $($h[$i])")
            }
            if ($h.Count -gt 20) {
                $more = "      ...and $($h.Count - 20) more"
                Write-Host $more
                $script:HygieneDetail.Add($more.TrimEnd())
            }
        }
        $sw.Stop()
        $note = "$($files.Count) file(s) scanned"
        if ($anyFail) { Add-Result 'Hygiene' '' 'FAIL' $sw.Elapsed.TotalSeconds "$failN failing check(s); $note" '' }
        elseif ($anyWarn) { Add-Result 'Hygiene' '' 'WARN' $sw.Elapsed.TotalSeconds "$warnN warning check(s); $note" '' }
        else { Add-Result 'Hygiene' '' 'PASS' $sw.Elapsed.TotalSeconds $note '' }
    }
    catch {
        $sw.Stop()
        Add-Result 'Hygiene' '' 'FAIL' $sw.Elapsed.TotalSeconds "error: $($_.Exception.Message)" ''
    }
}

Invoke-Hygiene
if ((-not $script:Stopped) -and (Test-Cmd 'gitleaks')) {
    Invoke-Step -Stage 'Hygiene' -Stack 'Gitleaks' -Command 'gitleaks detect --no-banner --source .' -Requires @('gitleaks') -WorkDir $script:Root
}

# ---------------------------------------------------------------- per-stack stage specs
function New-Run {
    param([string]$Cmd, [string[]]$Requires = @(), [string]$Tag = '', [switch]$FailIfOutput, [string]$FailIfMatch = '', [hashtable]$Env = @{})
    return @{ Cmd = $Cmd; Requires = $Requires; Tag = $Tag; FailIfOutput = [bool]$FailIfOutput; FailIfMatch = $FailIfMatch; Env = $Env }
}
function New-Skip { param([string]$Why) return @{ Skip = $Why } }

function Get-NodeSpecs {
    param($c, [string]$Stage, [bool]$Full)
    $pm = $c.PM
    $s = $c.Scripts
    $firstScript = {
        param([string[]]$names)
        foreach ($n in $names) { if ($s.ContainsKey($n) -and $s[$n] -notmatch 'no test specified') { return $n } }
        return $null
    }
    if ((-not $c.HasModules) -and $Stage -ne 'Audit') {
        if ($Stage -eq 'Format') { return @(@{ Warn = "dependencies not installed - run $pm install" }) }
        return @(New-Skip 'dependencies not installed')
    }
    switch ($Stage) {
        'Format' {
            $n = & $firstScript @('format:check', 'prettier:check', 'check:format')
            if ($n) { return @(New-Run "$pm run $n") }
            if ($c.Deps.ContainsKey('prettier')) { return @(New-Run 'npx prettier --check .') }
            return @(New-Skip 'no format script or prettier')
        }
        'Lint' {
            $n = & $firstScript @('lint')
            if ($n) { return @(New-Run "$pm run $n") }
            if ($c.Deps.ContainsKey('eslint')) { return @(New-Run 'npx eslint .') }
            return @(New-Skip 'no lint script or eslint')
        }
        'Typecheck' {
            $n = & $firstScript @('typecheck', 'type-check', 'check-types', 'tsc')
            if ($n) { return @(New-Run "$pm run $n") }
            if ($c.HasTsconfig) { return @(New-Run 'npx tsc --noEmit') }
            return @(New-Skip 'no typecheck script or tsconfig.json')
        }
        'Unit tests' {
            if ($Full) { $names = @('test:coverage', 'coverage', 'test:unit', 'test') } else { $names = @('test:unit', 'test') }
            $n = & $firstScript $names
            if ($n) { return @(New-Run "$pm run $n" -Env @{ CI = 'true' }) }
            return @(New-Skip 'no test script')
        }
        'Build' {
            $n = & $firstScript @('build')
            if ($n) { return @(New-Run "$pm run $n") }
            return @(New-Skip 'no build script')
        }
        'Audit' {
            switch ($pm) {
                'npm' { return @(New-Run 'npm audit --audit-level=high') }
                'pnpm' { return @(New-Run 'pnpm audit --audit-level high') }
                'yarn' { return @(New-Run 'yarn audit --level high') }
                default { return @(New-Skip 'bun has no audit command') }
            }
        }
        'E2E' {
            $n = & $firstScript @('test:e2e', 'e2e')
            if ($n) { return @(New-Run "$pm run $n" -Env @{ CI = 'true' }) }
            return @(New-Skip 'no e2e script')
        }
    }
    return @(New-Skip 'n/a')
}

function Get-PythonSpecs {
    param([string]$Stage, [bool]$Full)
    switch ($Stage) {
        'Format' {
            if (Test-Cmd 'ruff') { return @(New-Run 'ruff format --check .') }
            if (Test-Cmd 'black') { return @(New-Run 'black --check .') }
            return @(New-Skip 'install ruff or black')
        }
        'Lint' {
            if (Test-Cmd 'ruff') { return @(New-Run 'ruff check .') }
            if (Test-Cmd 'flake8') { return @(New-Run 'flake8') }
            return @(New-Skip 'install ruff or flake8')
        }
        'Typecheck' {
            if (Test-Cmd 'mypy') { return @(New-Run 'mypy .') }
            return @(New-Skip 'install mypy')
        }
        'Unit tests' {
            if (-not (Test-Cmd 'pytest')) { return @(New-Skip 'install pytest') }
            $cmd = 'pytest -q'
            if ($Full) {
                $py = ''
                if (Test-Cmd 'python') { $py = 'python' } elseif (Test-Cmd 'python3') { $py = 'python3' }
                if ($py) {
                    try {
                        & $py -c 'import pytest_cov' 2>$null | Out-Null
                        if ($LASTEXITCODE -eq 0) { $cmd = 'pytest -q --cov' }
                    }
                    catch { }
                }
            }
            return @(New-Run $cmd)
        }
        'Build' { return @(New-Skip 'no build step for Python') }
        'Audit' {
            if (Test-Cmd 'pip-audit') { return @(New-Run 'pip-audit') }
            return @(New-Skip 'install pip-audit')
        }
        'E2E' { return @(New-Skip 'no E2E for Python') }
    }
    return @(New-Skip 'n/a')
}

function Get-GoSpecs {
    param([string]$Stage, [bool]$Full)
    if (-not (Test-Cmd 'go')) { return @(New-Skip 'install go') }
    switch ($Stage) {
        'Format' { return @(New-Run 'gofmt -l .' -Requires @('gofmt') -FailIfOutput) }
        'Lint' {
            $r = @(New-Run 'go vet ./...' -Tag 'vet')
            if (Test-Cmd 'golangci-lint') { $r += New-Run 'golangci-lint run' -Tag 'golangci-lint' }
            return $r
        }
        'Typecheck' { return @(New-Skip 'covered by build') }
        'Unit tests' {
            if ($Full) { return @(New-Run 'go test -race -cover ./...') }
            return @(New-Run 'go test ./...')
        }
        'Build' { return @(New-Run 'go build ./...') }
        'Audit' {
            if (Test-Cmd 'govulncheck') { return @(New-Run 'govulncheck ./...') }
            return @(New-Skip 'install govulncheck')
        }
        'E2E' { return @(New-Skip 'no E2E for Go') }
    }
    return @(New-Skip 'n/a')
}

function Get-RustSpecs {
    param([string]$Stage, [bool]$Full)
    if (-not (Test-Cmd 'cargo')) { return @(New-Skip 'install rust (cargo)') }
    switch ($Stage) {
        'Format' { return @(New-Run 'cargo fmt --check') }
        'Lint' { return @(New-Run 'cargo clippy --all-targets -- -D warnings') }
        'Typecheck' { return @(New-Skip 'covered by build') }
        'Unit tests' { return @(New-Run 'cargo test') }
        'Build' { return @(New-Run 'cargo build') }
        'Audit' {
            if (Test-Cmd 'cargo-audit') { return @(New-Run 'cargo audit') }
            return @(New-Skip 'install cargo-audit')
        }
        'E2E' { return @(New-Skip 'no E2E for Rust') }
    }
    return @(New-Skip 'n/a')
}

function Get-DotnetSpecs {
    param([string]$Stage, [bool]$Full)
    if (-not (Test-Cmd 'dotnet')) { return @(New-Skip 'install the .NET SDK') }
    switch ($Stage) {
        'Format' { return @(New-Run 'dotnet format --verify-no-changes') }
        'Lint' { return @(New-Skip 'no separate lint step') }
        'Typecheck' { return @(New-Skip 'covered by build') }
        'Unit tests' { return @(New-Run 'dotnet test') }
        'Build' { return @(New-Run 'dotnet build -warnaserror') }
        'Audit' { return @(New-Run 'dotnet list package --vulnerable --include-transitive' -FailIfMatch 'has the following vulnerable packages') }
        'E2E' { return @(New-Skip 'no E2E for .NET') }
    }
    return @(New-Skip 'n/a')
}

function Get-JavaSpecs {
    param($c, [string]$Stage, [bool]$Full)
    $req = $c.Req
    if ($c.Tool -eq 'maven') {
        switch ($Stage) {
            'Unit tests' { return @(New-Run 'mvn -q test' -Requires $req) }
            'Build' { return @(New-Run 'mvn -q -DskipTests package' -Requires $req) }
            default { return @(New-Skip 'not configured for Maven') }
        }
    }
    $g = $c.Cmd
    switch ($Stage) {
        'Lint' { return @(New-Run "$g check -x test" -Requires $req) }
        'Unit tests' { return @(New-Run "$g test" -Requires $req) }
        'Build' { return @(New-Run "$g assemble" -Requires $req) }
        default { return @(New-Skip 'not configured for Gradle') }
    }
}

function Get-Specs {
    param($Stack, [string]$Stage, [bool]$Full)
    switch ($Stack.Name) {
        'Node' { return @(Get-NodeSpecs $Stack.Ctx $Stage $Full) }
        'Python' { return @(Get-PythonSpecs $Stage $Full) }
        'Go' { return @(Get-GoSpecs $Stage $Full) }
        'Rust' { return @(Get-RustSpecs $Stage $Full) }
        '.NET' { return @(Get-DotnetSpecs $Stage $Full) }
        'Java' { return @(Get-JavaSpecs $Stack.Ctx $Stage $Full) }
    }
    return @(New-Skip 'n/a')
}

# ---------------------------------------------------------------- stages 2-8
$isFull = ($Mode -eq 'full')
$stageList = @('Format', 'Lint', 'Typecheck', 'Unit tests')
if ($isFull) {
    $stageList += 'Build'
    if (-not $SkipAudit) { $stageList += 'Audit' }
    if ($E2E) { $stageList += 'E2E' }
}
elseif ($E2E) {
    Write-Host 'Note: E2E needs -Mode full; skipping E2E in quick mode.' -ForegroundColor Yellow
}
if ($script:ToolNote) { Write-Host "Note: $script:ToolNote" -ForegroundColor Yellow }
if ($script:Stacks.Count -eq 0) {
    Write-Host 'Note: no supported stack detected (Node, Python, Go, Rust, .NET, Java); only Hygiene ran.' -ForegroundColor Yellow
}

foreach ($stage in $stageList) {
    foreach ($stack in $script:Stacks) {
        if ($script:Stopped) { break }
        try {
            $specs = @(Get-Specs $stack $stage $isFull)
            foreach ($sp in $specs) {
                if ($script:Stopped) { break }
                if ($sp.ContainsKey('Skip')) { Add-Result $stage $stack.Name 'SKIP' 0 $sp.Skip '' }
                elseif ($sp.ContainsKey('Warn')) { Add-Result $stage $stack.Name 'WARN' 0 $sp.Warn '' }
                else {
                    Invoke-Step -Stage $stage -Stack $stack.Name -Command $sp.Cmd -Requires $sp.Requires `
                        -Tag $sp.Tag -FailIfOutput:$sp.FailIfOutput -FailIfMatch $sp.FailIfMatch -Env $sp.Env
                }
            }
        }
        catch {
            Add-Result $stage $stack.Name 'FAIL' 0 "error: $($_.Exception.Message)" ''
        }
    }
    if ($script:Stopped) { break }
}
if ($script:Stopped) {
    Write-Host 'Stopped early (-FailFast): remaining stages were not run.' -ForegroundColor Red
}

# ---------------------------------------------------------------- summary
$failCount = @($script:Results | Where-Object { $_.Result -eq 'FAIL' }).Count
$warnCount = @($script:Results | Where-Object { $_.Result -eq 'WARN' }).Count
if ($failCount -gt 0) { $verdict = 'NOT READY - fix FAIL items'; $vColor = 'Red' }
elseif ($warnCount -gt 0) { $verdict = 'READY WITH WARNINGS'; $vColor = 'Yellow' }
else { $verdict = 'READY TO PUSH'; $vColor = 'Green' }

Write-Host ''
Write-Host '=== Summary ===' -ForegroundColor Cyan
$hdrLine = ('{0}  {1}  {2}  {3}  {4}' -f 'Stage'.PadRight(11), 'Stack'.PadRight(9), 'Result'.PadRight(6), 'Time'.PadRight(7), 'Note')
Write-Host $hdrLine
foreach ($r in $script:Results) {
    $col = 'Gray'
    switch ($r.Result) { 'PASS' { $col = 'Green' } 'FAIL' { $col = 'Red' } 'WARN' { $col = 'Yellow' } 'SKIP' { $col = 'DarkGray' } }
    $nt = [string]$r.Note
    if ($nt.Length -gt 70) { $nt = $nt.Substring(0, 67) + '...' }
    $stk = $r.Stack
    if (-not $stk) { $stk = '-' }
    $row = ('{0}  {1}  {2}  {3}  {4}' -f ([string]$r.Stage).PadRight(11), ([string]$stk).PadRight(9), $r.Result.PadRight(6), (Format-Secs $r.Seconds).PadRight(7), $nt)
    Write-Host $row -ForegroundColor $col
}
Write-Host ''
Write-Host $verdict -ForegroundColor $vColor

# ---------------------------------------------------------------- report
try {
    New-Item -ItemType Directory -Force -Path (Join-Path $script:Root '.qa') | Out-Null
    $md = New-Object System.Collections.Generic.List[string]
    $md.Add('# QA report')
    $md.Add('')
    $md.Add("- Timestamp: $($script:StartTime.ToString('yyyy-MM-dd HH:mm:ss'))")
    $md.Add("- Project: $script:Root")
    if ($script:ToolRoot -ne $script:Root) { $md.Add("- Tools at: $script:ToolRoot") }
    $md.Add("- Mode: $Mode")
    $md.Add("- Base: $baseText")
    $md.Add("- Branch: $script:Branch")
    $md.Add("- Stacks: $stackNames")
    $md.Add("- Files checked by Hygiene: $script:ChangedCount")
    if ($script:ToolNote) { $md.Add(''); $md.Add("> $script:ToolNote") }
    $md.Add('')
    $md.Add('| Stage | Stack | Result | Time | Note |')
    $md.Add('| --- | --- | --- | --- | --- |')
    foreach ($r in $script:Results) {
        $stk = $r.Stack
        if (-not $stk) { $stk = '-' }
        $nt = ([string]$r.Note) -replace '\|', '/'
        $md.Add("| $($r.Stage) | $stk | $($r.Result) | $(Format-Secs $r.Seconds) | $nt |")
    }
    $md.Add('')
    $md.Add("**Verdict: $verdict**")
    $fails = @($script:Results | Where-Object { $_.Result -eq 'FAIL' })
    if ($fails.Count -gt 0) {
        $md.Add('')
        $md.Add('## Failures')
        foreach ($f in $fails) {
            $stk = $f.Stack
            if (-not $stk) { $stk = '-' }
            $lg = 'see Hygiene findings below'
            if ($f.Log) { $lg = $f.Log }
            $md.Add("- $stk / $($f.Stage): log: $lg")
        }
    }
    if ($script:HygieneDetail.Count -gt 0) {
        $md.Add('')
        $md.Add('## Hygiene findings')
        $md.Add('')
        $md.Add('```')
        foreach ($l in $script:HygieneDetail) { $md.Add($l) }
        $md.Add('```')
    }
    [System.IO.File]::WriteAllLines($script:ReportPath, $md.ToArray())
    Write-Host "Report: $script:ReportPath"
}
catch {
    Write-Host "Could not write report: $($_.Exception.Message)" -ForegroundColor Yellow
}

# ---------------------------------------------------------------- gitignore tip
try {
    $ignored = $false
    $gi = Join-Path $script:Root '.gitignore'
    if (Test-Path -LiteralPath $gi -PathType Leaf) {
        foreach ($l in (Get-Content -LiteralPath $gi -ErrorAction SilentlyContinue)) {
            if ($l -match '^\s*/?\.qa(/\*{0,2})?\s*$') { $ignored = $true; break }
        }
    }
    if ((-not $ignored) -and $script:IsGit) {
        $null = & git -C $script:Root check-ignore -q .qa/ 2>$null
        if ($LASTEXITCODE -eq 0) { $ignored = $true }
    }
    if (-not $ignored) { Write-Host 'Tip: Add .qa/ to .gitignore' -ForegroundColor DarkCyan }
}
catch { }

if ($failCount -gt 0) { exit 1 }
exit 0
