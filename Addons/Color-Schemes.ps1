# Color Schemes - an addon for Cybtek Downloader (needs Cybtek Downloader 1.4 or later).
#
# Adds "Color Scheme" to the Addons menu, with a pop-out list of colour schemes to switch between
# and "Create Custom..." at the bottom to design your own. The first time it is installed it asks
# which scheme to use.
#
# Every scheme is a .json file in the color-schemes folder next to this addon ($PSScriptRoot\color-schemes,
# which is %APPDATA%\CybtekDownloader\addons\color-schemes once installed). The built-in schemes are
# written there the first time; custom schemes are saved there too, so you can copy, share or edit them.
#
# Install: Addons > Install Addon... in Cybtek Downloader, then choose this file.

@{
    Name        = 'Color Schemes'
    Version     = '1.0'
    Author      = 'Cybtek Downloader'
    Description = 'Changes the colours of Cybtek Downloader. Pick one of the built-in schemes or create your own.'
    MenuText    = 'Color Scheme'

    OnLoad = {
        param($App, $Self)
        if (-not $App.SetColors) { throw 'This addon needs Cybtek Downloader 1.4 or later.' }
        $script:ColorSchemes_App = $App
        $script:ColorSchemes_Dir = Join-Path $Self.Folder 'color-schemes'
        $script:ColorSchemes_SelectedFile = Join-Path $script:ColorSchemes_Dir 'selected.txt'

        # The built-in schemes, in menu order. Each colour is "#RRGGBB".
        $script:ColorSchemes_BuiltIn = [ordered]@{
            'Cybtek Blue' = @{ Light = $false; Colors = [ordered]@{
                Back = '#070D1A'; Panel = '#0B162A'; Input = '#0E1E38'; Hover = '#14345A'; Border = '#204A78'
                Accent = '#00A8FF'; AccentLight = '#5ADEFF'; Text = '#E8F1FF'; Muted = '#8CA5C8'; Disabled = '#556987'
                Good = '#46DCA0'; Warn = '#FFB84D'; Bad = '#FF6373' } }
            'Metro Dark' = @{ Light = $false; Colors = [ordered]@{
                Back = '#1D1D1D'; Panel = '#2D2D30'; Input = '#252526'; Hover = '#3E3E42'; Border = '#555555'
                Accent = '#1BA1E2'; AccentLight = '#4FC1F0'; Text = '#F1F1F1'; Muted = '#A0A0A0'; Disabled = '#6D6D6D'
                Good = '#60A917'; Warn = '#F0A30A'; Bad = '#E51400' } }
            'Metro Light' = @{ Light = $true; Colors = [ordered]@{
                Back = '#FFFFFF'; Panel = '#F0F0F0'; Input = '#FFFFFF'; Hover = '#E1E1E1'; Border = '#ABABAB'
                Accent = '#0078D7'; AccentLight = '#005A9E'; Text = '#1E1E1E'; Muted = '#616161'; Disabled = '#A0A0A0'
                Good = '#107C10'; Warn = '#B35900'; Bad = '#C50F1F' } }
            'Midnight Purple' = @{ Light = $false; Colors = [ordered]@{
                Back = '#110A1E'; Panel = '#1A1030'; Input = '#22163D'; Hover = '#33205A'; Border = '#4E3388'
                Accent = '#A259FF'; AccentLight = '#D4AEFF'; Text = '#F2EBFF'; Muted = '#A99BC9'; Disabled = '#66597F'
                Good = '#4ADE9E'; Warn = '#FFC266'; Bad = '#FF6B8B' } }
            'Emerald Forest' = @{ Light = $false; Colors = [ordered]@{
                Back = '#06130E'; Panel = '#0B1F17'; Input = '#0F2A1F'; Hover = '#164231'; Border = '#20614A'
                Accent = '#10B981'; AccentLight = '#6EE7B7'; Text = '#E9FFF5'; Muted = '#92C4AE'; Disabled = '#4F7565'
                Good = '#A3E635'; Warn = '#FBBF24'; Bad = '#F87171' } }
            'Sunset Orange' = @{ Light = $false; Colors = [ordered]@{
                Back = '#170D08'; Panel = '#24140C'; Input = '#301B10'; Hover = '#4A2915'; Border = '#6E3E1F'
                Accent = '#FF7A1A'; AccentLight = '#FFB46B'; Text = '#FFF4EA'; Muted = '#C9A58C'; Disabled = '#7A5E4C'
                Good = '#5EE0A0'; Warn = '#FFD166'; Bad = '#FF5C5C' } }
            'Crimson Night' = @{ Light = $false; Colors = [ordered]@{
                Back = '#15070A'; Panel = '#210B10'; Input = '#2C0F16'; Hover = '#461720'; Border = '#6B2231'
                Accent = '#E11D48'; AccentLight = '#FF7A93'; Text = '#FFEEF1'; Muted = '#C99AA4'; Disabled = '#7A5560'
                Good = '#4ADE80'; Warn = '#FBBF24'; Bad = '#FF4D6D' } }
        }

        # What each colour is used for, as shown in the custom scheme editor
        $script:ColorSchemes_Labels = [ordered]@{
            Back = 'Window background'; Panel = 'Menu bar and panels'; Input = 'Text boxes and lists'; Hover = 'Buttons'
            Border = 'Borders and lines'; Accent = 'Accent (progress bar)'; AccentLight = 'Highlighted text'; Text = 'Text'
            Muted = 'Hints and secondary text'; Disabled = 'Disabled text'; Good = 'Status: all good'
            Warn = 'Status: needs attention'; Bad = 'Status: problem'
        }

        function script:ColorSchemes_FilePath([string]$Name) {
            $safe = ($Name -replace '[\\/:*?"<>|]', '').Trim()
            Join-Path $script:ColorSchemes_Dir "$safe.json"
        }

        function script:ColorSchemes_Write([string]$Name, [bool]$Light, $Colors) {
            $doc = [ordered]@{ Name = $Name; Light = $Light; Colors = [ordered]@{} }
            foreach ($n in $script:ColorSchemes_App.ColorNames) { if ($Colors[$n]) { $doc.Colors[$n] = [string]$Colors[$n] } }
            $json = $doc | ConvertTo-Json -Depth 4
            [IO.File]::WriteAllText((ColorSchemes_FilePath $Name), $json, (New-Object System.Text.UTF8Encoding($false)))
        }

        # All schemes in the folder: built-in ones first, in their usual order, then custom ones by name
        function script:ColorSchemes_Load {
            $builtInNames = @($script:ColorSchemes_BuiltIn.Keys)
            $list = New-Object System.Collections.Generic.List[object]
            foreach ($f in @(Get-ChildItem -LiteralPath $script:ColorSchemes_Dir -Filter '*.json' -File -ErrorAction SilentlyContinue)) {
                try {
                    $j = [IO.File]::ReadAllText($f.FullName) | ConvertFrom-Json
                    $colors = @{}
                    foreach ($n in $script:ColorSchemes_App.ColorNames) {
                        $value = [string]$j.Colors.$n
                        if ($value -match '^#[0-9A-Fa-f]{6}$') { $colors[$n] = $value }
                    }
                    if (-not $colors.Count) { throw 'it has no colours' }
                    $name = if ($j.Name) { [string]$j.Name } else { $f.BaseName }
                    $index = [Array]::IndexOf($builtInNames, $name)
                    $list.Add([pscustomobject]@{
                        Name = $name; Light = [bool]$j.Light; Colors = $colors; File = $f.FullName
                        BuiltIn = $index -ge 0; Order = $(if ($index -ge 0) { $index } else { 1000 })
                    })
                } catch {
                    & $script:ColorSchemes_App.Log "Color Schemes: skipped $($f.Name) ($($_.Exception.Message))."
                }
            }
            @($list | Sort-Object Order, Name)
        }

        function script:ColorSchemes_GetSelected {
            if (Test-Path -LiteralPath $script:ColorSchemes_SelectedFile) {
                ([IO.File]::ReadAllText($script:ColorSchemes_SelectedFile)).Trim()
            } else { $null }
        }

        function script:ColorSchemes_Apply($Scheme, [switch]$Remember) {
            $colors = @{}
            foreach ($k in $Scheme.Colors.Keys) { $colors[$k] = $Scheme.Colors[$k] }
            $colors['Light'] = [bool]$Scheme.Light
            & $script:ColorSchemes_App.SetColors $colors
            if ($Remember) {
                [IO.File]::WriteAllText($script:ColorSchemes_SelectedFile, $Scheme.Name, (New-Object System.Text.UTF8Encoding($false)))
                & $script:ColorSchemes_App.Log "Color scheme: $($Scheme.Name)."
            }
        }

        function script:ColorSchemes_ApplyByName([string]$Name) {
            $scheme = ColorSchemes_Load | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
            if ($scheme) { ColorSchemes_Apply $scheme -Remember }
        }

        # Draws a small mock-up of the main window in a scheme's colours
        function script:ColorSchemes_DrawPreview($Graphics, [System.Drawing.Rectangle]$Bounds, $Scheme) {
            $c = @{}
            foreach ($k in $Scheme.Colors.Keys) { $c[$k] = [System.Drawing.ColorTranslator]::FromHtml($Scheme.Colors[$k]) }
            $g = $Graphics
            $g.SmoothingMode = 'AntiAlias'
            $font = New-Object System.Drawing.Font('Segoe UI', 8.5)
            $bold = New-Object System.Drawing.Font('Segoe UI Semibold', 9)
            $x = $Bounds.X; $y = $Bounds.Y; $w = $Bounds.Width
            $fill = { param($color, $rx, $ry, $rw, $rh) $b = New-Object System.Drawing.SolidBrush($color); $g.FillRectangle($b, $rx, $ry, $rw, $rh); $b.Dispose() }
            $line = { param($color, $rx, $ry, $rw, $rh) $p = New-Object System.Drawing.Pen($color); $g.DrawRectangle($p, $rx, $ry, $rw, $rh); $p.Dispose() }
            $text = { param($s, $f, $color, $tx, $ty) [System.Windows.Forms.TextRenderer]::DrawText($g, $s, $f, (New-Object System.Drawing.Point($tx, $ty)), $color) }

            & $fill $c.Back $x $y $w $Bounds.Height
            & $fill $c.Panel $x $y $w 24
            & $text 'File   Source   Addons   Help' $font $c.Text ($x + 8) ($y + 4)
            & $fill $c.Panel $x ($y + 24) $w 22
            & $fill $c.Border $x ($y + 46) $w 1
            & $text ("$([char]0x25CF)  Dependencies installed and up to date") $font $c.Good ($x + 8) ($y + 28)
            & $text 'YouTube URL:' $font $c.AccentLight ($x + 10) ($y + 56)
            & $fill $c.Input ($x + 10) ($y + 76) ($w - 20) 22
            & $line $c.Border ($x + 10) ($y + 76) ($w - 21) 21
            & $text 'https://www.youtube.com/watch?v=...' $font $c.Text ($x + 14) ($y + 79)
            $bw = [int](($w - 30) / 2)
            foreach ($i in 0, 1) {
                $bx = $x + 10 + $i * ($bw + 10)
                & $fill $c.Hover $bx ($y + 108) $bw 30
                & $line $c.Border $bx ($y + 108) ($bw - 1) 29
                & $text $(if ($i -eq 0) { 'Download Video' } else { 'Download Audio' }) $bold $c.Text ($bx + 10) ($y + 114)
            }
            & $fill $c.Input ($x + 10) ($y + 150) ($w - 20) 12
            $bar = New-Object System.Drawing.Rectangle(($x + 10), ($y + 150), ($w - 20), 12)
            $grad = New-Object System.Drawing.Drawing2D.LinearGradientBrush($bar, $c.Accent, $c.AccentLight, [System.Drawing.Drawing2D.LinearGradientMode]::Horizontal)
            $g.FillRectangle($grad, ($x + 10), ($y + 150), [int](($w - 20) * 0.6), 12)
            $grad.Dispose()
            & $text 'Downloading video: 60%  of 48 MB at 6 MB/s' $font $c.Muted ($x + 10) ($y + 168)
            & $text "$([char]0x25CF) update available" $font $c.Warn ($x + 10) ($y + 190)
            & $text "$([char]0x25CF) missing" $font $c.Bad ($x + 130) ($y + 190)
            $font.Dispose(); $bold.Dispose()
        }

        # Picks a scheme from a list. The whole app changes as you click, so you can try them out.
        function script:ColorSchemes_ShowPicker([switch]$FirstRun) {
            $app = $script:ColorSchemes_App
            $schemes = ColorSchemes_Load
            $before = & $app.GetColors
            $current = ColorSchemes_GetSelected
            if (-not $current) { $current = 'Cybtek Blue' }

            $dlg = New-Object System.Windows.Forms.Form -Property @{
                Text = 'Choose a Color Scheme'; ClientSize = (New-Object System.Drawing.Size(580, 350)); StartPosition = 'CenterParent'
                FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; ShowInTaskbar = $false
                Font = (New-Object System.Drawing.Font('Segoe UI', 9))
            }
            if ($app.Form.Icon) { $dlg.Icon = $app.Form.Icon }
            $intro = if ($FirstRun) {
                "Thanks for installing Color Schemes! Pick the colours you'd like Cybtek Downloader to use. The app changes as " +
                "you click, so you can try them out. You can change it any time from Addons > Color Scheme."
            } else {
                'Pick a colour scheme. The app changes as you click, so you can try them out.'
            }
            $lblIntro = New-Object System.Windows.Forms.Label -Property @{
                Text = $intro; Location = (New-Object System.Drawing.Point(16, 12)); AutoSize = $true; MaximumSize = (New-Object System.Drawing.Size(548, 0))
            }
            $list = New-Object System.Windows.Forms.ListBox -Property @{
                Location = (New-Object System.Drawing.Point(16, 66)); Size = (New-Object System.Drawing.Size(200, 220)); IntegralHeight = $false
                Font = (New-Object System.Drawing.Font('Segoe UI', 10))
            }
            foreach ($s in $schemes) { [void]$list.Items.Add($(if ($s.BuiltIn) { $s.Name } else { "$($s.Name)  (custom)" })) }
            $preview = New-Object System.Windows.Forms.PictureBox -Property @{
                Location = (New-Object System.Drawing.Point(230, 66)); Size = (New-Object System.Drawing.Size(334, 220)); BorderStyle = 'FixedSingle'
            }
            $preview.add_Paint({
                param($s, $e)
                if ($s.Tag) { ColorSchemes_DrawPreview $e.Graphics $s.ClientRectangle $s.Tag }
            })
            $btnCustom = New-Object System.Windows.Forms.Button -Property @{ Text = 'Create Custom...'; Location = (New-Object System.Drawing.Point(16, 302)); Size = (New-Object System.Drawing.Size(130, 30)); DialogResult = 'Retry' }
            $btnOk = New-Object System.Windows.Forms.Button -Property @{ Text = 'Use this scheme'; Location = (New-Object System.Drawing.Point(344, 302)); Size = (New-Object System.Drawing.Size(120, 30)); DialogResult = 'OK' }
            $btnCancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (New-Object System.Drawing.Point(474, 302)); Size = (New-Object System.Drawing.Size(90, 30)); DialogResult = 'Cancel' }
            $dlg.Controls.AddRange(@($lblIntro, $list, $preview, $btnCustom, $btnOk, $btnCancel))
            $dlg.AcceptButton = $btnOk
            $dlg.CancelButton = $btnCancel

            $list.add_SelectedIndexChanged({
                $scheme = $schemes[$list.SelectedIndex]
                $preview.Tag = $scheme
                $preview.Invalidate()
                if ($dlg.Visible) { ColorSchemes_Apply $scheme }
            })
            $index = 0
            for ($i = 0; $i -lt $schemes.Count; $i++) { if ($schemes[$i].Name -eq $current) { $index = $i } }
            if ($schemes.Count) { $list.SelectedIndex = $index }
            # Re-applying the current colours also styles this window to match the app
            $dlg.add_Shown({ & $app.SetColors (& $app.GetColors) })

            $result = $dlg.ShowDialog($app.Form)
            $chosen = if ($list.SelectedIndex -ge 0) { $schemes[$list.SelectedIndex] } else { $null }
            $dlg.Dispose()

            if ($result -eq 'OK' -and $chosen) {
                ColorSchemes_Apply $chosen -Remember
                return
            }
            & $app.SetColors $before
            if ($result -eq 'Retry') { ColorSchemes_ShowEditor }
            if (-not (ColorSchemes_GetSelected)) {
                # First run, closed without choosing: stay with the standard look and don't ask again
                ColorSchemes_ApplyByName 'Cybtek Blue'
            }
        }

        # Lets the user design a scheme, previews it on the app, and saves it as a new .json file
        function script:ColorSchemes_ShowEditor {
            $app = $script:ColorSchemes_App
            $schemes = ColorSchemes_Load
            $before = & $app.GetColors
            $names = @($script:ColorSchemes_Labels.Keys)

            $dlg = New-Object System.Windows.Forms.Form -Property @{
                Text = 'Create Custom Color Scheme'; ClientSize = (New-Object System.Drawing.Size(660, 410)); StartPosition = 'CenterParent'
                FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; ShowInTaskbar = $false
                Font = (New-Object System.Drawing.Font('Segoe UI', 9))
            }
            if ($app.Form.Icon) { $dlg.Icon = $app.Form.Icon }
            $lblName = New-Object System.Windows.Forms.Label -Property @{ Text = 'Scheme name:'; Location = (New-Object System.Drawing.Point(16, 18)); AutoSize = $true }
            $txtName = New-Object System.Windows.Forms.TextBox -Property @{ Location = (New-Object System.Drawing.Point(110, 14)); Width = 200; Text = 'My Scheme' }
            $lblFrom = New-Object System.Windows.Forms.Label -Property @{ Text = 'Start from:'; Location = (New-Object System.Drawing.Point(360, 18)); AutoSize = $true }
            $cmbFrom = New-Object System.Windows.Forms.ComboBox -Property @{ Location = (New-Object System.Drawing.Point(436, 14)); Width = 206; DropDownStyle = 'DropDownList' }
            [void]$cmbFrom.Items.Add('(the current colours)')
            foreach ($s in $schemes) { [void]$cmbFrom.Items.Add($s.Name) }
            $dlg.Controls.AddRange(@($lblName, $txtName, $lblFrom, $cmbFrom))

            # One row per colour: what it is for, a swatch to click, and its hex value
            $rows = @{}
            for ($i = 0; $i -lt $names.Count; $i++) {
                $n = $names[$i]
                $x = if ($i -lt 7) { 16 } else { 340 }
                $y = 60 + ($i % 7) * 34
                $lbl = New-Object System.Windows.Forms.Label -Property @{ Text = $script:ColorSchemes_Labels[$n]; Location = (New-Object System.Drawing.Point($x, ($y + 4))); Size = (New-Object System.Drawing.Size(160, 20)) }
                $swatch = New-Object System.Windows.Forms.PictureBox -Property @{
                    Location = (New-Object System.Drawing.Point(($x + 166), $y)); Size = (New-Object System.Drawing.Size(40, 24))
                    BorderStyle = 'FixedSingle'; Cursor = 'Hand'; Tag = $n
                }
                $hex = New-Object System.Windows.Forms.TextBox -Property @{ Location = (New-Object System.Drawing.Point(($x + 214), $y)); Width = 80; Tag = $n; CharacterCasing = 'Upper' }
                $hex.add_TextChanged({
                    if ($this.Text -match '^#[0-9A-F]{6}$') { $rows[$this.Tag].Swatch.BackColor = [System.Drawing.ColorTranslator]::FromHtml($this.Text) }
                })
                $swatch.add_Click({
                    $row = $rows[$this.Tag]
                    $pick = New-Object System.Windows.Forms.ColorDialog -Property @{ FullOpen = $true; Color = $this.BackColor }
                    if ($pick.ShowDialog($dlg) -eq 'OK') { $row.Hex.Text = '#{0:X2}{1:X2}{2:X2}' -f $pick.Color.R, $pick.Color.G, $pick.Color.B }
                    $pick.Dispose()
                })
                $rows[$n] = @{ Swatch = $swatch; Hex = $hex }
                $dlg.Controls.AddRange(@($lbl, $swatch, $hex))
            }
            $cbLight = New-Object System.Windows.Forms.CheckBox -Property @{
                Text = 'Light scheme: dark text on a light background (uses a light title bar)'
                Location = (New-Object System.Drawing.Point(16, 302)); AutoSize = $true
            }
            $hint = New-Object System.Windows.Forms.Label -Property @{
                Text = 'Click a colour box to choose a colour, or type a value like #1E90FF. Preview shows it on the app before you save.'
                Location = (New-Object System.Drawing.Point(16, 330)); AutoSize = $true; MaximumSize = (New-Object System.Drawing.Size(628, 0)); Tag = 'hint'
            }
            $btnPreview = New-Object System.Windows.Forms.Button -Property @{ Text = 'Preview'; Location = (New-Object System.Drawing.Point(16, 366)); Size = (New-Object System.Drawing.Size(100, 30)) }
            $btnSave = New-Object System.Windows.Forms.Button -Property @{ Text = 'Save'; Location = (New-Object System.Drawing.Point(452, 366)); Size = (New-Object System.Drawing.Size(90, 30)) }
            $btnCancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (New-Object System.Drawing.Point(552, 366)); Size = (New-Object System.Drawing.Size(90, 30)); DialogResult = 'Cancel' }
            $dlg.Controls.AddRange(@($cbLight, $hint, $btnPreview, $btnSave, $btnCancel))
            $dlg.CancelButton = $btnCancel

            $fill = {
                param($Colors, $Light)
                foreach ($n in $names) { if ($Colors[$n]) { $rows[$n].Hex.Text = ([string]$Colors[$n]).ToUpperInvariant() } }
                $cbLight.Checked = [bool]$Light
            }
            # The colours in the editor, or $null (after saying which one is wrong) if any is not valid
            $collect = {
                $colors = @{}
                foreach ($n in $names) {
                    $value = $rows[$n].Hex.Text.Trim()
                    if ($value -notmatch '^#[0-9A-Fa-f]{6}$') {
                        [void][System.Windows.Forms.MessageBox]::Show($dlg, "'$value' is not a valid colour for '$($script:ColorSchemes_Labels[$n])'. Use a value like #1E90FF.", 'Create Custom Color Scheme', 'OK', 'Warning')
                        return $null
                    }
                    $colors[$n] = $value.ToUpperInvariant()
                }
                $colors['Light'] = $cbLight.Checked
                $colors
            }
            $cmbFrom.add_SelectedIndexChanged({
                if ($cmbFrom.SelectedIndex -le 0) { & $fill $before $before.Light }
                else { $s = $schemes[$cmbFrom.SelectedIndex - 1]; & $fill $s.Colors $s.Light }
            })
            $btnPreview.add_Click({ $c = & $collect; if ($c) { & $app.SetColors $c } })
            $btnSave.add_Click({
                $name = $txtName.Text.Trim()
                if (-not ($name -replace '[\\/:*?"<>|]', '').Trim()) {
                    [void][System.Windows.Forms.MessageBox]::Show($dlg, 'Please give your scheme a name.', 'Create Custom Color Scheme', 'OK', 'Warning')
                    return
                }
                if ($script:ColorSchemes_BuiltIn.Contains($name)) {
                    [void][System.Windows.Forms.MessageBox]::Show($dlg, "'$name' is the name of a built-in scheme. Please choose another name.", 'Create Custom Color Scheme', 'OK', 'Warning')
                    return
                }
                $c = & $collect
                if (-not $c) { return }
                if (Test-Path -LiteralPath (ColorSchemes_FilePath $name)) {
                    $answer = [System.Windows.Forms.MessageBox]::Show($dlg, "A scheme called '$name' already exists. Replace it?", 'Create Custom Color Scheme', 'YesNo', 'Question')
                    if ($answer -ne 'Yes') { return }
                }
                ColorSchemes_Write $name ([bool]$c.Light) $c
                $script:ColorSchemes_LastSaved = $name
                $dlg.DialogResult = 'OK'
            })
            $cmbFrom.SelectedIndex = 0
            $dlg.add_Shown({ & $app.SetColors (& $app.GetColors) })

            $script:ColorSchemes_LastSaved = $null
            $result = $dlg.ShowDialog($app.Form)
            $saved = $script:ColorSchemes_LastSaved
            $dlg.Dispose()
            if ($result -eq 'OK' -and $saved) {
                & $app.Log "Color Schemes: saved '$saved' to $(ColorSchemes_FilePath $saved)."
                ColorSchemes_ApplyByName $saved
            } else {
                & $app.SetColors $before
            }
        }

        # First time: write the built-in schemes to the folder and ask which one to use.
        # After that: switch to the scheme chosen last time.
        New-Item -ItemType Directory -Force -Path $script:ColorSchemes_Dir | Out-Null
        foreach ($name in $script:ColorSchemes_BuiltIn.Keys) {
            if (-not (Test-Path -LiteralPath (ColorSchemes_FilePath $name))) {
                $s = $script:ColorSchemes_BuiltIn[$name]
                ColorSchemes_Write $name $s.Light $s.Colors
            }
        }
        $selected = ColorSchemes_GetSelected
        if ($selected) { ColorSchemes_ApplyByName $selected } else { ColorSchemes_ShowPicker -FirstRun }
    }

    # Addons > Color Scheme: a pop-out list of the schemes, with Create Custom... at the bottom
    BuildMenu = {
        param($App, $Menu)
        $current = ColorSchemes_GetSelected
        foreach ($s in (ColorSchemes_Load)) {
            $item = New-Object System.Windows.Forms.ToolStripMenuItem $(if ($s.BuiltIn) { $s.Name } else { "$($s.Name)  (custom)" })
            $item.Tag = $s.Name
            $item.Checked = $s.Name -eq $current
            $item.add_Click({ ColorSchemes_ApplyByName $this.Tag })
            [void]$Menu.DropDownItems.Add($item)
        }
        [void]$Menu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
        $custom = New-Object System.Windows.Forms.ToolStripMenuItem 'Create Custom...'
        $custom.add_Click({ ColorSchemes_ShowEditor })
        [void]$Menu.DropDownItems.Add($custom)
    }
}
