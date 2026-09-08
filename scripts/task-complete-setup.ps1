# One-time per-machine setup for toast click-to-raise (Windows).
# Compiles a tiny windowless handler exe into %LOCALAPPDATA%\claude-notify and
# registers the claude-raise: URI scheme (HKCU, no admin) pointing at it.
# task-complete.ps1 only adds the click action to its toast when this
# registration exists, so running this script is what turns the feature on.
# Idempotent - rerun any time (e.g. to recompile after an edit).
# Run under Windows PowerShell 5.1: powershell -ExecutionPolicy Bypass -File task-complete-setup.ps1
$ErrorActionPreference = 'Stop'

$binDir = Join-Path $env:LOCALAPPDATA 'claude-notify'
$exe = Join-Path $binDir 'claude-raise.exe'
New-Item -ItemType Directory -Force -Path $binDir | Out-Null

# Handler: claude-raise://<hwnd> -> restore + foreground that window.
# Windows grants foreground rights here because the launch came from a real
# user click on the toast; if denied anyway, SetForegroundWindow degrades to
# a taskbar flash, which is still the right signal.
$src = @'
using System;
using System.Runtime.InteropServices;

static class RaiseWindow {
    [DllImport("user32.dll")] static extern bool SetForegroundWindow(IntPtr h);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
    [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
    [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
    [DllImport("user32.dll")] static extern void SwitchToThisWindow(IntPtr h, bool altTab);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern bool AttachThreadInput(uint idAttach, uint idAttachTo, bool attach);
    [DllImport("user32.dll")] static extern bool BringWindowToTop(IntPtr h);
    [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("kernel32.dll")] static extern uint GetCurrentThreadId();

    static void Log(string msg) {
        try {
            System.IO.File.AppendAllText(
                System.IO.Path.Combine(System.IO.Path.GetTempPath(), "claude-raise.log"),
                DateTime.Now.ToString("o") + " " + msg + Environment.NewLine);
        } catch {}
    }

    static void Main(string[] args) {
        Log("invoked args=[" + string.Join(" ", args) + "]");
        if (args.Length == 0) return;
        string digits = "";
        foreach (char c in args[0]) if (char.IsDigit(c)) digits += c;
        long v;
        if (!long.TryParse(digits, out v) || v == 0) { Log("no hwnd in uri"); return; }
        IntPtr h = new IntPtr(v);
        if (!IsWindow(h)) { Log("hwnd " + v + " is not a window (stale)"); return; }
        if (IsIconic(h)) ShowWindow(h, 9);         // SW_RESTORE
        // A launch from a real toast click carries foreground rights, so this
        // normally just works; when denied (active input elsewhere) fall back
        // to SwitchToThisWindow, and worst case Windows flashes the taskbar
        // button instead - still the right signal, never a stolen keystroke.
        SetForegroundWindow(h);
        if (GetForegroundWindow() == h) { Log("raised " + v + " via SetForegroundWindow"); return; }
        SwitchToThisWindow(h, true);
        if (GetForegroundWindow() == h) { Log("raised " + v + " via SwitchToThisWindow"); return; }
        // Foreground lock held by another thread (observed here: Input Leap's
        // capture window while the pointer is on another machine). Attach to
        // that thread's input state, which makes us "the" input thread, raise,
        // then detach.
        uint fgPid;
        uint fgThread = GetWindowThreadProcessId(GetForegroundWindow(), out fgPid);
        uint me = GetCurrentThreadId();
        if (fgThread != 0 && AttachThreadInput(me, fgThread, true)) {
            BringWindowToTop(h);
            SetForegroundWindow(h);
            AttachThreadInput(me, fgThread, false);
        }
        if (GetForegroundWindow() == h) { Log("raised " + v + " via AttachThreadInput"); return; }
        // Last resort: pop it visually on top without taking focus
        // (TOPMOST then NOTOPMOST; NOSIZE|NOMOVE|NOACTIVATE).
        SetWindowPos(h, new IntPtr(-1), 0, 0, 0, 0, 0x13u);
        SetWindowPos(h, new IntPtr(-2), 0, 0, 0, 0, 0x13u);
        Log("focus denied for " + v + " (fg=" + GetForegroundWindow() + "); brought visually to top instead");
    }
}
'@
Add-Type -TypeDefinition $src -OutputAssembly $exe -OutputType WindowsApplication
Write-Output "compiled $exe"

$root = 'HKCU:\Software\Classes\claude-raise'
New-Item -Path "$root\shell\open\command" -Force | Out-Null
Set-ItemProperty -Path $root -Name '(Default)' -Value 'URL:Claude raise window'
Set-ItemProperty -Path $root -Name 'URL Protocol' -Value ''
Set-ItemProperty -Path "$root\shell\open\command" -Name '(Default)' -Value "`"$exe`" `"%1`""
Write-Output "registered claude-raise: protocol -> $exe"
