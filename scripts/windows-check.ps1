# Install check for the Spark desktop app on one clean Windows machine (a GitHub-hosted runner).
#
# Does what a customer's installer does: download the installer get-spark.io
# serves, check it is signed, install it for the current user, open Spark and
# check it starts, shows a window and keeps running. Results go to
# $env:RUNNER_TEMP\spark-check (results.json, machine.json, screenshots).
#
# Kept out of Spark's real install numbers: downloads use curl.exe, which the
# site's download counter treats as a script, and get-spark.io is blocked on
# this machine before Spark is opened, so its launch never reaches the server.
$ErrorActionPreference = 'Continue'
$out = Join-Path $env:RUNNER_TEMP 'spark-check'
$dl = Join-Path $env:RUNNER_TEMP 'spark-download'
New-Item -ItemType Directory -Force -Path $out, $dl | Out-Null
$results = [System.Collections.Generic.List[object]]::new()
$script:failed = $false
function Record([string]$check, [string]$status, [string]$detail) {
  $results.Add([pscustomobject]@{ check = $check; result = $status; detail = ($detail -replace '\s+', ' ').Trim() })
  Write-Host "[$status] ${check}: $detail"
  if ($status -eq 'FAIL') { $script:failed = $true }
}

$os = Get-CimInstance Win32_OperatingSystem
$cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion'
$osName = "$($os.Caption) $($cv.DisplayVersion)".Trim()
$build = "$($os.BuildNumber).$($cv.UBR)"
$arch = $env:PROCESSOR_ARCHITECTURE
Record 'Machine' 'INFO' "$osName, build $build, $arch, runner $env:MACHINE"

$url = if ($env:SPARK_WINDOWS_URL) { $env:SPARK_WINDOWS_URL } else { 'https://get-spark.io/api/download/windows' }
$inst = Join-Path $dl 'Spark-Installer.exe'
$stub = Join-Path $dl 'Spark-Setup.exe'

# 1. Download the full installer and the small setup file customers are given.
curl.exe -fsSL --retry 3 --retry-delay 5 -o $inst $url
if ($LASTEXITCODE -eq 0 -and (Test-Path $inst)) {
  Record 'Download: installer' 'PASS' ("{0:N0} MB" -f ((Get-Item $inst).Length / 1MB))
} else { Record 'Download: installer' 'FAIL' "curl exit $LASTEXITCODE for $url" }
curl.exe -fsSL --retry 3 --retry-delay 5 -o $stub 'https://get-spark.io/api/download/windows/setup'
if ($LASTEXITCODE -eq 0 -and (Test-Path $stub)) {
  Record 'Download: setup file' 'PASS' ("{0:N1} MB" -f ((Get-Item $stub).Length / 1MB))
} else { Record 'Download: setup file' 'FAIL' "curl exit $LASTEXITCODE" }

# 2. Both are signed, with a signature Windows trusts.
foreach ($f in @($stub, $inst)) {
  if (-not (Test-Path $f)) { continue }
  $sig = Get-AuthenticodeSignature -FilePath $f
  $name = Split-Path $f -Leaf
  if ($sig.Status -eq 'Valid') {
    $cn = ($sig.SignerCertificate.Subject -split ',')[0] -replace '^CN=', ''
    $ts = if ($sig.TimeStamperCertificate) { 'timestamped' } else { 'NOT timestamped' }
    Record "Signature: $name" 'PASS' "signed by $cn, $ts"
  } else { Record "Signature: $name" 'FAIL' "$($sig.Status): $($sig.StatusMessage)" }
}

$sparkVersion = ''
if (Test-Path $inst) {
  # 3. Silent install for the current user, as the setup file runs it.
  $p = Start-Process -FilePath $inst -ArgumentList '/S' -PassThru -Wait
  if ($p.ExitCode -eq 0) { Record 'Install' 'PASS' 'silent install finished (exit 0)' } else { Record 'Install' 'FAIL' "installer exit code $($p.ExitCode)" }

  $un = Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall', 'HKLM:\Software\Microsoft\Windows\CurrentVersion\Uninstall' -ErrorAction SilentlyContinue |
    ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_.DisplayName -eq 'Spark' } | Select-Object -First 1
  $dir = if ($un -and $un.InstallLocation) { $un.InstallLocation.Trim('"') } else { Join-Path $env:LOCALAPPDATA 'Spark' }
  $exe = Get-ChildItem -Path $dir -Filter '*.exe' -ErrorAction SilentlyContinue |
    Where-Object { $_.Name -notmatch '^(uninstall|yt-dlp|ffmpeg|ffprobe|qjs)' } | Select-Object -First 1
  if ($exe) {
    $sparkVersion = if ($un.DisplayVersion) { $un.DisplayVersion } else { $exe.VersionInfo.ProductVersion }
    Record 'Spark version' 'INFO' "$sparkVersion at $($exe.FullName.Replace($env:USERPROFILE, '%USERPROFILE%'))"
  } else { Record 'Installed files' 'FAIL' "no Spark exe in $dir" }

  # 4. WebView2, the browser engine Spark's window runs on.
  $wv = Get-ItemProperty 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}', 'HKCU:\Software\Microsoft\EdgeUpdate\Clients\{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}' -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($wv -and $wv.pv) { Record 'WebView2' 'INFO' "version $($wv.pv) present" } else { Record 'WebView2' 'INFO' 'not found in the registry' }

  # 5. The bundled download tools run on this machine.
  if ($exe) {
    $tools = @(
      @{ n = 'yt-dlp'; a = @('--version'); ok = '^\d{4}\.' },
      @{ n = 'ffmpeg'; a = @('-hide_banner', '-version'); ok = 'ffmpeg version' },
      @{ n = 'ffprobe'; a = @('-hide_banner', '-version'); ok = 'ffprobe version' },
      @{ n = 'qjs'; a = @('-e', 'console.log(6*7)'); ok = '^42$' }
    )
    foreach ($t in $tools) {
      $path = Join-Path $dir "$($t.n).exe"
      if (-not (Test-Path $path)) { Record "Tool: $($t.n)" 'FAIL' 'missing from the install'; continue }
      $o = (& $path @($t.a) 2>&1 | Out-String).Trim()
      $first = ($o -split "`r?`n")[0]
      $last = ($o -split "`r?`n")[-1]
      if ($first -match $t.ok -or $last -match $t.ok) { Record "Tool: $($t.n)" 'PASS' $first } else { Record "Tool: $($t.n)" 'FAIL' "exit $LASTEXITCODE $first" }
    }
  }

  # 6. Keep this test machine out of Spark's real install numbers.
  $hosts = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
  Add-Content -Path $hosts -Value "`r`n127.0.0.1 get-spark.io`r`n127.0.0.1 www.get-spark.io`r`n::1 get-spark.io`r`n::1 www.get-spark.io"
  ipconfig /flushdns | Out-Null
  curl.exe -s -m 5 -o NUL https://get-spark.io/
  if ($LASTEXITCODE -eq 0) {
    Record 'Kept out of install stats' 'FAIL' 'get-spark.io still reachable, so Spark was not opened'
  } elseif ($exe) {
    Record 'Kept out of install stats' 'INFO' 'get-spark.io blocked on this machine before opening Spark'

    # 7. Open Spark.
    $opened = Get-Date
    $proc = Start-Process -FilePath $exe.FullName -PassThru
    Start-Sleep -Seconds 40
    $live = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if ($live) { Record 'Opens' 'PASS' "running after 40 s (pid $($proc.Id))" } else { Record 'Opens' 'FAIL' "exited within 40 s (exit code $($proc.ExitCode))" }
    if ($live) {
      $live.Refresh()
      $web = @(Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue).Count
      if ($live.MainWindowHandle -ne 0) { Record 'Window' 'PASS' "on screen ('$($live.MainWindowTitle)'), $web WebView2 processes" } else { Record 'Window' 'FAIL' "no main window ($web WebView2 processes)" }
    }
    try {
      Add-Type -AssemblyName System.Windows.Forms, System.Drawing
      $b = [System.Windows.Forms.Screen]::PrimaryScreen.Bounds
      $bmp = New-Object System.Drawing.Bitmap $b.Width, $b.Height
      $g = [System.Drawing.Graphics]::FromImage($bmp)
      $g.CopyFromScreen($b.Location, [System.Drawing.Point]::Empty, $b.Size)
      $bmp.Save((Join-Path $out 'screen-after-40s.png'), [System.Drawing.Imaging.ImageFormat]::Png)
      $g.Dispose(); $bmp.Dispose()
    } catch { Record 'Screenshot' 'INFO' "screen capture failed: $($_.Exception.Message)" }

    # 8. Still running a minute later, with no crash in the event log.
    Start-Sleep -Seconds 60
    $still = Get-Process -Id $proc.Id -ErrorAction SilentlyContinue
    if ($still) { Record 'Keeps running' 'PASS' ("still running after 100 s, {0:N0} MB memory" -f ($still.WorkingSet64 / 1MB)) } else { Record 'Keeps running' 'FAIL' 'quit or crashed within 100 s' }
    $crashes = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; StartTime = $opened } -ErrorAction SilentlyContinue |
      Where-Object { $_.ProviderName -in @('Application Error', 'Windows Error Reporting', '.NET Runtime') -and $_.Message -match [regex]::Escape($exe.Name) })
    if ($crashes.Count -eq 0) { Record 'No crash reports' 'PASS' 'none in the event log since opening' } else { Record 'No crash reports' 'FAIL' (($crashes | Select-Object -First 2 | ForEach-Object { ($_.Message -split "`r?`n")[0] }) -join ' / ') }
  }
}

$result = if ($script:failed) { 'FAIL' } else { 'PASS' }
$results | ConvertTo-Json -Depth 3 | Set-Content -Path (Join-Path $out 'results.json') -Encoding utf8
[pscustomobject]@{ runner = $env:MACHINE; platform = 'Windows'; os = $osName; build = $build; arch = $arch; spark = $sparkVersion; result = $result } |
  ConvertTo-Json | Set-Content -Path (Join-Path $out 'machine.json') -Encoding utf8
if ($env:GITHUB_STEP_SUMMARY) {
  $md = @("### $osName ($arch): $result", '', '| Check | Result | Detail |', '|---|---|---|')
  foreach ($r in $results) { $md += "| $($r.check) | $($r.result) | $($r.detail -replace '\|', '/') |" }
  Add-Content -Path $env:GITHUB_STEP_SUMMARY -Value ($md -join "`n")
}
if ($script:failed) { exit 1 } else { exit 0 }
