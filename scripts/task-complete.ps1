# Windows side of the Stop-hook notifier (spawned by task-complete.cjs).
# Multiple sessions run as TABS in one Windows Terminal window; the flash can
# only address the shared WINDOW, so the toast TEXT (the session's ai-title,
# passed in as -Label from the transcript) is what identifies which tab finished.
# 1. Flashes the hosting terminal window's taskbar button - a coarse "something
#    in this window finished" cue; no-ops when the window is already foreground.
# 2. Shows a per-session Windows toast NAMING the session. If task-complete-
#    setup.ps1 has been run (claude-raise: protocol registered) clicking it
#    raises the window via protocol activation; it still can't select the tab,
#    so the toast TEXT is what tells you which one.
# 3. Plays the wav then speaks "for <project>" - suppressed with -NoSound when
#    another session already made the sound (audio debounce).
# Runs under Windows PowerShell 5.1 (WinRT toast projection needs it).
param(
    [string]$Project = 'a project',
    [string]$Label = '',
    [string]$AudioFile = '',
    [string]$Sid = 'none',
    [switch]$NoSound,
    [switch]$NoToast
)
$ErrorActionPreference = 'SilentlyContinue'

$name = if ($Label) { $Label } else { $Project }
$trace = Join-Path $env:TEMP 'claude-notify-trace.log'
function Trace($msg) { Add-Content -Path $trace -Value "$([DateTime]::UtcNow.ToString('o')) $msg" }

# --- 1. Taskbar flash of THIS session's specific window ----------------------
# Each Claude session is its own top-level terminal window whose title is the
# session's ai-title (= our $Label). One WindowsTerminal.exe hosts several such
# windows, so Get-Process ... MainWindowHandle returns the ACTIVE one, not this
# session's - the old bug. Match the window by title instead: that is the
# correct taskbar button, which Windows highlights per-window.
# NB: single-quoted here-string (@'...'@) - C# source must NOT be subject to
# PowerShell expansion. A backtick in a comment (e.g. around a word) is the
# escape char in a double-quoted @"..."@ and silently corrupts the source.
Add-Type @'
using System;
using System.Text;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class WinFlash {
    [StructLayout(LayoutKind.Sequential)]
    public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
    [DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO pwfi);
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool EnumWindows(EnumWindowsProc cb, IntPtr l);
    delegate bool EnumWindowsProc(IntPtr h, IntPtr l);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] static extern int GetClassName(IntPtr h, StringBuilder s, int n);

    // Terminal host window classes. A title match is only trusted for these, so
    // a transient toast/notification banner that echoes the same text is never
    // flashed. Add a class here to support another terminal.
    static readonly string[] TERMINAL_CLASSES = {
        "CASCADIA_HOSTING_WINDOW_CLASS", // Windows Terminal
        "ConsoleWindowClass",            // conhost / classic console
        "PseudoConsoleWindow",
    };
    static bool IsTerminal(IntPtr h) {
        var cn = new StringBuilder(256);
        GetClassName(h, cn, cn.Capacity);
        string c = cn.ToString();
        foreach (var t in TERMINAL_CLASSES) if (c == t) return true;
        return false;
    }

    // Flash the caption + taskbar button until the window comes to the
    // foreground. FlashWindowEx TOGGLES the flash state on each call, so if a
    // prior notification left the window flashing (you never focused it), a
    // plain second call would INVERT it and stop the flash - the "every other
    // notification shows no orange" symptom. Send FLASHW_STOP (0) first to reset
    // to a known state, then start a fresh flash, so every call flashes.
    public static void Flash(IntPtr h) {
        var f = new FLASHWINFO();
        f.cbSize = (uint)Marshal.SizeOf(typeof(FLASHWINFO));
        f.hwnd = h; f.uCount = 0; f.dwTimeout = 0;
        f.dwFlags = 0u;         // FLASHW_STOP - clear any lingering flash
        FlashWindowEx(ref f);
        f.dwFlags = 3u | 12u;   // FLASHW_ALL | FLASHW_TIMERNOFG - flash till focus
        FlashWindowEx(ref f);
    }
    // Visible terminal-class top-level windows whose title contains `needle`
    // (ordinal, case-insensitive). Restricted to terminal classes so a transient
    // toast/notification banner echoing the same text is never returned.
    public static List<IntPtr> FindByTitle(string needle) {
        var hits = new List<IntPtr>();
        if (string.IsNullOrEmpty(needle)) return hits;
        EnumWindows((h,l)=>{
            if(!IsWindowVisible(h)) return true;
            // Fixed buffer + direct GetWindowText (WM_GETTEXT). Do NOT gate on
            // GetWindowTextLength: WM_GETTEXTLENGTH can return 0 cross-process
            // in the hook's context, which silently dropped the terminal window.
            var sb = new StringBuilder(512);
            GetWindowText(h, sb, sb.Capacity);
            if(sb.ToString().IndexOf(needle, StringComparison.OrdinalIgnoreCase) >= 0 && IsTerminal(h)) hits.Add(h);
            return true;
        }, IntPtr.Zero);
        return hits;
    }
}
'@

# Flash THIS session's window - the one whose title contains its name. We do
# NOT fall back to some other window (the active WT window, an ancestor's): a
# wrong flash is worse than none, because it sends you to a still-working tab.
# If the name can't be matched (no ai-title yet), the named toast still tells
# you which session finished.
$hwnds = @([WinFlash]::FindByTitle($Label) | ForEach-Object { $_ })
foreach ($h in $hwnds) { [WinFlash]::Flash($h) }
$fg = [WinFlash]::GetForegroundWindow().ToInt64()
Trace "ev=flash sid=$Sid flashed=[$($hwnds -join ',')] matched=$($hwnds.Count) fg=$fg foregroundIsTarget=$(($hwnds -contains $fg))"

# --- 2. Toast ---------------------------------------------------------------
if (-not $NoToast) {
    try {
        $null = [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime]
        $null = [Windows.Data.Xml.Dom.XmlDocument, Windows.Data.Xml.Dom.XmlDocument, ContentType = WindowsRuntime]
        # Borrow PowerShell's registered AppUserModelID so the toast displays.
        $appId = '{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe'
        $n = [Security.SecurityElement]::Escape($name)
        # Click-to-raise: only when the claude-raise: handler is registered
        # (task-complete-setup.ps1) and we actually found a window to raise.
        $launch = ''
        if ($hwnds -and (Test-Path 'HKCU:\Software\Classes\claude-raise\shell\open\command')) {
            $launch = " activationType=`"protocol`" launch=`"claude-raise://$($hwnds[0])`""
        }
        $xml = New-Object Windows.Data.Xml.Dom.XmlDocument
        # Session name is the prominent (first) line so you can scan which tab.
        $xml.LoadXml("<toast$launch><visual><binding template='ToastGeneric'><text>$n</text><text>Claude Code - task complete</text></binding></visual><audio silent='true'/></toast>")
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appId).Show(
            [Windows.UI.Notifications.ToastNotification]::new($xml))
        Trace "ev=toast sid=$Sid ok=1 name='$name'"
    } catch { Trace "ev=toast sid=$Sid ok=0 err='$($_.Exception.Message)'" }
}

# --- 3. Sound ---------------------------------------------------------------
Trace "ev=sound sid=$Sid played=$(-not $NoSound)"
if (-not $NoSound) {
    if ($AudioFile -and (Test-Path $AudioFile)) {
        (New-Object Media.SoundPlayer $AudioFile).PlaySync()
    }
    Add-Type -AssemblyName System.Speech
    (New-Object System.Speech.Synthesis.SpeechSynthesizer).Speak("for $Project")
}
