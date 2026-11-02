# Restore FD absolute paths for this checkout only. Does not invoke tools or board access.
param()
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/..").Path.Replace('\','/')
$utf8 = New-Object System.Text.UTF8Encoding($false)
foreach ($item in @(
    @('application.project.json.template','FDWork/ph1p35_hello/.fd/project.json'),
    @('bsp.project.json.template','FDWork/MCU_startup/.fd/project.json'),
    @('final_current_0x70ff.launch.template','FDWork/ph1p35_hello/final_current_0x70ff.launch')
)) {
    $source = Join-Path "$PSScriptRoot/templates" $item[0]
    $target = Join-Path $root $item[1]
    New-Item -ItemType Directory -Force -Path (Split-Path $target) | Out-Null
    $value = [IO.File]::ReadAllText($source)
    if ($item[0].EndsWith('.json.template')) {
        $escaped = ($root | ConvertTo-Json -Compress)
        $escaped = $escaped.Substring(1,$escaped.Length-2)
    } else {
        $escaped = [Security.SecurityElement]::Escape($root)
    }
    [IO.File]::WriteAllText($target,$value.Replace('@REPO_ROOT@',$escaped),$utf8)
}
# TD source-file entries are already relative. Change only the project-root hint.
$al = Join-Path $root 'FPGA/td_project/camera_to_dsi_display.al'
$value = [IO.File]::ReadAllText($al)
$newPath = [Security.SecurityElement]::Escape("$root/FPGA/td_project")
$updated = [regex]::Replace($value,'(<Project\b[^>]*\bPath=")[^"]*(")',{
    param($match)
    $match.Groups[1].Value + $newPath + $match.Groups[2].Value
})
if ($updated -ne $value) { [IO.File]::WriteAllText($al,$updated,$utf8) }
Write-Host "Local project paths prepared: $root"
Write-Host 'No synthesis, implementation, download, reset or debug connection was started.'
Write-Host 'Import MCU_startup and ph1p35_hello from this checkout into a fresh FD workspace.'
Write-Host 'BSP regeneration needs a separately exported HPF; existing sources can be built without it.'
