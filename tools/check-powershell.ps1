# Parse tracked PowerShell scripts without executing them.
$ErrorActionPreference = 'Stop'
$root = (Resolve-Path "$PSScriptRoot/..").Path
$files = @(& git -C $root ls-files -- '*.ps1')
if ($LASTEXITCODE -ne 0 -or $files.Count -eq 0) { throw 'No tracked PowerShell scripts found' }
foreach ($file in $files) {
    $tokens = $null
    $parseErrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile(
        (Join-Path $root $file), [ref]$tokens, [ref]$parseErrors) | Out-Null
    if ($parseErrors.Count) { throw "$file`n$($parseErrors | Out-String)" }
    Write-Output "PARSE_OK $file"
}
