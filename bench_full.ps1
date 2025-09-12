param(
  [ValidateSet('spsc', 'mpsc','mpmc','oneshot','all')]
  [string]$Target = 'all',
  [ValidateSet('compile','run','cr')]
  [string]$Action = 'cr',
  [int]$Count = 1000000,
  [Nullable[int]]$Affinity,
  [ValidateSet('Idle','BelowNormal','Normal','AboveNormal','High','RealTime')]
  [string]$Priority = 'AboveNormal',
  [int]$Repeat = 1,
  [switch]$Csv,                      
  [string]$OutCsv = "bench\out.csv",   
  [switch]$AppendCsv                  
)

function Resolve-RepoRoot {
  $p = Split-Path -Parent $PSCommandPath
  Set-Location $p
  return (Get-Location).Path
}

function Get-Targets {
  param([string]$t)
  $map = @{
    spsc           = @{ src = "bin\spsc_bench.dart";          out = "bench\spsc_bench.exe" }
    mpsc           = @{ src = "bin\mpsc_bench.dart";          out = "bench\mpsc_bench.exe" }
    mpmc           = @{ src = "bin\mpmc_bench.dart";          out = "bench\mpmc_bench.exe" }
    oneshot        = @{ src = "bin\oneshot_bench.dart";       out = "bench\oneshot_bench.exe" }
  }
  if ($t -eq 'all') { return $map.GetEnumerator() | ForEach-Object { $_.Key, $_.Value } }
  if (-not $map.ContainsKey($t)) { throw "Unknown target '$t'." }
  return @($t, $map[$t])
}

function Compile-Dart {
  param([string]$src, [string]$out)
  $args = @('compile','exe',$src,'-o', $out)
  New-Item -ItemType Directory -Force -Path (Split-Path $out) | Out-Null
  & dart @args
  if ($LASTEXITCODE -ne 0) { throw "dart compile failed: $src" }
}

function Invoke-Exe {
  param([string]$exe, [string[]]$argList)

  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $exe
  $psi.Arguments = ($argList -join ' ')
  $psi.UseShellExecute = $false
  $psi.RedirectStandardOutput = $true
  $psi.RedirectStandardError  = $true
  $psi.CreateNoWindow = $true
  $psi.StandardOutputEncoding = [System.Text.Encoding]::UTF8
  $psi.StandardErrorEncoding  = [System.Text.Encoding]::UTF8

  $proc = New-Object System.Diagnostics.Process
  $proc.StartInfo = $psi
  if (-not $proc.Start()) { throw "Failed to start $exe" }

  try { $proc.PriorityClass = [System.Diagnostics.ProcessPriorityClass]::$Priority } catch {}

  if ($Affinity.HasValue) {
    try { $proc.ProcessorAffinity = [IntPtr]::new($Affinity.Value) } catch {}
  }

  $stdout = $proc.StandardOutput.ReadToEnd()
  $stderr = $proc.StandardError.ReadToEnd()
  $proc.WaitForExit()

  if ($proc.ExitCode -ne 0) {
    if ($stderr) { Write-Host $stderr -ForegroundColor Red }
    throw "$exe exited with code $($proc.ExitCode)"
  }
  return $stdout
}

function Ensure-CsvHeader {
  param([string]$path)

  $dir = Split-Path $path
  if ($dir) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

  $needHeader = $true
  if ((Test-Path $path) -and $AppendCsv) {
    $needHeader = $false
  }

  if ($needHeader) {
    'ts,type,id,sent,recv,dropped,closed,trySendOk,trySendFail,tryRecvOk,tryRecvEmpty,send_p50_ns,send_p95_ns,send_p99_ns,recv_p50_ns,recv_p95_ns,recv_p99_ns,mops,ns_per_op,drop_rate,try_send_failure_rate,try_recv_empty_rate,channels_count' | Out-File -FilePath $path -Encoding utf8
  }
}

function Append-CsvLines {
  param([string]$path, [string]$stdout)

  $lines = $stdout -split "`r?`n" | Where-Object { $_ -and -not ($_ -match '^\s*$') }
  $data  = $lines | Where-Object { $_ -notmatch '^suite,case,' } 
  if ($data.Count -gt 0) {
    $data | Out-File -Append -FilePath $path -Encoding utf8
  }
}

function Run-Target {
  param([string]$name, [hashtable]$meta)

  $out = $meta.out
  
  Write-Host ""
  Write-Host ("Running {0} ({1} iterations)" -f $name, $Count) -ForegroundColor Green

  for ($i=1; $i -le $Repeat; $i++) {
    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    $args = @("$Count")
    if ($Csv) {
      $args += @("--csv")
    } 
    $outTxt = Invoke-Exe -exe $out -argList $args
    $sw.Stop()

    if ($Csv) {
      Append-CsvLines -path $OutCsv -stdout $outTxt
      Write-Host ("--- {0} -> CSV appended ({1} ms)" -f $name, [math]::Round($sw.Elapsed.TotalMilliseconds,1)) -ForegroundColor DarkGray
    } else {
      if ($Repeat -gt 1) {
        Write-Host ("--- run #{0} ({1} ms) ---" -f $i, [math]::Round($sw.Elapsed.TotalMilliseconds,1)) -ForegroundColor DarkGray
      }
      $outTxt.TrimEnd() | Write-Host
    }
  }
}

$root = Resolve-RepoRoot
$targets = Get-Targets -t $Target

Write-Host ("Target(s): {0}" -f ($Target)) -ForegroundColor Yellow
Write-Host ("Action   : {0}" -f ($Action)) -ForegroundColor Yellow
Write-Host ("Count    : {0}" -f ($Count)) -ForegroundColor Yellow
if ($Affinity.HasValue) { Write-Host ("Affinity : 0x{0:X}" -f $Affinity.Value) -ForegroundColor Yellow }
Write-Host ("Priority : {0}" -f $Priority) -ForegroundColor Yellow
Write-Host ("Repeat   : {0}" -f $Repeat) -ForegroundColor Yellow
if ($Csv) { Write-Host ("CSV      : {0}" -f $OutCsv) -ForegroundColor Yellow }

if ($Csv) {
  Ensure-CsvHeader -path $OutCsv
}

for ($i=0; $i -lt $targets.Length; $i+=2) {
  $src = $targets[$i+1].src
  $out = $targets[$i+1].out

  switch ($Action) {
    'compile' { Compile-Dart -src $src -out $out; return }
    'cr'      { Compile-Dart -src $src -out $out }
  }
}

for ($i=0; $i -lt $targets.Length; $i+=2) {
  $name = $targets[$i]
  $meta = $targets[$i+1]
  Run-Target -name $name -meta $meta
}

Write-Host ""
