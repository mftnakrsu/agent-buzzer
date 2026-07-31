#!/usr/bin/env pwsh
<#
    agent-buzzer test suite for buzzer.ps1.

    tests/run.sh is the thorough one; this covers the same silence rules on
    Windows so the port cannot quietly rot. No Pester, no modules:

        pwsh -File tests/run.ps1

    Like the bash suite, it fakes the outside world with the environment
    variables buzzer.ps1 already reads: BUZZER_HOME, BUZZER_DRY_RUN,
    BUZZER_FAKE_FRONTMOST ("-" = undetectable) and BUZZER_FAKE_NOW.
#>

Set-StrictMode -Off
$ErrorActionPreference = 'Continue'

$root = Split-Path -Parent (Split-Path -Parent $PSCommandPath)
$buzzer = Join-Path $root 'buzzer.ps1'

# Hooks are launched as a real process with real stdin, the way Claude Code
# launches them. Piping to a script inside this session would go to the
# PowerShell pipeline instead, which is not the path under test.
$psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
$script:passed = 0
$script:failed = 0
$script:failures = @()
$script:errors = @()
$script:state = ''

function Start-TestCase {
    $script:errors = @()
    $script:state = Join-Path ([IO.Path]::GetTempPath()) ("buzzer-test-" + [Guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path (Join-Path $script:state 'marks') | Out-Null
    $bird = Join-Path (Join-Path $root 'sounds') 'bird.wav'
    @"
enabled=true
threshold_seconds=30
volume=0.7
quiet_hours=false
quiet_start=23:00
quiet_end=08:00
terminal_app=
done_enabled=true
done_sound=$bird
done_volume=
done_repeat=1
waiting_enabled=true
waiting_sound=$bird
waiting_volume=
waiting_repeat=2
error_enabled=true
error_sound=$bird
error_volume=
error_repeat=1
subagent_enabled=true
subagent_sound=$bird
subagent_volume=0.35
subagent_repeat=1
"@ | Set-Content -LiteralPath (Join-Path $script:state 'config') -Encoding UTF8

    $env:BUZZER_HOME = $script:state
    $env:BUZZER_DRY_RUN = '1'
    $env:BUZZER_FAKE_FRONTMOST = '-'
    $env:BUZZER_FAKE_NOW = ''
    $env:TERM_PROGRAM = ''
}

function Stop-TestCase {
    Remove-Item -LiteralPath $script:state -Recurse -Force -ErrorAction SilentlyContinue
    Remove-Item Env:\BUZZER_DRY_RUN -ErrorAction SilentlyContinue
    Remove-Item Env:\BUZZER_FAKE_FRONTMOST -ErrorAction SilentlyContinue
    Remove-Item Env:\BUZZER_FAKE_NOW -ErrorAction SilentlyContinue
}

function Add-Failure {
    param([string]$Message)
    $script:errors += $Message
}

function Invoke-TestCase {
    param([string]$Name, [scriptblock]$Body)
    Start-TestCase
    try {
        & $Body
    } catch {
        Add-Failure "threw: $_"
    }
    Stop-TestCase
    if ($script:errors.Count -eq 0) {
        $script:passed++
        Write-Host "  ok   $Name" -ForegroundColor Green
    } else {
        $script:failed++
        $script:failures += $Name
        Write-Host "  FAIL $Name" -ForegroundColor Red
        foreach ($e in $script:errors) { Write-Host "       $e" -ForegroundColor Red }
    }
}

# --- driving buzzer.ps1 ----------------------------------------------------

function Invoke-Buzzer {
    param([string]$Payload)
    return ($Payload | & $psExe -NoProfile -File $buzzer @args 2>&1 | Out-String)
}

function Invoke-Hook {
    param([string]$EventName, [string]$SessionId = '')
    $payload = '{"session_id":"' + $SessionId + '","hook_event_name":"Stop"}'
    Invoke-Buzzer -Payload $payload 'hook' $EventName | Out-Null
}

function Invoke-Cli {
    & $buzzer @args 2>&1 | Out-String
}

function Set-Mark {
    param([string]$SessionId, [int]$SecondsAgo)
    $epoch = [int64]([DateTimeOffset]::UtcNow).ToUnixTimeSeconds() - $SecondsAgo
    Set-Content -LiteralPath (Join-Path (Join-Path $script:state 'marks') $SessionId) -Value $epoch
}

function Add-Config {
    param([string]$Key, [string]$Value)
    Add-Content -LiteralPath (Join-Path $script:state 'config') -Value "$Key=$Value"
}

function Get-PlayedContent {
    $p = Join-Path $script:state 'played'
    if (Test-Path -LiteralPath $p) { return (Get-Content -LiteralPath $p -Raw) }
    return ''
}

function Clear-Played {
    Remove-Item -LiteralPath (Join-Path $script:state 'played') -Force -ErrorAction SilentlyContinue
}

function Get-LastReason {
    $p = Join-Path $script:state 'log'
    if (-not (Test-Path -LiteralPath $p)) { return 'no log' }
    $m = [regex]::Matches((Get-Content -LiteralPath $p -Raw), 'reason="([^"]*)"')
    if ($m.Count -eq 0) { return 'no reason logged' }
    return $m[$m.Count - 1].Groups[1].Value
}

function Assert-Played {
    param([string]$EventName = '')
    $content = Get-PlayedContent
    if (-not $content.Trim()) {
        Add-Failure "expected a sound to play, nothing did (reason: $(Get-LastReason))"
        return
    }
    if ($EventName -and $content -notmatch "(?m)^$EventName\|") {
        Add-Failure "expected event '$EventName' to play, got: $($content.Trim())"
    }
}

function Assert-Silent {
    $content = Get-PlayedContent
    if ($content.Trim()) { Add-Failure "expected silence, but this played: $($content.Trim())" }
}

function Assert-Reason {
    param([string]$Expected)
    $got = Get-LastReason
    if ($got -notlike "*$Expected*") {
        Add-Failure "expected the blocking reason to mention '$Expected', got '$got'"
    }
}

function Assert-Contains {
    param([string]$Expected, [string]$Actual, [string]$Label = 'output')
    if ($Actual -notlike "*$Expected*") {
        Add-Failure "$Label should contain '$Expected', got: $Actual"
    }
}

function Assert-Equal {
    param($Expected, $Actual, [string]$Label = 'values')
    if ("$Expected" -ne "$Actual") { Add-Failure "${Label}: expected '$Expected', got '$Actual'" }
}

# --- tests ----------------------------------------------------------------

Write-Host "agent-buzzer tests (PowerShell)  $buzzer"
Write-Host ''

if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $root 'sounds') 'bird.wav'))) {
    Write-Host 'error: sounds/bird.wav is missing — run: python3 tools/make-sounds.py' -ForegroundColor Red
    exit 1
}

Invoke-TestCase 'long turn plays' {
    Set-Mark 'abc123' 120
    Invoke-Hook 'done' 'abc123'
    Assert-Played 'done'
}

Invoke-TestCase 'short turn stays silent' {
    Set-Mark 'abc123' 5
    Invoke-Hook 'done' 'abc123'
    Assert-Silent
    Assert-Reason 'turn too short'
}

Invoke-TestCase 'unknown session plays' {
    Invoke-Hook 'done' ''
    Assert-Played 'done'
}

Invoke-TestCase 'missing mark plays' {
    Invoke-Hook 'done' 'never-marked'
    Assert-Played 'done'
}

Invoke-TestCase 'waiting ignores the threshold' {
    Set-Mark 'abc123' 2
    Invoke-Hook 'waiting' 'abc123'
    Assert-Played 'waiting'
}

Invoke-TestCase 'subagent ignores the threshold' {
    Set-Mark 'abc123' 1
    Invoke-Hook 'subagent' 'abc123'
    Assert-Played 'subagent'
}

Invoke-TestCase 'disabled suppresses everything' {
    Add-Config 'enabled' 'false'
    foreach ($e in @('done', 'waiting', 'error', 'subagent')) {
        Set-Mark 'abc123' 999
        Invoke-Hook $e 'abc123'
    }
    Assert-Silent
    Assert-Reason 'disabled globally'
}

Invoke-TestCase 'per-event disable affects only that event' {
    Add-Config 'done_enabled' 'false'
    Invoke-Hook 'done' ''
    Assert-Silent
    Invoke-Hook 'waiting' ''
    Assert-Played 'waiting'
}

Invoke-TestCase 'quiet hours off ignores the window' {
    $env:BUZZER_FAKE_NOW = '23:30'
    Invoke-Hook 'done' ''
    Assert-Played 'done'
}

Invoke-TestCase 'quiet hours wrapping midnight: 23:30 is quiet' {
    Add-Config 'quiet_hours' 'true'
    $env:BUZZER_FAKE_NOW = '23:30'
    Invoke-Hook 'done' ''
    Assert-Silent
    Assert-Reason 'quiet hours'
}

Invoke-TestCase 'quiet hours wrapping midnight: 02:00 is quiet' {
    Add-Config 'quiet_hours' 'true'
    $env:BUZZER_FAKE_NOW = '02:00'
    Invoke-Hook 'done' ''
    Assert-Silent
}

Invoke-TestCase 'quiet hours wrapping midnight: 09:00 is not' {
    Add-Config 'quiet_hours' 'true'
    $env:BUZZER_FAKE_NOW = '09:00'
    Invoke-Hook 'done' ''
    Assert-Played 'done'
}

Invoke-TestCase 'quiet hours end boundary is awake' {
    Add-Config 'quiet_hours' 'true'
    $env:BUZZER_FAKE_NOW = '08:00'
    Invoke-Hook 'done' ''
    Assert-Played 'done'
    Clear-Played
    $env:BUZZER_FAKE_NOW = '07:59'
    Invoke-Hook 'done' ''
    Assert-Silent
}

Invoke-TestCase 'unknown focus plays' {
    $env:TERM_PROGRAM = 'vscode'
    $env:BUZZER_FAKE_FRONTMOST = '-'
    Invoke-Hook 'done' ''
    Assert-Played 'done'
}

Invoke-TestCase 'your terminal frontmost is silent' {
    $env:TERM_PROGRAM = 'vscode'
    $env:BUZZER_FAKE_FRONTMOST = 'Code'
    Invoke-Hook 'done' ''
    Assert-Silent
    Assert-Reason 'frontmost'
}

Invoke-TestCase 'another app frontmost plays' {
    $env:TERM_PROGRAM = 'vscode'
    $env:BUZZER_FAKE_FRONTMOST = 'chrome'
    Invoke-Hook 'done' ''
    Assert-Played 'done'
}

# The two snippets have to agree: a Windows user pasting this should get the
# same four events and the same non-blocking behaviour a macOS user gets.
# Mirrors "the hooks snippet covers every event" / "marks hooks async".
Invoke-TestCase 'the hooks snippet covers every event' {
    $out = Invoke-Cli 'hooks'
    foreach ($ev in @('UserPromptSubmit', 'Stop', 'StopFailure', 'Notification', 'SubagentStop')) {
        Assert-Contains "`"$ev`"" $out 'the hooks snippet'
    }
}

Invoke-TestCase 'the hooks snippet marks hooks async' {
    # Count inside the JSON block only. The prose around it discusses async too,
    # and a test that counts the explanation is measuring the wrong thing.
    $out = Invoke-Cli 'hooks'
    $start = $out.IndexOf("{`n")
    $end = $out.LastIndexOf("`n}")
    if ($start -lt 0 -or $end -le $start) {
        Add-Failure 'could not find a JSON block in the hooks snippet'
        return
    }
    $body = $out.Substring($start, $end - $start)
    $commands = ([regex]::Matches($body, '"type"\s*:\s*"command"')).Count
    $asyncs = ([regex]::Matches($body, '"async"\s*:\s*true')).Count
    Assert-Equal $commands $asyncs 'every command hook should be marked async'
}

# Get-ConfigInt validates the FORMAT (digits only) but not the RANGE, then hard
# casts. A digits-only value above Int32.MaxValue throws, the hook's catch-all
# swallows it, and the turn goes silent — a hand-typed extra zero turning into
# permanent silence is exactly the failure cardinal rule 3 forbids. An
# out-of-range value is invalid, so it must fall back to the default.
Invoke-TestCase 'an out-of-range threshold falls back instead of silencing' {
    Add-Config 'threshold_seconds' '99999999999'
    Set-Mark 'abc123' 120
    Invoke-Hook 'done' 'abc123'
    Assert-Played 'done'
}

# The issue template asks people to paste doctor output into a public bug
# report. Home paths carry the username along with it. Kept in step with the
# bash suite's "doctor leaks neither hostname nor home path".
Invoke-TestCase 'doctor abbreviates the home path' {
    Remove-Item Env:\BUZZER_HOME -ErrorAction SilentlyContinue
    $out = Invoke-Cli 'doctor'
    $env:BUZZER_HOME = $script:state
    if ($out -like "*$HOME*") {
        Add-Failure 'doctor prints the absolute home path; it should abbreviate to ~'
    }
    Assert-Contains '~' $out 'doctor state section'
}

# An app whose name merely contains a terminal's name is a different app.
# "Xcode" contains "code"; treating it as your terminal silences the buzzer at
# exactly the moment you had switched away and needed it. Kept in step with the
# bash suite's "a lookalike app name still plays".
Invoke-TestCase 'a lookalike app name still plays' {
    foreach ($pair in @(
            @('vscode', 'Xcode'),
            @('vscode', 'Barcode Scanner'),
            @('vscode', 'Codebook'),
            @('Apple_Terminal', 'Terminal Pro'),
            @('Hyper', 'Hyperion'),
            @('WarpTerminal', 'Warpinator'))) {
        Clear-Played
        $env:TERM_PROGRAM = $pair[0]
        $env:BUZZER_FAKE_FRONTMOST = $pair[1]
        Invoke-Hook 'done' ''
        if (-not (Get-PlayedContent)) {
            Add-Failure "TERM_PROGRAM=$($pair[0]) with $($pair[1]) frontmost is a different app and must play"
        }
    }
}

Invoke-TestCase 'unset TERM_PROGRAM plays' {
    $env:TERM_PROGRAM = ''
    $env:BUZZER_FAKE_FRONTMOST = 'WindowsTerminal'
    Invoke-Hook 'done' ''
    Assert-Played 'done'
}

Invoke-TestCase 'terminal_app override wins' {
    $env:TERM_PROGRAM = ''
    $env:BUZZER_FAKE_FRONTMOST = 'WindowsTerminal'
    Add-Config 'terminal_app' 'windowsterminal,alacritty'
    Invoke-Hook 'done' ''
    Assert-Silent
}

Invoke-TestCase 'rules short-circuit in the documented order' {
    Add-Config 'enabled' 'false'
    Add-Config 'quiet_hours' 'true'
    $env:BUZZER_FAKE_NOW = '23:30'
    $env:TERM_PROGRAM = 'vscode'
    $env:BUZZER_FAKE_FRONTMOST = 'Code'
    Set-Mark 'abc123' 1
    Invoke-Hook 'done' 'abc123'
    Assert-Reason 'disabled globally'
}

Invoke-TestCase 'hook prints nothing and exits 0' {
    Set-Mark 'abc123' 120
    $out = Invoke-Buzzer -Payload '{"session_id":"abc123"}' 'hook' 'done'
    Assert-Equal 0 $LASTEXITCODE 'hook exit code'
    Assert-Equal '' $out.Trim() 'hook output'
}

Invoke-TestCase 'mark prints nothing and exits 0' {
    $out = Invoke-Buzzer -Payload '{"session_id":"s1"}' 'mark'
    Assert-Equal 0 $LASTEXITCODE 'mark exit code'
    Assert-Equal '' $out.Trim() 'mark output'
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $script:state 'marks') 's1'))) {
        Add-Failure 'mark should have written marks/s1'
    }
}

Invoke-TestCase 'hook survives a broken config' {
    Set-Content -LiteralPath (Join-Path $script:state 'config') -Value "this is not`n[weird]"
    $out = Invoke-Buzzer -Payload '{"session_id":"x"}' 'hook' 'done'
    Assert-Equal 0 $LASTEXITCODE 'hook exit code'
    Assert-Equal '' $out.Trim() 'hook output'
}

Invoke-TestCase 'unknown event is silent and exits 0' {
    $out = Invoke-Buzzer -Payload '{"session_id":"x"}' 'hook' 'nonsense'
    Assert-Equal 0 $LASTEXITCODE 'hook exit code'
    Assert-Equal '' $out.Trim() 'hook output'
    Assert-Silent
}

Invoke-TestCase 'session id is sanitized' {
    Invoke-Buzzer -Payload '{"session_id":"../../../buzzer-escape"}' 'mark' | Out-Null
    $escaped = Join-Path ([IO.Path]::GetTempPath()) 'buzzer-escape'
    if (Test-Path -LiteralPath $escaped) {
        Remove-Item -LiteralPath $escaped -Force -ErrorAction SilentlyContinue
        Add-Failure 'a session id escaped the marks directory'
    }
    if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $script:state 'marks') 'buzzer-escape'))) {
        Add-Failure 'expected marks/buzzer-escape'
    }
}

Invoke-TestCase 'waiting plays twice' {
    Invoke-Hook 'waiting' ''
    Assert-Contains '|2|' (Get-PlayedContent) 'played record'
}

Invoke-TestCase 'subagent is quieter' {
    Invoke-Hook 'subagent' ''
    Assert-Contains '|0.35|' (Get-PlayedContent) 'played record'
}

Invoke-TestCase 'out-of-range volume falls back' {
    Add-Config 'volume' '11'
    Invoke-Hook 'done' ''
    Assert-Contains '|0.7|' (Get-PlayedContent) 'played record'
}

Invoke-TestCase 'status agrees with the hook' {
    Add-Config 'quiet_hours' 'true'
    $env:BUZZER_FAKE_NOW = '23:30'
    $status = Invoke-Cli 'status'
    Assert-Contains 'silent' $status 'status output'
    Assert-Contains 'quiet hours' $status 'status output'
    Invoke-Hook 'done' ''
    Assert-Silent
}

Invoke-TestCase 'set rejects an unknown event' {
    $out = Invoke-Cli 'set' 'nosuchevent' 'bird.wav'
    Assert-Contains 'done' $out 'error message'
    Assert-Contains 'subagent' $out 'error message'
}

Invoke-TestCase 'list shows every event' {
    $out = Invoke-Cli 'list'
    foreach ($e in @('done', 'waiting', 'error', 'subagent')) {
        Assert-Contains $e $out 'list output'
    }
}

Invoke-TestCase 'nothing ever writes settings.json' {
    $fakeHome = Join-Path $script:state 'fakehome'
    New-Item -ItemType Directory -Force -Path (Join-Path $fakeHome '.claude') | Out-Null
    $settings = Join-Path (Join-Path $fakeHome '.claude') 'settings.json'
    Set-Content -LiteralPath $settings -Value '{"model":"opus"}'
    $before = Get-Content -LiteralPath $settings -Raw
    $realHome = $env:HOME
    $env:HOME = $fakeHome
    try {
        Invoke-Cli 'on' | Out-Null
        Invoke-Cli 'hooks' | Out-Null
        Invoke-Cli 'status' | Out-Null
        Invoke-Cli 'doctor' | Out-Null
        Invoke-Buzzer -Payload '{"session_id":"x"}' 'mark' | Out-Null
        Invoke-Buzzer -Payload '{"session_id":"x"}' 'hook' 'done' | Out-Null
    } finally {
        $env:HOME = $realHome
    }
    Assert-Equal $before (Get-Content -LiteralPath $settings -Raw) 'settings.json contents'
}

Write-Host ''
if ($script:failed -eq 0) {
    Write-Host "all good: $script:passed passed" -ForegroundColor Green
    exit 0
}
Write-Host "failures: $script:passed passed, $script:failed failed" -ForegroundColor Red
foreach ($f in $script:failures) { Write-Host "  $f" -ForegroundColor Red }
exit 1
