param([Parameter(Mandatory=$true)][string]$GodotPath,[string]$OutputDirectory)
$ErrorActionPreference = 'Stop'
$projectDirectory = Split-Path $PSScriptRoot -Parent
if ([string]::IsNullOrWhiteSpace($OutputDirectory)) { $OutputDirectory = Join-Path $projectDirectory ('deliverables/windows_v3_' + (Get-Date -Format 'yyyyMMdd_HHmmss')) }
if (Test-Path -LiteralPath $OutputDirectory) { throw '输出目录已存在，请指定新目录。' }
New-Item -ItemType Directory -Path $OutputDirectory | Out-Null
$exePath = Join-Path ([IO.Path]::GetFullPath($OutputDirectory)) 'BlueSnowValley_v3.exe'
& $GodotPath --headless --path $projectDirectory --export-release 'Windows V3 Offline' $exePath
if ($LASTEXITCODE -ne 0) { throw 'Windows导出失败。' }
Write-Output $exePath
