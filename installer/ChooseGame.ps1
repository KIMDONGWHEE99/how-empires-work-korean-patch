# Steam 라이브러리와 이전 설치 위치를 읽어 폴더 선택 창에 표시합니다.
function Get-SteamRoots {
    $locations = @(
        @('HKCU:\Software\Valve\Steam', 'SteamPath'),
        @('HKLM:\SOFTWARE\WOW6432Node\Valve\Steam', 'InstallPath'),
        @('HKLM:\SOFTWARE\Valve\Steam', 'InstallPath')
    )
    foreach ($location in $locations) {
        $item = Get-ItemProperty -LiteralPath $location[0] -ErrorAction SilentlyContinue
        if ($null -ne $item) {
            $property = $item.PSObject.Properties[$location[1]]
            if ($null -ne $property -and $property.Value) { [string]$property.Value }
        }
    }
    foreach ($base in @(${env:ProgramFiles(x86)}, $env:ProgramFiles)) {
        if ($base) { Join-Path $base 'Steam' }
    }
}

function Resolve-GameLocation([string]$Path) {
    if ([string]::IsNullOrWhiteSpace($Path)) { return $null }
    try {
        $resolved = [IO.Path]::GetFullPath($Path.Trim().Trim('"')).TrimEnd('\')
        if ([IO.File]::Exists($resolved) -and [IO.Path]::GetFileName($resolved) -ieq 'HowEmpiresWork.exe') {
            $resolved = [IO.Path]::GetDirectoryName($resolved)
        }
        if ([IO.File]::Exists((Join-Path $resolved 'HowEmpiresWork.exe')) -and
            [IO.File]::Exists((Join-Path $resolved 'HowEmpiresWork.pck'))) { return $resolved }
    } catch { return $null }
    return $null
}

function Get-GameLocations(
    [string[]]$SteamRoots = @(Get-SteamRoots),
    [string[]]$NearbyPaths = @($PSScriptRoot, (Split-Path -Parent $PSScriptRoot)),
    [string]$ReceiptRoot = (Join-Path $env:LOCALAPPDATA 'HowEmpiresWorkKoreanPatch\working_private')
) {
    $libraries = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $candidates = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($root in $SteamRoots) {
        if ([string]::IsNullOrWhiteSpace($root)) { continue }
        try { $root = [IO.Path]::GetFullPath($root) } catch { continue }
        $null = $libraries.Add($root)
        foreach ($relative in @('steamapps\libraryfolders.vdf', 'config\libraryfolders.vdf')) {
            $vdf = Join-Path $root $relative
            if (-not [IO.File]::Exists($vdf)) { continue }
            try { $content = [IO.File]::ReadAllText($vdf) } catch { continue }
            # 현재 형식의 path 필드와 구형의 숫자 키를 모두 지원합니다.
            foreach ($match in [regex]::Matches($content, '(?m)^\s*"(?:path|[0-9]+)"\s+"([^"\r\n]+)"')) {
                $path = $match.Groups[1].Value.Replace('\\', '\')
                if ([IO.Path]::IsPathRooted($path)) { $null = $libraries.Add($path) }
            }
        }
    }
    foreach ($library in $libraries) {
        $common = Join-Path $library 'steamapps\common'
        $null = $candidates.Add((Join-Path $common 'How Empires Work'))
        $appManifest = Join-Path $library 'steamapps\appmanifest_4663730.acf'
        if ([IO.File]::Exists($appManifest)) {
            try {
                $match = [regex]::Match([IO.File]::ReadAllText($appManifest), '"installdir"\s+"([^"\r\n]+)"')
                if ($match.Success) {
                    $installName = $match.Groups[1].Value
                    if ($installName -notin @('.', '..') -and $installName.IndexOfAny([IO.Path]::GetInvalidFileNameChars()) -lt 0) {
                        $null = $candidates.Add((Join-Path $common $installName))
                    }
                }
            } catch { continue }
        }
    }
    foreach ($path in $NearbyPaths) { if ($path) { $null = $candidates.Add($path) } }
    if ($ReceiptRoot -and [IO.Directory]::Exists($ReceiptRoot)) {
        foreach ($file in @(Get-ChildItem -LiteralPath $ReceiptRoot -Filter 'receipt.json' -File -Recurse -ErrorAction SilentlyContinue)) {
            $receiptPath = $file.FullName
            if (-not [IO.File]::Exists($receiptPath)) { continue }
            try {
                $receipt = [IO.File]::ReadAllText($receiptPath) | ConvertFrom-Json
                $property = $receipt.PSObject.Properties['game_directory']
                if ($null -ne $property -and $property.Value) { $null = $candidates.Add([string]$property.Value) }
            } catch { continue }
        }
    }
    $valid = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($path in $candidates) {
        $resolved = Resolve-GameLocation $path
        if ($resolved) { $null = $valid.Add($resolved) }
    }
    $valid | Sort-Object
}

function New-GameLocationForm([string]$Mode, [string[]]$Candidates) {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [Windows.Forms.Application]::EnableVisualStyles()
    $action = switch ($Mode) { 'Uninstall' { '제거' } 'Status' { '확인' } default { '설치' } }
    $form = [Windows.Forms.Form]::new()
    $form.Text = 'How Empires Work 한국어 패치 1.0.1'
    $form.Font = [Drawing.Font]::new('맑은 고딕', 10)
    $form.AutoScaleMode = [Windows.Forms.AutoScaleMode]::Font
    $form.ClientSize = [Drawing.Size]::new(700, 220)
    $form.FormBorderStyle = [Windows.Forms.FormBorderStyle]::FixedDialog
    $form.StartPosition = [Windows.Forms.FormStartPosition]::CenterScreen
    $form.MaximizeBox = $false
    $form.MinimizeBox = $false
    $form.Tag = $null

    $layout = [Windows.Forms.TableLayoutPanel]::new()
    $layout.Dock = 'Fill'
    $layout.Padding = [Windows.Forms.Padding]::new(16)
    $layout.ColumnCount = 2
    $layout.RowCount = 4
    $null = $layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Percent, 100))
    $null = $layout.ColumnStyles.Add([Windows.Forms.ColumnStyle]::new([Windows.Forms.SizeType]::Absolute, 112))
    foreach ($height in @(42, 40, 50, 56)) {
        $null = $layout.RowStyles.Add([Windows.Forms.RowStyle]::new([Windows.Forms.SizeType]::Absolute, $height))
    }
    $heading = [Windows.Forms.Label]::new()
    $heading.Text = "게임 폴더를 확인한 뒤 [$action]를 눌러주세요."
    $heading.AutoSize = $true
    $heading.Anchor = 'Left'
    $layout.Controls.Add($heading, 0, 0)
    $layout.SetColumnSpan($heading, 2)

    $pathBox = [Windows.Forms.ComboBox]::new()
    $pathBox.Name = 'GameDirectory'
    $pathBox.Dock = 'Fill'
    $pathBox.DropDownStyle = 'DropDown'
    $pathBox.AutoCompleteMode = 'SuggestAppend'
    $pathBox.AutoCompleteSource = 'ListItems'
    foreach ($path in $Candidates) { $null = $pathBox.Items.Add($path) }
    if ($pathBox.Items.Count -gt 0) { $pathBox.SelectedIndex = 0 }
    $layout.Controls.Add($pathBox, 0, 1)

    $browse = [Windows.Forms.Button]::new()
    $browse.Text = '찾아보기…'
    $browse.Dock = 'Fill'
    $browse.Add_Click({
        $dialog = [Windows.Forms.FolderBrowserDialog]::new()
        $dialog.Description = 'HowEmpiresWork.exe가 들어 있는 게임 폴더를 선택하세요.'
        $dialog.ShowNewFolderButton = $false
        if ([IO.Directory]::Exists($pathBox.Text)) { $dialog.SelectedPath = $pathBox.Text }
        try {
            if ($dialog.ShowDialog($form) -eq [Windows.Forms.DialogResult]::OK) { $pathBox.Text = $dialog.SelectedPath }
        } finally { $dialog.Dispose() }
    }.GetNewClosure())
    $layout.Controls.Add($browse, 1, 1)

    $hint = [Windows.Forms.Label]::new()
    $hint.Dock = 'Fill'
    $hint.Text = if ($pathBox.Items.Count -gt 0) {
        '찾은 게임 위치를 표시했습니다. 다른 위치라면 [찾아보기…]로 바꿔주세요.'
    } else { '게임 위치를 찾지 못했습니다. [찾아보기…]에서 How Empires Work 폴더를 선택하세요.' }
    $layout.Controls.Add($hint, 0, 2)
    $layout.SetColumnSpan($hint, 2)

    $buttons = [Windows.Forms.FlowLayoutPanel]::new()
    $buttons.Dock = 'Fill'
    $buttons.FlowDirection = 'RightToLeft'
    $cancel = [Windows.Forms.Button]::new()
    $cancel.Text = '취소'
    $cancel.Size = [Drawing.Size]::new(100, 34)
    $cancel.DialogResult = [Windows.Forms.DialogResult]::Cancel
    $confirm = [Windows.Forms.Button]::new()
    $confirm.Name = 'Confirm'
    $confirm.Text = $action
    $confirm.Size = [Drawing.Size]::new(100, 34)
    $confirm.Add_Click({
        $selected = Resolve-GameLocation $pathBox.Text
        if (-not $selected) {
            $null = [Windows.Forms.MessageBox]::Show($form, 'HowEmpiresWork.exe가 들어 있는 게임 폴더를 선택해 주세요.', '게임 폴더 확인', [Windows.Forms.MessageBoxButtons]::OK, [Windows.Forms.MessageBoxIcon]::Information)
            return
        }
        $form.Tag = $selected
        $form.DialogResult = [Windows.Forms.DialogResult]::OK
        $form.Close()
    }.GetNewClosure())
    $buttons.Controls.Add($cancel)
    $buttons.Controls.Add($confirm)
    $layout.Controls.Add($buttons, 0, 3)
    $layout.SetColumnSpan($buttons, 2)
    $form.AcceptButton = $confirm
    $form.CancelButton = $cancel
    $form.Controls.Add($layout)
    return $form
}

function Show-GameLocationDialog([string]$Mode) {
    $form = New-GameLocationForm $Mode @(Get-GameLocations)
    try {
        if ($form.ShowDialog() -eq [Windows.Forms.DialogResult]::OK) { return [string]$form.Tag }
        return $null
    } finally { $form.Dispose() }
}
