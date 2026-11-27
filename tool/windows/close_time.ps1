# How long the app takes to close on Windows (roadmap C19): starts it,
# waits, presses the close button and times how long the window stays
# and how long the program lives on after it.
#
#   powershell -ExecutionPolicy Bypass -File tool\windows\close_time.ps1
#   ... -Exe "C:\path\to\uwmedia.exe" -Wait 20 -Times 3
#
# Without -Exe: the installed app, then a build of this repo. -Wait is
# the seconds the app is left alone before it is closed (use the app in
# that time to try a close after a page was opened). Nothing is written
# anywhere; the app's own log gets its "Closing" line as on any close.
param(
    [string]$Exe = '',
    [int]$Wait = 10,
    [int]$Times = 3
)

if (-not $Exe) {
    $candidates = @(
        (Join-Path $env:LOCALAPPDATA 'Programs\uwmedia\uwmedia.exe'),
        (Join-Path $env:ProgramFiles 'Christersson\uwmedia\uwmedia.exe'),
        (Join-Path $PSScriptRoot '..\..\build\windows\x64\runner\Release\uwmedia.exe')
    )
    $Exe = $candidates | Where-Object { Test-Path $_ } | Select-Object -First 1
}
if (-not $Exe -or -not (Test-Path $Exe)) {
    Write-Error 'uwmedia.exe not found: give it with -Exe'
    exit 1
}
Write-Output "App: $Exe"

for ($run = 1; $run -le $Times; $run++) {
    $app = Start-Process -FilePath $Exe -PassThru
    # The window is shown once it is placed.
    $shown = [Diagnostics.Stopwatch]::StartNew()
    while ($app.MainWindowHandle -eq 0 -and $shown.Elapsed.TotalSeconds -lt 60) {
        Start-Sleep -Milliseconds 100
        $app.Refresh()
    }
    if ($app.MainWindowHandle -eq 0) {
        Write-Error 'The app showed no window in 60 s'
        $app.Kill()
        exit 1
    }
    $started = $shown.ElapsedMilliseconds
    Start-Sleep -Seconds $Wait

    $clock = [Diagnostics.Stopwatch]::StartNew()
    [void]$app.CloseMainWindow()
    $windowGone = $null
    while (-not $app.HasExited -and $clock.Elapsed.TotalSeconds -lt 120) {
        $app.Refresh()
        if ($null -eq $windowGone -and $app.MainWindowHandle -eq 0) {
            $windowGone = $clock.ElapsedMilliseconds
        }
        Start-Sleep -Milliseconds 20
    }
    if (-not $app.HasExited) {
        Write-Output "Run ${run}: still running 120 s after the close; killed"
        $app.Kill()
        continue
    }
    $ended = $clock.ElapsedMilliseconds
    if ($null -eq $windowGone) { $windowGone = $ended }
    Write-Output ("Run ${run}: window after {0} ms; closed after {1} s; the window gone after {2} ms, the program after {3} ms" -f $started, $Wait, $windowGone, $ended)
}
