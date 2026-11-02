param(
    [string]$FdRoot = $(if ($env:FD_ROOT) { $env:FD_ROOT } else { 'E:/FD' }),
    [switch]$Clean
)
$ErrorActionPreference = 'Stop'
$savedPath = $env:Path
try {
    $buildTools = Join-Path $FdRoot 'toolchain/build-tools/bin'
    $gccTools = Join-Path $FdRoot 'toolchain/gcc/riscv/ph1p35/bin'
    $makeExe = Join-Path $buildTools 'make.exe'
    if (!(Test-Path -LiteralPath $makeExe) -or
        !(Test-Path -LiteralPath (Join-Path $gccTools 'riscv64-unknown-elf-gcc.exe'))) {
        throw "FD make/RISC-V toolchain missing under $FdRoot"
    }
    $env:Path = "$buildTools;$gccTools;$savedPath"
    $appDir = Join-Path $PSScriptRoot 'ph1p35_hello'
    if ($Clean) {
        & $makeExe -C $appDir COMPILE_PREFIX=riscv64-unknown-elf- clean
        if ($LASTEXITCODE -ne 0) { throw 'Firmware clean failed' }
    }
    & $makeExe -C $appDir -j4 COMPILE_PREFIX=riscv64-unknown-elf- all
    if ($LASTEXITCODE -ne 0) { throw 'Firmware build failed' }
    Write-Host "FIRMWARE_BUILD_PASSED: $appDir/build/ph1p35_hello.elf"
} finally {
    $env:Path = $savedPath
}
