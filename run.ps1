param(
    [switch]$Editor,
    [switch]$Capture,
    [string]$GodotPath,
    [ValidateSet('V1', 'V2', 'V3')]
    [string]$Version = 'V3'
)

# 1. 优先使用显式路径，否则查找本次已验证的Godot版本。
$ErrorActionPreference = 'Stop'
$enginePath = $GodotPath
if ([string]::IsNullOrWhiteSpace($enginePath)) {
    $engineCommand = Get-Command 'Godot_v4.7.1-stable_win64_console.exe' -ErrorAction SilentlyContinue
    if ($null -eq $engineCommand) {
        throw '未找到Godot 4.7.1。请使用 -GodotPath 指定Godot可执行文件的完整路径。'
    }
    $enginePath = $engineCommand.Source
}
if (-not (Test-Path -LiteralPath $enginePath -PathType Leaf)) {
    throw ('Godot可执行文件不存在：' + $enginePath)
}
if ($Editor -and $Capture) {
    throw '-Editor 与 -Capture 不能同时使用。'
}
if ($Capture -and $Version -ne 'V1') {
    throw '-Capture 仅用于第一版三组配色采集，第二版／第三版请使用游戏内F12截图。'
}

# 2. 用脚本所在目录定位工程，避免依赖调用终端的当前路径。
$engineArguments = @('--path', $PSScriptRoot)
$scenePath = switch ($Version) {
    'V1' { 'res://scenes/snow_playground.tscn' }
    'V2' { 'res://scenes/world/snow_valley.tscn' }
    'V3' { 'res://scenes/v3/snow_valley_v3.tscn' }
}
if ($Editor) {
    # 各版显式选择场景；M15离线交付默认进入已确认的第三版。
    $engineArguments += @('--editor', $scenePath)
}
if ($Capture) {
    # 原配色采集仅属于第一版，不能因主场景切换误启动山谷。
    $engineArguments += @($scenePath, '--quit-after', '600', '--', '--capture-all')
}
if (-not $Editor -and -not $Capture) {
    # 默认进入第三版；显式-VersionV1或V2保留旧玩法和各自存档目录。
    $engineArguments += $scenePath
}

# 3. 保留真实图形渲染，截图模式由场景在采集完成后退出。
& $enginePath @engineArguments
exit $LASTEXITCODE
