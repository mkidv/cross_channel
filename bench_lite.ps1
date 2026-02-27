param(
  [ValidateSet('spsc','mpsc','mpmc','oneshot','broadcast','all')]
  [string]$Target = 'all',
  [int]$Count = 1000000
)

$map = @{
  spsc="bin\spsc_bench.dart";
  mpsc="bin\mpsc_bench.dart";
  mpmc="bin\mpmc_bench.dart"
  oneshot="bin\oneshot_bench.dart";
  broadcast="bin\broadcast_bench.dart";
}
if ($Target -eq 'all') { $targets = $map.Keys } else { $targets = @($Target) }

foreach ($t in $targets) {
  if (-not $map.ContainsKey($t)) { throw "Unknown target '$t'." }
  $src = $map[$t]
  $out = "bench\${t}_bench.exe"
  dart compile exe $src -o $out
  if ($LASTEXITCODE -ne 0) { throw "compile failed" }
}

foreach ($t in $targets) {
  $out = "bench\${t}_bench.exe"
  Write-Host ""
  Write-Host ("Running {0} ({1} iterations)" -f $t, $Count) -ForegroundColor Green
  $args = @("$Count")
  & $out @args
}
