# Recording aid for the demo GIF (Windows). Opens three terminal windows with
# generic titles, then — after a countdown, so you can start your recorder and
# click away — fires a "task complete" notification for the MIDDLE one. You get
# the real behaviour (that window's taskbar button flashes + a toast names it)
# with staged, shareable titles instead of your real session names.
#
# Run it:  powershell -NoProfile -ExecutionPolicy Bypass -File scripts\demo.ps1
# Repeat a take by just running it again (re-uses / re-opens the windows).
param(
    [int]$Delay = 8,                                  # seconds before firing
    [string]$Target = 'write-integration-tests'      # which window "finishes"
)
$root = $PSScriptRoot
$titles = @('refactor-auth-module', $Target, 'run-database-migration')

Write-Host ""
Write-Host "Opening 3 demo windows..." -ForegroundColor Green
foreach ($t in $titles) {
    # -w new = a separate window; hold the title from inside the shell so it sticks.
    Start-Process wt -ArgumentList @(
        '-w', 'new', 'new-tab', '--title', $t,
        'powershell', '-NoExit', '-Command',
        "`$host.ui.RawUI.WindowTitle='$t'; Clear-Host; Write-Host '   demo session: $t' -ForegroundColor Cyan; Write-Host '   (idle - this is just a titled window for the GIF)'"
    )
    Start-Sleep -Milliseconds 900
}

Write-Host ""
Write-Host "READY." -ForegroundColor Green
Write-Host "1. Start your screen recorder (ScreenToGif / ShareX) over the taskbar + bottom-right." -ForegroundColor Yellow
Write-Host "2. Click ANY OTHER window so '$Target' is in the background." -ForegroundColor Yellow
Write-Host "3. Firing 'task complete' for '$Target' in $Delay seconds..." -ForegroundColor Yellow
for ($i = $Delay; $i -gt 0; $i--) { Write-Host "   $i" -NoNewline; Start-Sleep -Seconds 1; Write-Host "`r" -NoNewline }

& "$root\task-complete.ps1" -Project demo -Label $Target `
    -Headline 'Claude Code - task complete' -Speech 'for demo' `
    -AudioFile "$root\task-complete.wav"

Write-Host ""
Write-Host "Fired. '$Target' should have flashed + shown a toast naming it." -ForegroundColor Green
Write-Host "Click the toast (or the flashing taskbar button) to show click-to-raise, then stop recording." -ForegroundColor Green
