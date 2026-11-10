param(
    [ValidateSet('Install','Uninstall','Status')][string]$Mode = 'Install',
    [string]$GameDirectory
)
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$packageRoot = $PSScriptRoot
$lockStream = $null
$journal = $null
$journalPath = $null
$temporarySuffix = '.hew-korean-new'

function Get-Hash([string]$Path) {
    if (-not [IO.File]::Exists($Path)) { return $null }
    $algorithm = [Security.Cryptography.SHA256]::Create()
    $inputStream = [IO.File]::OpenRead($Path)
    try { return ([BitConverter]::ToString($algorithm.ComputeHash($inputStream))).Replace('-','').ToLowerInvariant() }
    finally { $inputStream.Dispose(); $algorithm.Dispose() }
}
function Get-SafePath([string]$Root, [string]$Relative) {
    if ([string]::IsNullOrWhiteSpace($Relative) -or [IO.Path]::IsPathRooted($Relative) -or $Relative.Contains(':') -or ($Relative -split '[/\\]' | Where-Object { $_ -eq '..' -or $_ -eq '.' })) { throw "잘못된 상대 경로: $Relative" }
    $result = [IO.Path]::GetFullPath((Join-Path $Root $Relative))
    if (-not $result.StartsWith($Root.TrimEnd('\')+'\',[StringComparison]::OrdinalIgnoreCase)) { throw '허용 경로를 벗어났습니다.' }
    $probe = $result
    while ($probe.Length -ge $Root.Length) {
        if (Test-Path -LiteralPath $probe) {
            if ((Get-Item -LiteralPath $probe -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "연결 경로에는 적용하지 않습니다: $probe" }
        }
        $probe = Split-Path -Parent $probe
        if (-not $probe) { break }
    }
    return $result
}
function Write-JsonAtomic([string]$Path, $Value) {
    $temporary = $Path + '.new'
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Value | ConvertTo-Json -Depth 25))
    $stream = [IO.File]::Open($temporary,[IO.FileMode]::Create,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try { $stream.Write($bytes,0,$bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary,$Path,[System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($temporary,$Path) }
}
function Set-GameFile([string]$Target, [string]$Source, [string]$ExpectedHash) {
    if ((Get-Hash $Source) -ne $ExpectedHash) { throw '복원할 파일의 내용이 일치하지 않습니다.' }
    # 원본은 마지막 교체까지 유지하고, 같은 드라이브의 준비 파일을 원자적으로 교체합니다.
    $temporary = $Target + $temporarySuffix
    if (Test-Path -LiteralPath $temporary) { throw "이전 설치의 임시 파일을 확인해야 합니다: $temporary" }
    try {
        [IO.File]::Copy($Source,$temporary,$false)
        $stream = [IO.File]::Open($temporary,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
        try { $stream.Flush($true) } finally { $stream.Dispose() }
        if ((Get-Hash $temporary) -ne $ExpectedHash) { throw '설치 임시 파일의 내용이 일치하지 않습니다.' }
        [IO.File]::Replace($temporary,$Target,[System.Management.Automation.Language.NullString]::Value,$true)
    } finally {
        if ([IO.File]::Exists($temporary)) { Remove-Item -LiteralPath $temporary -Force }
    }
}
function Restore-Transaction($Transaction) {
    if ($Transaction.game_directory -ne $gameRoot -or $Transaction.manifest_sha256 -ne $manifestHash) { throw '이전 설치 기록의 대상·버전이 다릅니다.' }
    if ($Transaction.entries.Count -ne $manifest.changes.Count) { throw '이전 설치 기록의 파일 수가 다릅니다.' }
    # 모든 기록·현재 파일·복원 원본을 먼저 확인하여 일부만 복구되는 상황을 줄입니다.
    for ($i=0; $i -lt $manifest.changes.Count; $i++) {
        $change = $manifest.changes[$i]; $entry = $Transaction.entries[$i]
        if ($entry.path -ne $change.path -or $entry.before -notin @($change.original_sha256,$change.patched_sha256)) { throw '이전 설치 기록의 원본 상태가 다릅니다.' }
        $target = Get-SafePath $gameRoot $change.path
        $current = Get-Hash $target
        if ($current -notin @($change.original_sha256,$change.patched_sha256)) { throw "설치 중 다른 내용으로 바뀐 파일은 덮어쓰지 않습니다: $($change.path)" }
        if ($current -ne $entry.before) {
            $kind = if ($entry.before -eq $change.original_sha256) { 'original' } else { 'patched' }
            if ((Get-Hash (Get-SafePath $stateRoot ('cache/'+$i+'/'+$kind))) -ne $entry.before) { throw '복구 원본이 손상됐습니다.' }
        }
    }
    for ($i=0; $i -lt $manifest.changes.Count; $i++) {
        $change = $manifest.changes[$i]; $entry = $Transaction.entries[$i]
        $target = Get-SafePath $gameRoot $change.path
        $temporary = $target + $temporarySuffix
        if ([IO.File]::Exists($temporary)) { Remove-Item -LiteralPath $temporary -Force }
        if ((Get-Hash $target) -ne $entry.before) {
            $kind = if ($entry.before -eq $change.original_sha256) { 'original' } else { 'patched' }
            Set-GameFile $target (Get-SafePath $stateRoot ('cache/'+$i+'/'+$kind)) $entry.before
        }
        if ((Get-Hash $target) -ne $entry.before) { throw '복구 후 파일 확인에 실패했습니다.' }
    }
    $Transaction.phase = 'ROLLED_BACK'
    Write-JsonAtomic $journalPath $Transaction
    Write-Host '중단된 설치를 시작 전 상태로 복원했습니다.'
}

try {
    if ([string]::IsNullOrWhiteSpace($GameDirectory)) {
        . (Join-Path $packageRoot 'ChooseGame.ps1')
        $GameDirectory = Show-GameLocationDialog $Mode
        if ([string]::IsNullOrWhiteSpace($GameDirectory)) {
            Write-Host '취소했습니다. 게임 파일은 변경하지 않았습니다.'
            return
        }
    }
    $gameRoot = [IO.Path]::GetFullPath($GameDirectory).TrimEnd('\')
    if (-not [IO.File]::Exists((Join-Path $gameRoot 'HowEmpiresWork.exe'))) { throw 'HowEmpiresWork.exe가 있는 게임 폴더를 지정해 주세요.' }
    $null = Get-SafePath $gameRoot 'HowEmpiresWork.exe'
    $manifestPath = Join-Path $packageRoot 'manifest.json'
    $manifest = Get-Content -LiteralPath $manifestPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($manifest.game_id -ne 'HOW_EMPIRES_WORK' -or $manifest.steam_build -ne '26482667' -or $manifest.version -ne '1.0.1') { throw '지원하지 않는 패치 목록입니다.' }
    $manifestHash = Get-Hash $manifestPath
    foreach ($running in @(Get-Process -Name 'HowEmpiresWork' -ErrorAction SilentlyContinue)) {
        try { $runningPath = $running.Path } catch { throw '게임 실행 경로를 확인할 수 없습니다. 게임을 종료해 주세요.' }
        if (-not $runningPath -or [IO.Path]::GetFullPath($runningPath).Equals((Join-Path $gameRoot 'HowEmpiresWork.exe'),[StringComparison]::OrdinalIgnoreCase)) { throw '적용 대상 게임이 실행 중입니다. 게임을 종료한 뒤 다시 실행해 주세요.' }
    }
    $changeMap = @{}
    $baselineMap = @{}
    foreach ($file in $manifest.baseline) {
        $null = Get-SafePath $gameRoot $file.path
        if ($baselineMap.ContainsKey($file.path) -or $file.sha256 -notmatch '^[0-9a-f]{64}$') { throw '원본 목록이 올바르지 않습니다.' }
        $baselineMap[$file.path] = $file
    }
    foreach ($change in $manifest.changes) {
        $null = Get-SafePath $gameRoot $change.path
        if ($changeMap.ContainsKey($change.path) -or -not $baselineMap.ContainsKey($change.path) -or $change.original_sha256 -ne $baselineMap[$change.path].sha256 -or $change.patched_sha256 -notmatch '^[0-9a-f]{64}$') { throw '수정 목록이 올바르지 않습니다.' }
        $null = Get-SafePath $packageRoot $change.forward
        $null = Get-SafePath $packageRoot $change.reverse
        $changeMap[$change.path] = $change
    }
    if ($changeMap.Count -lt 1) { throw '수정 파일이 없습니다.' }
    $payloadMap = @{}
    foreach ($file in $manifest.payload) {
        $path = Get-SafePath $packageRoot $file.path
        if ($payloadMap.ContainsKey($file.path) -or (Get-Hash $path) -ne $file.sha256 -or ([IO.FileInfo]::new($path)).Length -ne $file.size) { throw "패치 구성 파일이 손상됐습니다: $($file.path)" }
        $payloadMap[$file.path] = $file
    }
    foreach ($required in @('tools/xdelta3.exe','Patch.ps1','ChooseGame.ps1')) {
        if (-not $payloadMap.ContainsKey($required)) { throw '필수 패치 구성 파일이 없습니다.' }
    }
    foreach ($change in $manifest.changes) {
        if (-not $payloadMap.ContainsKey($change.forward) -or -not $payloadMap.ContainsKey($change.reverse)) { throw '차이 파일이 목록에 없습니다.' }
    }
    $sha = [Security.Cryptography.SHA256]::Create()
    try { $rootKey = ([BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($gameRoot.ToLowerInvariant())))).Replace('-','').Substring(0,16) } finally { $sha.Dispose() }
    $stateRoot = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA ('HowEmpiresWorkKoreanPatch\working_private\'+$rootKey+'\build_26482667')))
    $null = Get-SafePath ([IO.Path]::GetFullPath($env:LOCALAPPDATA)) ('HowEmpiresWorkKoreanPatch\working_private\'+$rootKey+'\build_26482667')
    $null = New-Item -ItemType Directory -Path $stateRoot -Force
    $lockStream = [IO.File]::Open((Get-SafePath $stateRoot 'install.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
    $journalPath = Get-SafePath $stateRoot 'transaction.json'
    if ([IO.File]::Exists($journalPath)) {
        $previous = Get-Content -LiteralPath $journalPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($previous.phase -eq 'APPLYING') { Restore-Transaction $previous }
    }
    foreach ($file in $manifest.baseline) {
        $actual = Get-Hash (Get-SafePath $gameRoot $file.path)
        $expected = @($file.sha256)
        if ($changeMap.ContainsKey($file.path)) { $expected += $changeMap[$file.path].patched_sha256 }
        if ($actual -notin $expected) { throw "게임 버전이 다르거나 파일이 변경됐습니다: $($file.path)" }
    }
    $states = @()
    foreach ($change in $manifest.changes) {
        $states += [ordered]@{path=$change.path;before=(Get-Hash (Get-SafePath $gameRoot $change.path))}
    }
    $installedCount = @($manifest.changes | Where-Object { (Get-Hash (Get-SafePath $gameRoot $_.path)) -eq $_.patched_sha256 }).Count
    if ($Mode -eq 'Status') {
        [ordered]@{mode=$Mode;game_directory=$gameRoot;patched_files=$installedCount;total=$manifest.changes.Count;backup_directory=$stateRoot} | ConvertTo-Json
        return
    }
    $decoder = Get-SafePath $packageRoot 'tools/xdelta3.exe'
    for ($i=0; $i -lt $manifest.changes.Count; $i++) {
        $change=$manifest.changes[$i]; $target=Get-SafePath $gameRoot $change.path
        $cacheDir=Get-SafePath $stateRoot ('cache/'+$i)
        $null=New-Item -ItemType Directory -Path $cacheDir -Force
        $original=Get-SafePath $cacheDir 'original'; $patched=Get-SafePath $cacheDir 'patched'
        if ([IO.File]::Exists($original)) {
            if ((Get-Hash $original) -ne $change.original_sha256) { throw '원본 백업이 손상됐습니다.' }
        } else {
            # 백업 복사 중 강제 종료돼도 완성된 백업과 구별하도록 준비 파일에 씁니다.
            $originalPending = $original + '.new'
            if ([IO.File]::Exists($originalPending)) { Remove-Item -LiteralPath $originalPending -Force }
            if ((Get-Hash $target) -eq $change.original_sha256) { [IO.File]::Copy($target,$originalPending,$false) }
            else {
                & $decoder -d -f -s $target (Get-SafePath $packageRoot $change.reverse) $originalPending
                if ($LASTEXITCODE -ne 0) { throw '원본 복원 파일 생성에 실패했습니다.' }
            }
            if ((Get-Hash $originalPending) -ne $change.original_sha256) { throw '원본 백업 준비 확인에 실패했습니다.' }
            $stream = [IO.File]::Open($originalPending,[IO.FileMode]::Open,[IO.FileAccess]::Write,[IO.FileShare]::None)
            try { $stream.Flush($true) } finally { $stream.Dispose() }
            [IO.File]::Move($originalPending,$original)
        }
        if ((Get-Hash $original) -ne $change.original_sha256) { throw '원본 백업 확인에 실패했습니다.' }
        if ((Get-Hash $patched) -ne $change.patched_sha256) {
            & $decoder -d -f -s $original (Get-SafePath $packageRoot $change.forward) $patched
            if ($LASTEXITCODE -ne 0 -or (Get-Hash $patched) -ne $change.patched_sha256) { throw "패치 파일 생성에 실패했습니다: $($change.path)" }
        }
    }
    $journal = [ordered]@{phase='APPLYING';mode=$Mode;game_directory=$gameRoot;manifest_sha256=$manifestHash;started=(Get-Date).ToString('o');entries=$states}
    Write-JsonAtomic $journalPath $journal
    for ($i=0; $i -lt $manifest.changes.Count; $i++) {
        $change=$manifest.changes[$i]; $target=Get-SafePath $gameRoot $change.path
        if ((Get-Hash $target) -ne $states[$i].before) { throw '준비 중 게임 파일이 변경됐습니다.' }
        $kind=if ($Mode -eq 'Install') { 'patched' } else { 'original' }
        $expected=if ($Mode -eq 'Install') { $change.patched_sha256 } else { $change.original_sha256 }
        if ((Get-Hash $target) -ne $expected) { Set-GameFile $target (Get-SafePath $stateRoot ('cache/'+$i+'/'+$kind)) $expected }
        Write-Host ('[{0}/{1}] {2}' -f ($i+1),$manifest.changes.Count,$change.path)
    }
    foreach ($change in $manifest.changes) {
        $expected=if ($Mode -eq 'Install') { $change.patched_sha256 } else { $change.original_sha256 }
        if ((Get-Hash (Get-SafePath $gameRoot $change.path)) -ne $expected) { throw '최종 파일 확인에 실패했습니다.' }
    }
    # 완료 영수증까지 저장된 뒤에만 거래를 끝냅니다. 영수증 오류도 되돌림 대상입니다.
    $receipt=[ordered]@{status='COMPLETE';mode=$Mode;version=$manifest.version;candidate=$manifest.candidate;game_directory=$gameRoot;manifest_sha256=$manifestHash;files=$manifest.changes.Count;completed=(Get-Date).ToString('o');backup_directory=$stateRoot}
    Write-JsonAtomic (Get-SafePath $stateRoot 'receipt.json') $receipt
    $journal.phase='COMPLETE'
    Write-JsonAtomic $journalPath $journal
    if ($Mode -eq 'Install') { Write-Host '한글패치 적용 완료. Steam에서 게임을 실행하세요.' } else { Write-Host '원본 복원 완료.' }
    Write-Host ('원본 백업: '+$stateRoot)
} catch {
    $failure=$_
    if ($null -ne $journal -and $journal.phase -in @('APPLYING','COMPLETE')) {
        try { Restore-Transaction $journal } catch { Write-Error ('복구 기록을 보존했습니다. 같은 설치기를 다시 실행하세요. '+$_.Exception.Message) -ErrorAction Continue }
    }
    Write-Error $failure -ErrorAction Continue
    exit 1
} finally {
    if ($null -ne $lockStream) { $lockStream.Dispose() }
}
