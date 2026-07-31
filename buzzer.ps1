#!/usr/bin/env pwsh
<#
    agent-buzzer (Windows) — plays a sound when Claude Code finishes working,
    so you can look away from the terminal instead of babysitting it.

    This is the Windows port of buzzer.sh. It reads the same key=value config
    file and implements the same silence rules. macOS/Linux is the reference
    implementation; this side is less battle-tested.

    THREE RULES THAT OUTRANK EVERYTHING ELSE IN THIS FILE:

      1. NEVER BLOCK. Playback happens in a detached hidden process, so the
         hook returns while the sound is still playing.

      2. FAIL OPEN, NEVER FAIL LOUD. In hook mode any unexpected condition
         exits 0 and writes nothing to stdout/stderr, because errors printed
         into someone's Claude session are worse than a missed beep.
         Diagnostics go to the log file instead.

      3. WHEN SOMETHING IS UNKNOWN, PLAY. If focus can't be detected or the
         turn duration can't be measured, play the sound. A missed
         notification is a worse failure than one extra beep. Please do not
         "fix" this the other way around.

    No modules, no dependencies. Works on Windows PowerShell 5.1 and pwsh 7+.
#>

# Deliberately a *simple* script: one bare parameter, everything else read from
# $args. Adding [CmdletBinding()] or even a single [Parameter()] attribute turns
# this into an advanced script, and then
#
#     powershell -File buzzer.ps1 hook done   # with JSON on stdin
#
# fails outright with "the input object cannot be bound to any parameters",
# because PowerShell tries to bind stdin to a parameter and none accepts
# pipeline input. Hooks are always invoked exactly that way, so this matters
# more than the tidier signature.
param([string]$Command = 'help')

Set-StrictMode -Off

# Pipeline input, captured before anything else runs. Claude Code pipes hook
# JSON in through the real stdin of the process, which [Console]::In reads, but
# when this script is piped to from inside another PowerShell session the text
# arrives here instead. Support both.
$script:PipedInput = @($input)

# Commands report failure by setting this rather than returning a value,
# because a function that both prints and returns a number sends the number
# down the output stream along with the text.
$script:ExitCode = 0

$script:Version = '0.1.0'
$script:Events = @('done', 'waiting', 'error', 'subagent')
$script:LogKeep = 100
$script:LogMax = 140
$script:RepeatGapMs = 350

# Deliberately not under ~/.claude. Claude Code is the first agent supported,
# not the only one planned, and a Codex user should not have to create another
# tool's config directory to set up this one. Kept in step with buzzer.sh.
#
# BUZZER_HOME can be overridden, which is also how the tests run against a
# throwaway state directory instead of your real one.
$script:BuzzerHome = if ($env:BUZZER_HOME) { $env:BUZZER_HOME } else { Join-Path $HOME '.agent-buzzer' }
# Abbreviate $HOME to ~ in anything a user might paste somewhere public. The
# issue template asks for `buzzer doctor` output, and a home path hands over a
# username to anyone reading the thread. Mirrors tilde() in buzzer.sh.
function Get-TildePath {
    param([string]$Path)
    if (-not $Path -or -not $HOME) { return $Path }
    if ($Path -eq $HOME) { return '~' }
    if ($Path.StartsWith($HOME, [StringComparison]::OrdinalIgnoreCase)) {
        return '~' + $Path.Substring($HOME.Length)
    }
    return $Path
}

$script:ConfigFile = Join-Path $script:BuzzerHome 'config'
$script:MarksDir = Join-Path $script:BuzzerHome 'marks'
$script:LogFile = Join-Path $script:BuzzerHome 'log'
$script:ScriptDir = Split-Path -Parent $PSCommandPath
$script:DecisionReason = ''

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

function Write-BuzzerLog {
    param([string]$Message)
    try {
        if (-not (Test-Path -LiteralPath $script:BuzzerHome)) {
            New-Item -ItemType Directory -Force -Path $script:BuzzerHome | Out-Null
        }
        $stamp = (Get-Date).ToString('yyyy-MM-ddTHH:mm:ssK')
        Add-Content -LiteralPath $script:LogFile -Value "$stamp $Message" -Encoding UTF8

        # The log is a debugging aid, not an archive.
        $lines = @(Get-Content -LiteralPath $script:LogFile -ErrorAction Stop)
        if ($lines.Count -gt $script:LogMax) {
            $first = $lines.Count - $script:LogKeep
            $keep = $lines[$first..($lines.Count - 1)]
            Set-Content -LiteralPath $script:LogFile -Value $keep -Encoding UTF8
        }
    } catch {
        # Logging must never be the reason anything fails, and there is nowhere
        # left to report a failure to log.
        $null = $_
    }
}

# ---------------------------------------------------------------------------
# Config: plain key=value, one per line, '#' starts a comment.
# Same file and same keys as the bash version.
# ---------------------------------------------------------------------------

function Get-DefaultSound {
    # Windows has no sound set worth depending on, so every event defaults to
    # the bundled bird; the events differ by volume and repeat count instead.
    $bundled = Join-Path (Join-Path $script:BuzzerHome 'sounds') 'bird.wav'
    if (-not (Test-Path -LiteralPath $bundled)) {
        $repo = Join-Path (Join-Path $script:ScriptDir 'sounds') 'bird.wav'
        if (Test-Path -LiteralPath $repo) { return $repo }
    }
    return $bundled
}

function Write-DefaultConfig {
    New-Item -ItemType Directory -Force -Path $script:BuzzerHome | Out-Null
    New-Item -ItemType Directory -Force -Path $script:MarksDir | Out-Null

    $done = Get-DefaultSound
    $content = @"
# agent-buzzer config — plain key=value, one per line. '#' starts a comment.
# Edit by hand or use the CLI ("buzzer set", "buzzer volume", ...).
# Run "buzzer status" to see what is in effect and what would happen right now.

# Master switch.
enabled=true

# Turns shorter than this many seconds stay silent, so one-line chat replies
# don't beep. Only applies to 'done' and 'error'.
threshold_seconds=30

# Default playback volume, 0.0-1.0. Per-event overrides below win.
volume=0.7

# Quiet hours. Off by default. The window may wrap midnight (23:00 -> 08:00).
quiet_hours=false
quiet_start=23:00
quiet_end=08:00

# Which app counts as "your terminal", i.e. if it's frontmost you are already
# looking at Claude and don't need a sound. Empty = detect from TERM_PROGRAM.
# Accepts a comma-separated list of substrings, e.g. "code,windowsterminal".
terminal_app=

# done      — Claude finished its turn
# waiting   — Claude is blocked on a permission prompt or a question
# error     — the turn failed or was interrupted
# subagent  — a background/subagent task finished

done_enabled=true
done_sound=$done
done_volume=
done_repeat=1

waiting_enabled=true
waiting_sound=$done
waiting_volume=
waiting_repeat=2

error_enabled=true
error_sound=$done
error_volume=
error_repeat=1

subagent_enabled=true
subagent_sound=$done
subagent_volume=0.35
subagent_repeat=1
"@
    Set-Content -LiteralPath $script:ConfigFile -Value $content -Encoding UTF8
}

function Initialize-BuzzerConfig {
    try {
        if (-not (Test-Path -LiteralPath $script:MarksDir)) {
            New-Item -ItemType Directory -Force -Path $script:MarksDir | Out-Null
        }
        if (-not (Test-Path -LiteralPath $script:ConfigFile)) { Write-DefaultConfig }
        return $true
    } catch {
        return $false
    }
}

function Get-ConfigValue {
    param([string]$Key, [string]$Fallback = '')
    try {
        if (Test-Path -LiteralPath $script:ConfigFile) {
            $pattern = '^\s*' + [regex]::Escape($Key) + '\s*=\s*(.*)$'
            $value = $null
            foreach ($line in Get-Content -LiteralPath $script:ConfigFile) {
                $m = [regex]::Match($line, $pattern)
                if ($m.Success) { $value = $m.Groups[1].Value.Trim() }
            }
            if ($value) { return $value }
        }
    } catch {
        # An unreadable config behaves exactly like an absent one: defaults.
        # Not logged, because this runs once per key and would fill the log.
        $null = $_
    }
    return $Fallback
}

function Get-ConfigBool {
    param([string]$Key, [string]$Fallback)
    switch (([string](Get-ConfigValue $Key $Fallback)).Trim().ToLowerInvariant()) {
        'true' { return $true }
        '1' { return $true }
        'yes' { return $true }
        'on' { return $true }
        'false' { return $false }
        '0' { return $false }
        'no' { return $false }
        'off' { return $false }
        default { return ($Fallback -eq 'true') }
    }
}

function Get-ConfigInt {
    param([string]$Key, [int]$Fallback)
    $raw = Get-ConfigValue $Key ''
    # The regex checks the format; it cannot check the range. A digits-only
    # value above Int32.MaxValue makes a hard [int] cast throw, and in hook mode
    # that exception is swallowed by the catch-all and comes out as silence —
    # one stray keystroke in a hand-edited config turning the buzzer off for
    # good. TryParse fails instead of throwing, so it falls back like any other
    # invalid value.
    $parsed = 0
    if ($raw -match '^[0-9]+$' -and [int]::TryParse($raw, [ref]$parsed)) {
        return $parsed
    }
    return $Fallback
}

function Test-VolumeValue {
    param([string]$Value)
    if ($Value -notmatch '^[0-9]*\.?[0-9]+$') { return $false }
    $v = [double]$Value
    return ($v -ge 0 -and $v -le 1)
}

function Get-EventVolume {
    param([string]$EventName)
    $v = Get-ConfigValue "${EventName}_volume" ''
    if (Test-VolumeValue $v) { return $v }
    $v = Get-ConfigValue 'volume' '0.7'
    if (Test-VolumeValue $v) { return $v }
    return '0.7'
}

function Set-ConfigValue {
    param([string]$Key, [string]$Value)
    try {
        if (-not (Initialize-BuzzerConfig)) { return $false }
        $pattern = '^\s*' + [regex]::Escape($Key) + '\s*='
        $written = $false
        $out = New-Object System.Collections.Generic.List[string]
        foreach ($line in Get-Content -LiteralPath $script:ConfigFile) {
            if ($line -match $pattern) {
                if (-not $written) {
                    $out.Add("$Key=$Value")
                    $written = $true
                }
                continue
            }
            $out.Add($line)
        }
        if (-not $written) { $out.Add("$Key=$Value") }
        Set-Content -LiteralPath $script:ConfigFile -Value $out -Encoding UTF8
        return $true
    } catch {
        return $false
    }
}

function Test-EventName {
    param([string]$Name)
    return ($script:Events -contains $Name)
}

# $IsWindows only exists in PowerShell 6+, so fall back to $env:OS for 5.1.
function Test-WindowsHost {
    return ([bool]$IsWindows -or $env:OS -eq 'Windows_NT')
}

function Get-PlatformLabel {
    $version = [Environment]::OSVersion.VersionString
    if (Test-WindowsHost) { return "windows ($version)" }
    return "$version — NOT Windows; buzzer.sh is the implementation for this platform"
}

# Booleans as the config file spells them, so status and config agree.
function Format-Bool {
    param([bool]$Value)
    if ($Value) { return 'true' }
    return 'false'
}

function Test-EventNameLoud {
    param([string]$Name)
    if (Test-EventName $Name) { return $true }
    Write-Error "unknown event '$Name'. Valid events: $($script:Events -join ', ')"
    return $false
}

# ---------------------------------------------------------------------------
# Hook payload
# ---------------------------------------------------------------------------

function Read-HookPayload {
    try {
        if ([Console]::IsInputRedirected) {
            $text = [Console]::In.ReadToEnd()
            if ($text) { return $text }
        }
    } catch {
        # No usable stdin is fine: it just means "duration unknown" later, which
        # plays rather than staying silent.
        Write-BuzzerLog "stdin unreadable: $_"
    }
    if ($script:PipedInput -and $script:PipedInput.Count -gt 0) {
        return ($script:PipedInput -join "`n")
    }
    return ''
}

function Get-JsonString {
    param([string]$Key, [string]$Payload)
    if (-not $Payload) { return '' }
    $m = [regex]::Match($Payload, '"' + [regex]::Escape($Key) + '"\s*:\s*"([^"]*)"')
    if ($m.Success) { return $m.Groups[1].Value }
    return ''
}

# A session id becomes a filename, so allow only [A-Za-z0-9_-].
function Get-SafeId {
    param([string]$Value)
    if (-not $Value) { return '' }
    $clean = ($Value -replace '[^A-Za-z0-9_-]', '')
    if ($clean.Length -gt 128) { $clean = $clean.Substring(0, 128) }
    return $clean
}

function Get-EpochSecond {
    return ([DateTimeOffset]::UtcNow).ToUnixTimeSeconds()
}

# BUZZER_FAKE_NOW ("HH:MM") exists so the quiet-hours tests don't have to wait
# until 23:00 to run.
function Get-NowHhmm {
    if ($env:BUZZER_FAKE_NOW) { return $env:BUZZER_FAKE_NOW }
    return (Get-Date).ToString('HH:mm')
}

function Get-MinuteOfDay {
    param([string]$Hhmm)
    $m = [regex]::Match([string]$Hhmm, '^([0-9]{1,2}):([0-9]{2})$')
    if (-not $m.Success) { return -1 }
    $h = [int]$m.Groups[1].Value
    $min = [int]$m.Groups[2].Value
    if ($h -gt 23 -or $min -gt 59) { return -1 }
    return ($h * 60 + $min)
}

# Anything unparseable answers $false (not quiet), because failing towards
# "play" is the safe direction.
function Test-QuietWindow {
    param([string]$Now, [string]$From, [string]$To)
    $n = Get-MinuteOfDay $Now
    $f = Get-MinuteOfDay $From
    $t = Get-MinuteOfDay $To
    if ($n -lt 0 -or $f -lt 0 -or $t -lt 0) { return $false }
    if ($f -eq $t) { return $false }
    if ($f -lt $t) { return ($n -ge $f -and $n -lt $t) }
    # Wraps midnight, e.g. 23:00-08:00: inside if after 'from' OR before 'to'.
    return ($n -ge $f -or $n -lt $t)
}

# ---------------------------------------------------------------------------
# Turn duration
# ---------------------------------------------------------------------------

function Get-MarkPath {
    param([string]$SessionId)
    $id = Get-SafeId $SessionId
    if (-not $id) { return $null }
    return (Join-Path $script:MarksDir $id)
}

# Returns elapsed seconds, or $null when unknown. Unknown means PLAY.
function Get-TurnElapsed {
    param([string]$Payload)
    try {
        $path = Get-MarkPath (Get-JsonString 'session_id' $Payload)
        if (-not $path -or -not (Test-Path -LiteralPath $path)) { return $null }
        $raw = (Get-Content -LiteralPath $path -TotalCount 1) -replace '[^0-9]', ''
        if (-not $raw) { return $null }
        $elapsed = (Get-EpochSecond) - [int64]$raw
        if ($elapsed -lt 0) { return $null }
        return [int64]$elapsed
    } catch {
        return $null
    }
}

function Remove-StaleMark {
    try {
        if (-not (Test-Path -LiteralPath $script:MarksDir)) { return }
        $cutoff = (Get-Date).AddDays(-1)
        Get-ChildItem -LiteralPath $script:MarksDir -File -ErrorAction SilentlyContinue |
            Where-Object { $_.LastWriteTime -lt $cutoff } |
            Remove-Item -Force -ErrorAction SilentlyContinue
    } catch {
        # Housekeeping is never worth an error.
        Write-BuzzerLog "could not prune old marks: $_"
    }
}

# ---------------------------------------------------------------------------
# Focus detection
#
# Returns the frontmost process name, or '' when it cannot be determined.
# Empty means UNKNOWN, and unknown means PLAY.
# ---------------------------------------------------------------------------

function Get-FrontmostApp {
    # Test/debug override. The single value "-" means "pretend focus could not
    # be detected", which is how the tests cover the unknown-focus path.
    if ($env:BUZZER_FAKE_FRONTMOST -eq '-') { return '' }
    if ($env:BUZZER_FAKE_FRONTMOST) { return $env:BUZZER_FAKE_FRONTMOST }
    try {
        if (-not ('BuzzerWin32' -as [type])) {
            Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class BuzzerWin32 {
    [DllImport("user32.dll")]
    public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll", SetLastError = true)]
    public static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);
}
'@ -ErrorAction Stop
        }
        $handle = [BuzzerWin32]::GetForegroundWindow()
        if ($handle -eq [IntPtr]::Zero) { return '' }
        $ownerId = [uint32]0
        [void][BuzzerWin32]::GetWindowThreadProcessId($handle, [ref]$ownerId)
        if ($ownerId -eq 0) { return '' }
        $proc = Get-Process -Id $ownerId -ErrorAction Stop
        return $proc.ProcessName
    } catch {
        # Unknown focus. Which means PLAY.
        return ''
    }
}

function Get-NormalizedAppName {
    param([string]$Name)
    if (-not $Name) { return '' }
    return ($Name -replace '\.app$', '' -replace '\.exe$', '').Trim().ToLowerInvariant()
}

# Which frontmost names count as "the terminal I am running in". An empty list
# means we have no idea, which means PLAY.
function Get-TerminalCandidate {
    $override = Get-ConfigValue 'terminal_app' ''
    if ($override) {
        return @($override -split ',' | ForEach-Object { $_.Trim().ToLowerInvariant() } | Where-Object { $_ })
    }
    switch (Get-NormalizedAppName $env:TERM_PROGRAM) {
        'vscode' { return @('code', 'cursor', 'windsurf', 'vscodium') }
        'windows_terminal' { return @('windowsterminal') }
        'wezterm' { return @('wezterm') }
        'hyper' { return @('hyper') }
        'warpterminal' { return @('warp') }
        'ghostty' { return @('ghostty') }
        'alacritty' { return @('alacritty') }
        # tmux tells us nothing about the outer terminal, and an unset or
        # unrecognized TERM_PROGRAM is the same situation: unknown -> PLAY.
        default { return @() }
    }
}

function Test-TerminalFrontmost {
    param([string]$Frontmost)
    $front = Get-NormalizedAppName $Frontmost
    if (-not $front) { return $false }
    # Exact match, never a substring. "Xcode" contains "code", and a substring
    # match silenced the buzzer whenever you flipped from your editor to Xcode —
    # precisely when you had looked away and needed the sound. Failing to
    # recognise your terminal costs one extra beep; a false match costs silence.
    # Kept identical to terminal_is_frontmost in buzzer.sh.
    foreach ($cand in Get-TerminalCandidate) {
        if ($cand -and $front -eq $cand) { return $true }
    }
    return $false
}

# ---------------------------------------------------------------------------
# Audio
# ---------------------------------------------------------------------------

function Test-AudioBackend {
    # MediaPlayer handles mp3 + wav; SoundPlayer is the WAV-only fallback.
    try {
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        return 'MediaPlayer'
    } catch {
        return 'SoundPlayer'
    }
}

# Fire and forget: playback happens in a detached hidden process so this
# returns immediately no matter how long the sound is.
function Start-SoundPlayback {
    param(
        [string]$EventName,
        [string]$Path,
        [string]$Volume,
        [int]$Repeat
    )

    if (-not $Path) {
        Write-BuzzerLog "skip ${EventName}: no sound configured"
        return $false
    }
    if (-not (Test-Path -LiteralPath $Path)) {
        Write-BuzzerLog "skip ${EventName}: sound not found: $Path"
        return $false
    }
    $backend = Test-AudioBackend

    # BUZZER_DRY_RUN records what would have played instead of playing it. The
    # test suite reads this file; it is also handy when debugging remotely.
    # It records the intent even where audio is unavailable, because the
    # silence rules are what it exists to check.
    if ($env:BUZZER_DRY_RUN) {
        try {
            New-Item -ItemType Directory -Force -Path $script:BuzzerHome | Out-Null
            Add-Content -LiteralPath (Join-Path $script:BuzzerHome 'played') `
                -Value "$EventName|$Path|$Volume|$Repeat|$backend" -Encoding UTF8
        } catch {
            Write-BuzzerLog "could not write the dry-run record: $_"
        }
        Write-BuzzerLog "dry-run ${EventName}: $backend $Path vol=$Volume repeat=$Repeat"
        return $true
    }

    $child = @"
`$ErrorActionPreference = 'SilentlyContinue'
`$path = '$($Path.Replace("'", "''"))'
`$vol = [double]$Volume
for (`$i = 0; `$i -lt $Repeat; `$i++) {
    if (`$i -gt 0) { Start-Sleep -Milliseconds $script:RepeatGapMs }
    try {
        Add-Type -AssemblyName PresentationCore -ErrorAction Stop
        `$p = New-Object System.Windows.Media.MediaPlayer
        `$p.Open([uri]`$path)
        `$spin = 0
        while (-not `$p.NaturalDuration.HasTimeSpan -and `$spin -lt 50) {
            Start-Sleep -Milliseconds 40
            `$spin++
        }
        `$p.Volume = `$vol
        `$p.Play()
        if (`$p.NaturalDuration.HasTimeSpan) {
            Start-Sleep -Milliseconds ([int]`$p.NaturalDuration.TimeSpan.TotalMilliseconds + 250)
        } else {
            Start-Sleep -Seconds 3
        }
        `$p.Close()
    } catch {
        # WAV-only fallback.
        try { (New-Object System.Media.SoundPlayer `$path).PlaySync() } catch { }
    }
}
"@
    try {
        $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($child))
        $psExe = if ($PSVersionTable.PSEdition -eq 'Core') { 'pwsh' } else { 'powershell' }
        Start-Process -FilePath $psExe `
            -ArgumentList '-NoProfile', '-NonInteractive', '-EncodedCommand', $encoded `
            -WindowStyle Hidden | Out-Null
        Write-BuzzerLog "play ${EventName}: $backend $Path vol=$Volume repeat=$Repeat"
        return $true
    } catch {
        Write-BuzzerLog "skip ${EventName}: could not start playback process"
        return $false
    }
}

# ---------------------------------------------------------------------------
# The silence rules
#
# This is the whole point of the tool, and it is also what `status` reports on,
# so what status says is by construction what the hook actually does.
# Returns $true to play; sets $script:DecisionReason either way.
# ---------------------------------------------------------------------------

function Test-ShouldPlay {
    param([string]$EventName, [string]$Payload = '')
    $script:DecisionReason = ''

    # 1. Global switch.
    if (-not (Get-ConfigBool 'enabled' 'true')) {
        $script:DecisionReason = 'disabled globally (enabled=false)'
        return $false
    }

    # 1b. Per-event switch.
    if (-not (Get-ConfigBool "${EventName}_enabled" 'true')) {
        $script:DecisionReason = "event '$EventName' is off (${EventName}_enabled=false)"
        return $false
    }

    # 2. Quiet hours. Off by default.
    if (Get-ConfigBool 'quiet_hours' 'false') {
        $from = Get-ConfigValue 'quiet_start' '23:00'
        $to = Get-ConfigValue 'quiet_end' '08:00'
        $now = Get-NowHhmm
        if (Test-QuietWindow $now $from $to) {
            $script:DecisionReason = "quiet hours ($from-$to, now $now)"
            return $false
        }
    }

    # 3. Short turns stay silent. 'waiting' and 'subagent' are not
    #    turn-scoped, so this rule does not apply to them at all.
    if ($EventName -eq 'done' -or $EventName -eq 'error') {
        $threshold = Get-ConfigInt 'threshold_seconds' 30
        $elapsed = Get-TurnElapsed $Payload
        if ($null -eq $elapsed) {
            # Duration unknown -> PLAY. Missing information must never cause a
            # missed notification.
        } elseif ($elapsed -lt $threshold) {
            $script:DecisionReason = "turn too short (${elapsed}s < ${threshold}s)"
            return $false
        }
    }

    # 4. You are already looking at it.
    $front = Get-FrontmostApp
    if ($front -and (Test-TerminalFrontmost $front)) {
        $script:DecisionReason = "your terminal is frontmost ($front)"
        return $false
    }

    # 5. Play.
    $script:DecisionReason = 'all rules passed'
    return $true
}

# ---------------------------------------------------------------------------
# Hook mode
# ---------------------------------------------------------------------------

function Invoke-MarkCommand {
    # Structural guarantee for rule 2: nothing here prints, and every path
    # exits 0.
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        [void](Initialize-BuzzerConfig)
        $payload = Read-HookPayload
        $id = Get-SafeId (Get-JsonString 'session_id' $payload)
        if (-not $id) {
            # Without a session id the done hook finds no mark, which reads as
            # "duration unknown", which plays. That is the correct fallback.
            Write-BuzzerLog 'mark: no session_id in payload'
            exit 0
        }
        New-Item -ItemType Directory -Force -Path $script:MarksDir | Out-Null
        Set-Content -LiteralPath (Join-Path $script:MarksDir $id) -Value (Get-EpochSecond) -Encoding ASCII
        Write-BuzzerLog "mark: $id"
        Remove-StaleMark
    } catch {
        # Fail open, silently: the log is the only place this may surface.
        Write-BuzzerLog "mark failed: $_"
    }
    exit 0
}

function Invoke-HookCommand {
    param([string]$EventName)
    $ErrorActionPreference = 'SilentlyContinue'
    try {
        if (-not (Test-EventName $EventName)) {
            Write-BuzzerLog "hook: unknown event '$EventName'"
            exit 0
        }
        [void](Initialize-BuzzerConfig)
        $payload = Read-HookPayload

        if (Test-ShouldPlay $EventName $payload) {
            Write-BuzzerLog "decision=play event=$EventName reason=`"$script:DecisionReason`""
            $sound = Get-ConfigValue "${EventName}_sound" (Get-DefaultSound)
            $volume = Get-EventVolume $EventName
            $repeat = Get-ConfigInt "${EventName}_repeat" 1
            if ($repeat -lt 1) { $repeat = 1 }
            [void](Start-SoundPlayback -EventName $EventName -Path $sound -Volume $volume -Repeat $repeat)
        } else {
            Write-BuzzerLog "decision=silent event=$EventName reason=`"$script:DecisionReason`""
        }

        # The turn is over, so the mark has done its job.
        if ($EventName -eq 'done' -or $EventName -eq 'error') {
            $path = Get-MarkPath (Get-JsonString 'session_id' $payload)
            if ($path -and (Test-Path -LiteralPath $path)) {
                Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
            }
        }
    } catch {
        # Fail open, silently: the log is the only place this may surface.
        Write-BuzzerLog "hook failed: $_"
    }
    exit 0
}

# ---------------------------------------------------------------------------
# CLI mode
# ---------------------------------------------------------------------------

# Accepts a path, a bundled sound name ("bird.wav"), or a Windows Media name
# ("chimes"). Returns the resolved full path, or $null.
function Resolve-SoundPath {
    param([string]$Value)
    if (-not $Value) { return $null }
    $candidates = @(
        $Value,
        (Join-Path (Join-Path $script:BuzzerHome 'sounds') $Value),
        (Join-Path (Join-Path $script:ScriptDir 'sounds') $Value),
        (Join-Path (Join-Path (Join-Path $script:ScriptDir 'sounds') 'community') $Value)
    )
    if ($env:SystemRoot) {
        $media = Join-Path $env:SystemRoot 'Media'
        $candidates += (Join-Path $media $Value)
        $candidates += (Join-Path $media "$Value.wav")
    }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) {
            return (Resolve-Path -LiteralPath $c).Path
        }
    }
    return $null
}

function Show-EventList {
    [void](Initialize-BuzzerConfig)
    $rows = @('{0,-9}  {1,-3}  {2,-6}  {3,-3}  {4}' -f 'EVENT', 'ON', 'VOLUME', 'REP', 'SOUND')
    foreach ($e in $script:Events) {
        $sound = Get-ConfigValue "${e}_sound" (Get-DefaultSound)
        if ($sound -and -not (Test-Path -LiteralPath $sound)) { $sound = "$sound  (MISSING)" }
        $on = if (Get-ConfigBool "${e}_enabled" 'true') { 'yes' } else { 'no' }
        $rows += ('{0,-9}  {1,-3}  {2,-6}  {3,-3}  {4}' -f $e, $on, (Get-EventVolume $e), (Get-ConfigInt "${e}_repeat" 1), $sound)
    }
    if (-not (Get-ConfigBool 'enabled' 'true')) {
        $rows += ''
        $rows += 'All sounds are off: enabled=false. Turn them back on with "buzzer on".'
    }
    Write-Output $rows
}

function Set-EventSound {
    param([string]$EventName, [string]$Value)
    if (-not (Test-EventNameLoud $EventName)) {
        $script:ExitCode = 1
        return
    }
    $path = Resolve-SoundPath $Value
    if (-not $path) {
        Write-Error "no such sound: $Value (tried it as a path, a bundled sound, and a Windows Media sound)"
        $script:ExitCode = 1
        return
    }
    if (-not (Set-ConfigValue "${EventName}_sound" $path)) {
        Write-Error "could not write $script:ConfigFile"
        $script:ExitCode = 1
        return
    }
    Write-Output "$EventName -> $path"
}

function Invoke-TestSound {
    param([string]$EventName)
    if (-not $EventName) { $EventName = 'done' }
    if (-not (Test-EventNameLoud $EventName)) {
        $script:ExitCode = 1
        return
    }
    [void](Initialize-BuzzerConfig)
    $sound = Get-ConfigValue "${EventName}_sound" (Get-DefaultSound)
    $volume = Get-EventVolume $EventName
    $repeat = Get-ConfigInt "${EventName}_repeat" 1
    Write-Output "playing ${EventName}: $sound (volume $volume, ${repeat}x)"
    Write-Output 'This bypasses every silence rule. Use "buzzer status" to see what a real hook would do.'
    if (-not (Start-SoundPlayback -EventName $EventName -Path $sound -Volume $volume -Repeat $repeat)) {
        Write-Error "could not play it — run 'buzzer.ps1 doctor'"
        $script:ExitCode = 1
    }
}

function Show-Status {
    [void](Initialize-BuzzerConfig)
    $out = New-Object System.Collections.Generic.List[string]
    $out.Add("agent-buzzer $script:Version")
    $out.Add("config      $(Get-TildePath $script:ConfigFile)")
    $out.Add("log         $(Get-TildePath $script:LogFile)")
    $out.Add("platform    $(Get-PlatformLabel), PowerShell $($PSVersionTable.PSVersion)")
    $out.Add('')
    $out.Add("enabled            $(Format-Bool (Get-ConfigBool 'enabled' 'true'))")
    $out.Add("threshold_seconds  $(Get-ConfigInt 'threshold_seconds' 30)")
    $out.Add("volume             $(Get-ConfigValue 'volume' '0.7')")
    if (Get-ConfigBool 'quiet_hours' 'false') {
        $from = Get-ConfigValue 'quiet_start' '23:00'
        $to = Get-ConfigValue 'quiet_end' '08:00'
        $now = Get-NowHhmm
        $where = if (Test-QuietWindow $now $from $to) { 'inside' } else { 'outside' }
        $out.Add("quiet_hours        on, $from-$to (now $now, $where)")
    } else {
        $out.Add('quiet_hours        off')
    }
    $out.Add('')
    $termProgram = if ($env:TERM_PROGRAM) { $env:TERM_PROGRAM } else { '<unset>' }
    $out.Add("TERM_PROGRAM       $termProgram")
    $candidates = Get-TerminalCandidate
    if ($candidates.Count -gt 0) {
        $out.Add("your terminal      $($candidates -join ' ')")
    } else {
        $out.Add('your terminal      unknown -> the "already looking at it" rule can never fire, so sounds play')
    }
    $front = Get-FrontmostApp
    if ($front) {
        $suffix = if (Test-TerminalFrontmost $front) { '  (that IS your terminal)' } else { '  (not your terminal)' }
        $out.Add("frontmost app      $front$suffix")
    } else {
        $out.Add('frontmost app      unknown -> treated as "not frontmost", so sounds play')
    }
    $out.Add('')
    $out.Add('would it play right now?')
    foreach ($e in $script:Events) {
        $verdict = if (Test-ShouldPlay $e '') { 'PLAY' } else { 'silent' }
        $out.Add(('  {0,-9} {1,-7} {2}' -f $e, $verdict, $script:DecisionReason))
    }
    $out.Add('')
    $out.Add('Note: outside a real hook there is no session_id, so turn duration is')
    $out.Add('unknown here and the short-turn rule cannot fire. In a real turn it can.')
    Write-Output $out
}

function Show-Doctor {
    [void](Initialize-BuzzerConfig)
    $problems = 0
    $warnings = 0
    $out = New-Object System.Collections.Generic.List[string]

    $out.Add("agent-buzzer $script:Version — doctor")
    $out.Add('')
    $out.Add('[platform]')
    $out.Add("  os              $(Get-PlatformLabel)")
    $out.Add("  powershell      $($PSVersionTable.PSVersion) ($($PSVersionTable.PSEdition))")
    $termProgram = if ($env:TERM_PROGRAM) { $env:TERM_PROGRAM } else { '<unset>' }
    $out.Add("  TERM_PROGRAM    $termProgram")
    $out.Add('')

    $out.Add('[state]')
    $out.Add("  home            $(Get-TildePath $script:BuzzerHome)")
    if (Test-Path -LiteralPath $script:ConfigFile) {
        $out.Add("  config          $(Get-TildePath $script:ConfigFile)")
    } else {
        $out.Add("  config          $(Get-TildePath $script:ConfigFile) (MISSING)")
        $problems++
    }
    if (Test-Path -LiteralPath $script:MarksDir) {
        $count = @(Get-ChildItem -LiteralPath $script:MarksDir -File -ErrorAction SilentlyContinue).Count
        $out.Add("  marks           $(Get-TildePath $script:MarksDir) ($count present)")
    } else {
        $out.Add("  marks           $(Get-TildePath $script:MarksDir) (MISSING — turn duration always unknown, so everything plays)")
        $warnings++
    }
    $out.Add('')

    $out.Add('[audio]')
    $backend = Test-AudioBackend
    if ($backend -eq 'MediaPlayer') {
        $out.Add('  backend         System.Windows.Media.MediaPlayer (wav + mp3)')
    } else {
        $out.Add('  backend         System.Media.SoundPlayer (WAV ONLY — mp3 sounds will not play)')
        $warnings++
    }
    $out.Add('')

    $out.Add('[sounds]')
    foreach ($e in $script:Events) {
        $sound = Get-ConfigValue "${e}_sound" (Get-DefaultSound)
        if (-not $sound) {
            $out.Add(('  {0,-9}      NOT SET' -f $e))
            $problems++
        } elseif (-not (Test-Path -LiteralPath $sound)) {
            $out.Add(('  {0,-9}      MISSING: {1}' -f $e, $sound))
            $problems++
        } elseif ($backend -eq 'SoundPlayer' -and [IO.Path]::GetExtension($sound).ToLowerInvariant() -ne '.wav') {
            $out.Add(('  {0,-9}      UNPLAYABLE (SoundPlayer is WAV-only): {1}' -f $e, $sound))
            $problems++
        } else {
            $out.Add(('  {0,-9}      ok: {1}' -f $e, $sound))
        }
    }
    $out.Add('')

    $out.Add('[focus detection]')
    $out.Add('  method          GetForegroundWindow + GetWindowThreadProcessId')
    $front = Get-FrontmostApp
    if ($front) {
        $out.Add("  frontmost now   $front")
        $isYou = if (Test-TerminalFrontmost $front) { 'yes -> sounds suppressed while it is focused' } else { 'no -> sounds play' }
        $out.Add("  is that you?    $isYou")
    } else {
        $out.Add('  frontmost now   UNKNOWN')
        $out.Add('  effect          unknown always means PLAY, so you get an extra beep, never silence')
        $warnings++
    }
    $out.Add('')

    $out.Add('[hooks]')
    $out.Add('  buzzer never edits settings.json. Run "buzzer hooks" for the snippet')
    $out.Add('  and add it yourself via /hooks.')
    $settings = Join-Path $HOME '.claude\settings.json'
    if (Test-Path -LiteralPath $settings) {
        if (Select-String -LiteralPath $settings -Pattern 'buzzer' -Quiet -ErrorAction SilentlyContinue) {
            $out.Add('  settings.json   mentions buzzer — looks wired up')
        } else {
            $out.Add('  settings.json   exists but does not mention buzzer — hooks probably not wired up yet')
            $warnings++
        }
    } else {
        $out.Add('  settings.json   not found — hooks are not wired up yet')
        $warnings++
    }
    $out.Add('')

    if ($problems -gt 0) {
        $out.Add("RESULT: $problems problem(s), $warnings warning(s). Sounds may not play.")
        $script:ExitCode = 1
    } else {
        $out.Add("RESULT: no problems, $warnings warning(s).")
    }
    Write-Output $out
}

function Show-HookSnippet {
    $self = $PSCommandPath
    Write-Output @"
Add this to $HOME\.claude\settings.json yourself — buzzer will never write that
file. The safest route is Claude Code's /hooks command; a malformed
settings.json silently disables every setting in it.

{
  "hooks": {
    "UserPromptSubmit": [
      { "hooks": [ { "type": "command", "async": true, "command": "powershell -NoProfile -File \"$self\" mark" } ] }
    ],
    "Stop": [
      { "hooks": [ { "type": "command", "async": true, "command": "powershell -NoProfile -File \"$self\" hook done" } ] }
    ],
    "StopFailure": [
      { "hooks": [ { "type": "command", "async": true, "command": "powershell -NoProfile -File \"$self\" hook error" } ] }
    ],
    "Notification": [
      { "hooks": [ { "type": "command", "async": true, "command": "powershell -NoProfile -File \"$self\" hook waiting" } ] }
    ],
    "SubagentStop": [
      { "hooks": [ { "type": "command", "async": true, "command": "powershell -NoProfile -File \"$self\" hook subagent" } ] }
    ]
  }
}

UserPromptSubmit is what makes the short-turn rule work: it records when the
turn started. Without it every turn counts as "duration unknown" and plays.

"async": true keeps the hook off the turn's critical path, so Claude never
waits on it even if something below it misbehaves.

StopFailure is what fires the 'error' sound when a turn fails or is
interrupted. If your Claude Code build does not know that event name it will
say so when you add it, and you can drop that one block; the other four are
independent.
"@
}

function Show-Usage {
    Write-Output @'
agent-buzzer — a sound when Claude Code finishes, so you can look away.

  buzzer.ps1 list                     what plays for which event
  buzzer.ps1 set <event> <path>       change a sound
  buzzer.ps1 test <event>             play it now, ignoring every silence rule
  buzzer.ps1 on | off                 master switch
  buzzer.ps1 enable | disable <event> per-event switch
  buzzer.ps1 threshold <seconds>      short-turn cutoff (default 30)
  buzzer.ps1 quiet-hours <from> <to>  e.g. quiet-hours 23:00 08:00
  buzzer.ps1 quiet-hours off
  buzzer.ps1 volume <0.0-1.0> [event]
  buzzer.ps1 sounds                   list sounds available on this machine
  buzzer.ps1 status                   effective config + would it play right now, and if not why
  buzzer.ps1 doctor                   audio backend, focus detection, missing files
  buzzer.ps1 hooks                    print the settings.json snippet to add yourself
  buzzer.ps1 log                      recent decisions
  buzzer.ps1 config [key] [value]     read or write config directly
  buzzer.ps1 version

Events: done, waiting, error, subagent

Used by Claude Code, not by you:
  buzzer.ps1 mark                     records when a turn started (UserPromptSubmit)
  buzzer.ps1 hook <event>             runs the silence rules and plays

Nothing here ever writes settings.json.
'@
}

function Show-SoundList {
    $found = $false
    $mediaDir = Join-Path $env:SystemRoot 'Media'
    if (Test-Path -LiteralPath $mediaDir) {
        Write-Output "Windows sounds ($mediaDir):"
        foreach ($f in Get-ChildItem -LiteralPath $mediaDir -Filter '*.wav' -ErrorAction SilentlyContinue) {
            Write-Output "  $($f.BaseName)"
            $found = $true
        }
    }
    foreach ($dir in @((Join-Path $script:BuzzerHome 'sounds'), (Join-Path $script:ScriptDir 'sounds'), (Join-Path (Join-Path $script:ScriptDir 'sounds') 'community'))) {
        if (-not (Test-Path -LiteralPath $dir)) { continue }
        # -Include needs -Recurse or a wildcard path to do anything, so filter
        # on the extension instead.
        $files = @(Get-ChildItem -LiteralPath $dir -File -ErrorAction SilentlyContinue |
                Where-Object { $_.Extension -in '.wav', '.mp3', '.aiff', '.m4a' })
        if ($files.Count -eq 0) { continue }
        Write-Output ''
        Write-Output "${dir}:"
        foreach ($f in $files) {
            Write-Output "  $($f.Name)"
            $found = $true
        }
    }
    if (-not $found) { Write-Output 'No sounds found. Pass "set <event> <path>" a file directly.' }
    Write-Output ''
    Write-Output 'Use any of these by name: buzzer.ps1 set done bird.wav'
}

function Set-QuietHour {
    param([string]$From, [string]$To)
    [void](Initialize-BuzzerConfig)
    if ($From -in @('off', 'false', 'none')) {
        [void](Set-ConfigValue 'quiet_hours' 'false')
        Write-Output 'quiet hours off'
        return
    }
    if ($From -in @('on', 'true')) {
        [void](Set-ConfigValue 'quiet_hours' 'true')
        Write-Output "quiet hours on ($(Get-ConfigValue 'quiet_start' '23:00')-$(Get-ConfigValue 'quiet_end' '08:00'))"
        return
    }
    if ((Get-MinuteOfDay $From) -lt 0 -or (Get-MinuteOfDay $To) -lt 0) {
        Write-Error 'usage: buzzer.ps1 quiet-hours <from> <to>   (e.g. 23:00 08:00), or quiet-hours off'
        $script:ExitCode = 1
        return
    }
    [void](Set-ConfigValue 'quiet_start' $From)
    [void](Set-ConfigValue 'quiet_end' $To)
    [void](Set-ConfigValue 'quiet_hours' 'true')
    $wrap = if ((Get-MinuteOfDay $From) -gt (Get-MinuteOfDay $To)) { ' (wraps midnight)' } else { '' }
    Write-Output "quiet hours on: $From-$To$wrap"
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------

$rest = @($args)
$arg0 = if ($rest.Count -ge 1) { [string]$rest[0] } else { '' }
$arg1 = if ($rest.Count -ge 2) { [string]$rest[1] } else { '' }

switch ($Command.ToLowerInvariant()) {
    'mark' { Invoke-MarkCommand }
    'hook' { Invoke-HookCommand $arg0 }
    'list' { Show-EventList }
    'set' { Set-EventSound $arg0 $arg1 }
    'test' { Invoke-TestSound $arg0 }
    'on' {
        [void](Initialize-BuzzerConfig)
        [void](Set-ConfigValue 'enabled' 'true')
        Write-Output 'buzzer is on'
    }
    'off' {
        [void](Initialize-BuzzerConfig)
        [void](Set-ConfigValue 'enabled' 'false')
        Write-Output 'buzzer is off — no event will play until "buzzer.ps1 on"'
    }
    'enable' {
        if (Test-EventNameLoud $arg0) {
            [void](Set-ConfigValue "${arg0}_enabled" 'true')
            Write-Output "$arg0 is on"
        } else { $script:ExitCode = 1 }
    }
    'disable' {
        if (Test-EventNameLoud $arg0) {
            [void](Set-ConfigValue "${arg0}_enabled" 'false')
            Write-Output "$arg0 is off"
        } else { $script:ExitCode = 1 }
    }
    'threshold' {
        if ($arg0 -match '^[0-9]+$') {
            [void](Set-ConfigValue 'threshold_seconds' $arg0)
            Write-Output "turns shorter than ${arg0}s stay silent"
        } else {
            Write-Error 'usage: buzzer.ps1 threshold <seconds>'
            $script:ExitCode = 1
        }
    }
    'quiet-hours' { Set-QuietHour $arg0 $arg1 }
    'quiet' { Set-QuietHour $arg0 $arg1 }
    'volume' {
        if (-not (Test-VolumeValue $arg0)) {
            Write-Error 'usage: buzzer.ps1 volume <0.0-1.0> [event]'
            $script:ExitCode = 1
        } elseif ($arg1) {
            if (Test-EventNameLoud $arg1) {
                [void](Set-ConfigValue "${arg1}_volume" $arg0)
                Write-Output "$arg1 volume -> $arg0"
            } else { $script:ExitCode = 1 }
        } else {
            [void](Set-ConfigValue 'volume' $arg0)
            Write-Output "default volume -> $arg0"
        }
    }
    'sounds' { Show-SoundList }
    'status' { Show-Status }
    'doctor' { Show-Doctor }
    'hooks' { Show-HookSnippet }
    'log' {
        if (Test-Path -LiteralPath $script:LogFile) {
            Get-Content -LiteralPath $script:LogFile
        } else {
            Write-Output "no log yet: $script:LogFile"
        }
    }
    'config' {
        [void](Initialize-BuzzerConfig)
        if (-not $arg0) {
            Write-Output "# $script:ConfigFile"
            Get-Content -LiteralPath $script:ConfigFile
        } elseif (-not $arg1) {
            Write-Output (Get-ConfigValue $arg0 '')
        } else {
            [void](Set-ConfigValue $arg0 $arg1)
            Write-Output "$arg0=$arg1"
        }
    }
    'version' { Write-Output "agent-buzzer $script:Version" }
    '--version' { Write-Output "agent-buzzer $script:Version" }
    'help' { Show-Usage }
    '--help' { Show-Usage }
    '-h' { Show-Usage }
    default {
        Write-Error "unknown command '$Command'"
        Show-Usage
        $script:ExitCode = 64
    }
}

exit $script:ExitCode
