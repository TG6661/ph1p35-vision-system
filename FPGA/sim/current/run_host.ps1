param(
 [switch]$BuildFirmware,
 [string]$Gcc = $(if ($env:HOST_GCC) { $env:HOST_GCC } else { 'gcc' }),
 [string]$FdRoot = $(if ($env:FD_ROOT) { $env:FD_ROOT } else { 'E:/FD' })
)
$ErrorActionPreference='Stop'
$root=(Resolve-Path "$PSScriptRoot/../../..").Path
$src="$root/FDWork/ph1p35_hello"
$logs="$PSScriptRoot/runs/$(Get-Date -Format yyyyMMdd_HHmmss_fff)"
New-Item -ItemType Directory -Path $logs | Out-Null
$gcc=(Get-Command $Gcc -ErrorAction Stop).Source
$savedPath=$env:Path
$env:Path=(Split-Path $gcc)+';'+$savedPath
try {
$common=@('-std=c11','-Wall','-Wextra','-Werror','-O2','-static','-DOOPFPGA_HOST_TEST','-I',$src)
$suites=@(
 @{Name='mode_menu';Sources=@("$PSScriptRoot/test_mode_menu.c","$src/integration_service.c","$src/menu_control.c","$src/menu_display.c","$src/gimbal_track.c")},
 @{Name='style_control';Sources=@("$PSScriptRoot/test_style_control.c","$src/integration_service.c")},
 @{Name='boot_contract';Sources=@("$PSScriptRoot/test_boot_contract.c")},
 @{Name='camera_retry';Sources=@("$PSScriptRoot/test_camera_retry.c","$src/camera_service.c","$src/exposure_service.c")},
 @{Name='exposure';Sources=@("$PSScriptRoot/test_exposure.c","$src/exposure_service.c","$src/integration_service.c","$src/camera_service.c","$src/menu_control.c","$src/menu_display.c","$src/gimbal_track.c")},
 @{Name='gimbal';Sources=@("$PSScriptRoot/test_gimbal.c","$src/gimbal_track.c","$src/menu_control.c","$src/menu_display.c")},
 @{Name='readiness';Sources=@("$PSScriptRoot/test_readiness.c","$src/integration_service.c")}
)
foreach($suite in $suites) {
 & $gcc @common @($suite.Sources) -o "$logs/$($suite.Name).exe" *> "$logs/$($suite.Name)-compile.log"
 if($LASTEXITCODE -ne 0){throw "Compile failed: $logs/$($suite.Name)-compile.log"}
 if($suite.Name -eq 'mode_menu') {
  & "$logs/$($suite.Name).exe" "$PSScriptRoot/menu_vectors.txt" *> "$logs/$($suite.Name).log"
 } else {
  & "$logs/$($suite.Name).exe" *> "$logs/$($suite.Name).log"
 }
 if($LASTEXITCODE -ne 0){throw "Test failed: $logs/$($suite.Name).log"}
 Get-Content "$logs/$($suite.Name).log"
}
if($BuildFirmware) {
 & "$root/FDWork/build.ps1" -FdRoot $FdRoot *> "$logs/firmware.log"
 if($LASTEXITCODE -ne 0){throw "Firmware build failed: $logs/firmware.log"}
}
Write-Output "CURRENT_HOST_PASS logs=$logs"
} finally { $env:Path=$savedPath }
