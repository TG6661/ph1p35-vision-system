param(
 [switch]$BuildFirmware,
 [string]$Gcc = $(if ($env:HOST_GCC) { $env:HOST_GCC } else { 'gcc' }),
 [string]$FdRoot = $(if ($env:FD_ROOT) { $env:FD_ROOT } else { 'E:/FD' }),
 [string]$Vsim = $(if ($env:MODELSIM_VSIM) { $env:MODELSIM_VSIM } else { 'vsim' }),
 [string]$TdSimDir = $(if ($env:TD_SIM_DIR) { $env:TD_SIM_DIR } else { 'E:/TD/sim_release/ph1p' })
)
# Functional checks only; never invokes TD, implementation or board tools.
$ErrorActionPreference='Stop'
$sim=(Resolve-Path "$PSScriptRoot/..").Path
$logs="$PSScriptRoot/runs/validation_$(Get-Date -Format yyyyMMdd_HHmmss_fff)"
New-Item -ItemType Directory -Path $logs | Out-Null
# The HUD simulations consume the vectors emitted by the real C packer.
& "$PSScriptRoot/run_host.ps1" -BuildFirmware:$BuildFirmware -Gcc $Gcc -FdRoot $FdRoot
if($LASTEXITCODE -ne 0) {throw 'Host validation failed'}
Push-Location $sim
try {
 foreach($name in @('lsc','gg','ascii','ascii_full','ascii_post','crt','crt_latency','cl','negative_unit','negative_serial','regs','post_contract','runtime','final_sink','replay_neg','replay_ascii','stats','mode_menu','osd_timing','target_timing','camera_hud','mcu_candidate','servo','actual_manifest')) {
  $tclPath = $TdSimDir.Replace('\','/')
  if ($tclPath -match '[{}\r\n]') { throw 'TD simulation path cannot contain braces or newlines' }
  & $Vsim -c -do "set TD_SIM_DIR {$tclPath}; do current/$name.do" -l "$logs/$name.log" *> "$logs/${name}_console.log"
  if($LASTEXITCODE -ne 0) {throw "$name failed: $logs/$name.log"}
  Write-Output "$name PASS"
 }
 Write-Output "CURRENT_VALIDATION_PASS logs=$logs"
} finally {Pop-Location}
