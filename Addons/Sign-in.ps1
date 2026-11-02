# Sign-In - an addon for Cybtek Downloader (needs Cybtek Downloader 1.5 or later).
#
# Adds "Sign In" to the Addons menu. Pick a site, log in (including 2FA) in the built-in browser
# window, and click "Use this login". The addon saves the browser's cookies to a cookies.txt file
# and points Cybtek Downloader at it, so yt-dlp can download videos that need you to be signed in.
#
# Nothing is sent anywhere by this addon - the login happens in a Microsoft WebView2 browser on your
# own PC, and the cookies are written only to this addon's folder. The first time you use it, the app
# offers to download the WebView2 browser component.
#
# Files are kept next to this addon ($PSScriptRoot, which is %APPDATA%\CybtekDownloader\addons once
# installed): the login profile in a "browser-profile" folder and the exported "cookies.txt".
#
# Install: Addons > Install Addon... in Cybtek Downloader, then choose this file.

@{
    Name        = 'Sign-In'
    Version     = '1.0'
    Author      = 'Cybtek Downloader'
    Description = 'Log in to a site in a built-in browser so downloads that need a sign-in work. Saves the login as a cookies.txt the app uses.'
    MenuText    = 'Sign In'

    OnLoad = {
        param($App, $Self)
        if (-not $App.EnsureWebView2) { throw 'This addon needs Cybtek Downloader 1.6 or later.' }
        try { if ([version]$App.AppVersion -lt [version]'1.6.0') { throw 'old' } } catch { throw 'This addon needs Cybtek Downloader 1.6 or later (for the Sign In menu).' }
        $script:SignIn_App = $App
        $script:SignIn_ProfileDir = Join-Path $Self.Folder 'browser-profile'
        $script:SignIn_CookieFile = Join-Path $Self.Folder 'cookies.txt'
        $script:SignIn_SettingsFile = Join-Path $Self.Folder 'sign-in.json'
        $script:SignIn_CoreLoaded = $false

        # The sites you can sign in to, with the page to open for each. "Other site..." asks for a URL.
        $script:SignIn_Sites = @(
            [pscustomobject]@{ Name = 'YouTube';     Url = 'https://www.youtube.com' }
            [pscustomobject]@{ Name = 'TikTok';      Url = 'https://www.tiktok.com/login' }
            [pscustomobject]@{ Name = 'Instagram';   Url = 'https://www.instagram.com/accounts/login/' }
            [pscustomobject]@{ Name = 'Twitter / X'; Url = 'https://x.com/login' }
            [pscustomobject]@{ Name = 'Twitch';      Url = 'https://www.twitch.tv/login' }
            [pscustomobject]@{ Name = 'Facebook';    Url = 'https://www.facebook.com/login' }
            [pscustomobject]@{ Name = 'Reddit';      Url = 'https://www.reddit.com/login' }
            [pscustomobject]@{ Name = 'Vimeo';       Url = 'https://vimeo.com/log_in' }
            [pscustomobject]@{ Name = 'Dailymotion'; Url = 'https://www.dailymotion.com/signin' }
            [pscustomobject]@{ Name = 'Bilibili';    Url = 'https://passport.bilibili.com/login' }
            [pscustomobject]@{ Name = 'SoundCloud';  Url = 'https://soundcloud.com/signin' }
            [pscustomobject]@{ Name = 'Bandcamp';    Url = 'https://bandcamp.com/login' }
        )

        # Pumps the UI message loop until a .NET Task finishes, then returns its result
        function script:SignIn_Await($Task, [int]$Seconds = 60) {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            while (-not $Task.IsCompleted -and $sw.Elapsed.TotalSeconds -lt $Seconds) {
                [System.Windows.Forms.Application]::DoEvents()
                Start-Sleep -Milliseconds 20
            }
            if (-not $Task.IsCompleted) { throw 'The browser took too long to respond.' }
            $Task.GetAwaiter().GetResult()
        }

        function script:SignIn_LoadCore([string]$BinDir) {
            if ($script:SignIn_CoreLoaded) { return }
            [Reflection.Assembly]::LoadFrom((Join-Path $BinDir 'Microsoft.Web.WebView2.Core.dll')) | Out-Null
            $script:SignIn_CoreLoaded = $true
        }

        # Reads every cookie from the login browser and writes a Netscape cookies.txt that yt-dlp reads
        function script:SignIn_ExportCookies($CoreWebView2) {
            $cookies = SignIn_Await ($CoreWebView2.CookieManager.GetCookiesAsync($null))
            $lines = New-Object System.Collections.Generic.List[string]
            $lines.Add('# Netscape HTTP Cookie File')
            $lines.Add('# Saved by the Cybtek Downloader Sign-In addon')
            foreach ($c in $cookies) {
                if (-not $c.Name) { continue }
                $incl = if ($c.Domain.StartsWith('.')) { 'TRUE' } else { 'FALSE' }
                $secure = if ($c.IsSecure) { 'TRUE' } else { 'FALSE' }
                $expiry = 0
                if (-not $c.IsSession) { try { $expiry = [long]([DateTimeOffset]$c.Expires).ToUnixTimeSeconds() } catch { $expiry = 0 } }
                if ($expiry -lt 0) { $expiry = 0 }
                $prefix = if ($c.IsHttpOnly) { '#HttpOnly_' } else { '' }
                $lines.Add(($prefix + $c.Domain + "`t" + $incl + "`t" + $c.Path + "`t" + $secure + "`t" + $expiry + "`t" + $c.Name + "`t" + $c.Value))
            }
            [IO.File]::WriteAllText($script:SignIn_CookieFile, ($lines -join "`n") + "`n", (New-Object System.Text.UTF8Encoding($false)))
            $cookies.Count
        }

        # Switches Cybtek Downloader to use the saved cookies.txt, and remembers it across restarts
        function script:SignIn_UseCookies {
            $script:SignIn_App.Settings.CookieSource = 'file'
            $script:SignIn_App.Settings.CookieFile = $script:SignIn_CookieFile
            & $script:SignIn_App.SaveSettings
        }

        # Opens the login window for a site and wires up the WebView2 browser
        function script:SignIn_ShowLogin([string]$SiteName, [string]$Url) {
            $app = $script:SignIn_App
            $bin = & $app.EnsureWebView2
            if (-not $bin) { return }
            try { SignIn_LoadCore $bin }
            catch {
                [void][System.Windows.Forms.MessageBox]::Show($app.Form, "The built-in browser could not be loaded:`n$($_.Exception.Message)", 'Sign In', 'OK', 'Error')
                return
            }
            $colors = & $app.GetColors
            $panelColor = [System.Drawing.ColorTranslator]::FromHtml($colors.Panel)
            $textColor = [System.Drawing.ColorTranslator]::FromHtml($colors.Text)
            $accentColor = [System.Drawing.ColorTranslator]::FromHtml($colors.AccentLight)

            $f = New-Object System.Windows.Forms.Form -Property @{
                Text = "Sign in to $SiteName"; StartPosition = 'CenterParent'; Width = 1000; Height = 760
                MinimumSize = (New-Object System.Drawing.Size(640, 520)); ShowInTaskbar = $false
                Font = (New-Object System.Drawing.Font('Segoe UI', 9)); BackColor = $panelColor
            }
            if ($app.Form.Icon) { $f.Icon = $app.Form.Icon }

            $bar = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Top'; Height = 52; BackColor = $panelColor }
            $lblInfo = New-Object System.Windows.Forms.Label -Property @{
                Text = "Log in to $SiteName, then click 'Use this login'."; Location = (New-Object System.Drawing.Point(12, 8)); AutoSize = $true
                ForeColor = $accentColor; Font = (New-Object System.Drawing.Font('Segoe UI Semibold', 10))
            }
            $lblAddr = New-Object System.Windows.Forms.Label -Property @{
                Text = $Url; Location = (New-Object System.Drawing.Point(13, 30)); AutoSize = $true; ForeColor = [System.Drawing.ColorTranslator]::FromHtml($colors.Muted)
                MaximumSize = (New-Object System.Drawing.Size(640, 18))
            }
            $btnUse = New-Object System.Windows.Forms.Button -Property @{ Text = 'Use this login'; Width = 130; Height = 32; Anchor = 'Top, Right'; ForeColor = $textColor }
            $btnCancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Width = 90; Height = 32; Anchor = 'Top, Right'; ForeColor = $textColor }
            foreach ($b in @($btnUse, $btnCancel)) {
                $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false
                $b.BackColor = [System.Drawing.ColorTranslator]::FromHtml($colors.Hover)
                $b.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml($colors.Border)
            }
            $positionButtons = { $btnUse.Location = (New-Object System.Drawing.Point(($bar.ClientSize.Width - 230), 10)); $btnCancel.Location = (New-Object System.Drawing.Point(($bar.ClientSize.Width - 96), 10)) }
            & $positionButtons
            $bar.add_Resize($positionButtons)
            $bar.Controls.AddRange(@($lblInfo, $lblAddr, $btnUse, $btnCancel))

            $browserHost = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Fill'; BackColor = [System.Drawing.Color]::White }
            $f.Controls.Add($browserHost)
            $f.Controls.Add($bar)

            $script:SignIn_Controller = $null
            $script:SignIn_Saved = $false

            $f.add_Shown({
                try {
                    $envTask = [Microsoft.Web.WebView2.Core.CoreWebView2Environment]::CreateAsync($null, $script:SignIn_ProfileDir, $null)
                    $wvEnv = SignIn_Await $envTask 30
                    $script:SignIn_Controller = SignIn_Await ($wvEnv.CreateCoreWebView2ControllerAsync($browserHost.Handle)) 30
                    $script:SignIn_Controller.Bounds = New-Object System.Drawing.Rectangle(0, 0, $browserHost.ClientSize.Width, $browserHost.ClientSize.Height)
                    $script:SignIn_Controller.IsVisible = $true
                    $cw = $script:SignIn_Controller.CoreWebView2
                    $cw.add_SourceChanged({ param($s, $e) try { $lblAddr.Text = $script:SignIn_Controller.CoreWebView2.Source } catch { } })
                    $cw.Navigate($Url)
                } catch {
                    [void][System.Windows.Forms.MessageBox]::Show($f, "The built-in browser could not start:`n$($_.Exception.Message)", 'Sign In', 'OK', 'Error')
                    $f.Close()
                }
            })
            $browserHost.add_Resize({
                if ($script:SignIn_Controller) {
                    $script:SignIn_Controller.Bounds = New-Object System.Drawing.Rectangle(0, 0, $browserHost.ClientSize.Width, $browserHost.ClientSize.Height)
                }
            })
            $btnUse.add_Click({
                try {
                    $count = SignIn_ExportCookies $script:SignIn_Controller.CoreWebView2
                    SignIn_UseCookies
                    $script:SignIn_Saved = $true
                    & $script:SignIn_App.Log "Sign-In: saved $count cookies for $SiteName and set the app to use them."
                    $f.Close()
                } catch {
                    [void][System.Windows.Forms.MessageBox]::Show($f, "The login could not be saved:`n$($_.Exception.Message)", 'Sign In', 'OK', 'Error')
                }
            })
            $btnCancel.add_Click({ $f.Close() })
            $f.add_FormClosed({
                if ($script:SignIn_Controller) {
                    try { $script:SignIn_Controller.Close() } catch { }
                    $script:SignIn_Controller = $null
                }
            })
            [void]$f.ShowDialog($app.Form)

            if ($script:SignIn_Saved) {
                [void][System.Windows.Forms.MessageBox]::Show($app.Form,
                    "You are signed in to $SiteName.`n`nCybtek Downloader will now use this login (Settings > Sources shows 'cookies.txt file'). Try your download again.",
                    'Sign In', 'OK', 'Information')
            }
        }

        function script:SignIn_ShowOther {
            $url = [Microsoft.VisualBasic.Interaction]::InputBox('Enter the address of the site to sign in to:', 'Sign In', 'https://')
            $url = "$url".Trim()
            if ($url -and $url -match '^https?://') { SignIn_ShowLogin 'this site' $url }
            elseif ($url) { [void][System.Windows.Forms.MessageBox]::Show($script:SignIn_App.Form, 'Please enter a full address starting with http:// or https://.', 'Sign In', 'OK', 'Warning') }
        }

        # Deletes the saved login (the cookies file and the browser profile) and stops using it
        function script:SignIn_ClearLogin {
            $app = $script:SignIn_App
            if ((([System.Windows.Forms.MessageBox]::Show($app.Form, "Remove the saved login? This signs you out of every site in the built-in browser and deletes the saved cookies.", 'Sign In', 'YesNo', 'Question'))) -ne 'Yes') { return }
            try {
                if ($app.Settings.CookieFile -eq $script:SignIn_CookieFile) {
                    $app.Settings.CookieSource = ''
                    $app.Settings.CookieFile = ''
                    & $app.SaveSettings
                }
                Remove-Item -LiteralPath $script:SignIn_CookieFile -Force -ErrorAction SilentlyContinue
                if (Test-Path -LiteralPath $script:SignIn_ProfileDir) { Remove-Item -LiteralPath $script:SignIn_ProfileDir -Recurse -Force -ErrorAction SilentlyContinue }
                & $app.Log 'Sign-In: saved login cleared.'
                [void][System.Windows.Forms.MessageBox]::Show($app.Form, 'The saved login was removed.', 'Sign In', 'OK', 'Information')
            } catch {
                [void][System.Windows.Forms.MessageBox]::Show($app.Form, "Could not fully remove the saved login:`n$($_.Exception.Message)", 'Sign In', 'OK', 'Warning')
            }
        }

        # Whether to show the start-up reminder (kept in the addon's own settings file, next to the addon)
        function script:SignIn_GetShowReminder {
            try {
                if (Test-Path -LiteralPath $script:SignIn_SettingsFile) {
                    $j = [IO.File]::ReadAllText($script:SignIn_SettingsFile) | ConvertFrom-Json
                    if ($null -ne $j.ShowStartupReminder) { return [bool]$j.ShowStartupReminder }
                }
            } catch { }
            $true   # default: show it
        }
        function script:SignIn_SetShowReminder([bool]$Show) {
            try {
                $doc = [ordered]@{ ShowStartupReminder = $Show }
                [IO.File]::WriteAllText($script:SignIn_SettingsFile, ($doc | ConvertTo-Json), (New-Object System.Text.UTF8Encoding($false)))
            } catch { & $script:SignIn_App.Log "Sign-In: could not save settings ($($_.Exception.Message))." }
        }

        # Gives a small window the app's colours
        function script:SignIn_ThemeWindow($Window) {
            $c = & $script:SignIn_App.GetColors
            $Window.BackColor = [System.Drawing.ColorTranslator]::FromHtml($c.Back)
            $Window.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($c.Text)
            foreach ($ctl in $Window.Controls) {
                if ($ctl -is [System.Windows.Forms.Button]) {
                    $ctl.FlatStyle = 'Flat'; $ctl.UseVisualStyleBackColor = $false
                    $ctl.BackColor = [System.Drawing.ColorTranslator]::FromHtml($c.Hover)
                    $ctl.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($c.Text)
                    $ctl.FlatAppearance.BorderColor = [System.Drawing.ColorTranslator]::FromHtml($c.Border)
                } else {
                    $ctl.ForeColor = [System.Drawing.ColorTranslator]::FromHtml($c.Text)
                }
            }
            if ('CyNative' -as [type]) { $Window.add_HandleCreated({ [CyNative]::UseDarkTitleBar($this.Handle) }) }
        }

        # The reminder shown after start-up: sign in via the Sign In menu, with a "show at startup" checkbox
        function script:SignIn_ShowStartupReminder {
            $app = $script:SignIn_App
            $f = New-Object System.Windows.Forms.Form -Property @{
                Text = 'Sign in to download'; ClientSize = (New-Object System.Drawing.Size(470, 218)); StartPosition = 'CenterParent'
                FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; ShowInTaskbar = $false
                Font = (New-Object System.Drawing.Font('Segoe UI', 9))
            }
            if ($app.Form.Icon) { $f.Icon = $app.Form.Icon }
            $lblTitle = New-Object System.Windows.Forms.Label -Property @{
                Text = 'Some downloads need you to be signed in'; Location = (New-Object System.Drawing.Point(16, 16)); AutoSize = $true
                Font = (New-Object System.Drawing.Font('Segoe UI Semibold', 11))
            }
            $lblMsg = New-Object System.Windows.Forms.Label -Property @{
                Location = (New-Object System.Drawing.Point(16, 48)); Size = (New-Object System.Drawing.Size(438, 90))
                Text = "YouTube and some other sites only let you download when you are logged in. To sign in, click the Sign In menu at the top of the window, pick the site, and log in. Cybtek Downloader then uses that login for your downloads."
            }
            $cb = New-Object System.Windows.Forms.CheckBox -Property @{
                Text = 'Show this reminder each time Cybtek Downloader starts'; Location = (New-Object System.Drawing.Point(16, 148)); AutoSize = $true; Checked = (SignIn_GetShowReminder)
            }
            $btnOk = New-Object System.Windows.Forms.Button -Property @{ Text = 'Got it'; Location = (New-Object System.Drawing.Point(370, 176)); Width = 84; Height = 30; DialogResult = 'OK' }
            $f.Controls.AddRange(@($lblTitle, $lblMsg, $cb, $btnOk))
            $f.AcceptButton = $btnOk
            SignIn_ThemeWindow $f
            $lblTitle.ForeColor = [System.Drawing.ColorTranslator]::FromHtml((& $app.GetColors).AccentLight)
            [void]$f.ShowDialog($app.Form)
            SignIn_SetShowReminder ([bool]$cb.Checked)
        }

        # Addons > Sign In: options, including turning the start-up reminder back on
        function script:SignIn_ShowOptions {
            $app = $script:SignIn_App
            $f = New-Object System.Windows.Forms.Form -Property @{
                Text = 'Sign-In Options'; ClientSize = (New-Object System.Drawing.Size(430, 150)); StartPosition = 'CenterParent'
                FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; ShowInTaskbar = $false
                Font = (New-Object System.Drawing.Font('Segoe UI', 9))
            }
            if ($app.Form.Icon) { $f.Icon = $app.Form.Icon }
            $cb = New-Object System.Windows.Forms.CheckBox -Property @{
                Text = 'Show the sign-in reminder each time Cybtek Downloader starts'; Location = (New-Object System.Drawing.Point(16, 22)); AutoSize = $true; Checked = (SignIn_GetShowReminder)
            }
            $lbl = New-Object System.Windows.Forms.Label -Property @{
                Text = 'To sign in to a site, use the Sign In menu at the top of the window.'; Location = (New-Object System.Drawing.Point(16, 52)); AutoSize = $true
            }
            $btnOk = New-Object System.Windows.Forms.Button -Property @{ Text = 'OK'; Location = (New-Object System.Drawing.Point(240, 104)); Width = 84; Height = 30; DialogResult = 'OK' }
            $btnCancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (New-Object System.Drawing.Point(330, 104)); Width = 84; Height = 30; DialogResult = 'Cancel' }
            $f.Controls.AddRange(@($cb, $lbl, $btnOk, $btnCancel))
            $f.AcceptButton = $btnOk; $f.CancelButton = $btnCancel
            SignIn_ThemeWindow $f
            $lbl.ForeColor = [System.Drawing.ColorTranslator]::FromHtml((& $app.GetColors).Muted)
            if ($f.ShowDialog($app.Form) -eq 'OK') { SignIn_SetShowReminder ([bool]$cb.Checked) }
        }

        # Fills the Sign In menu with the list of sites (used by both the top-level menu and anywhere else)
        function script:SignIn_BuildSiteMenu($Menu) {
            $signedIn = $script:SignIn_App.Settings.CookieFile -eq $script:SignIn_CookieFile -and (Test-Path -LiteralPath $script:SignIn_CookieFile)
            foreach ($site in $script:SignIn_Sites) {
                $item = New-Object System.Windows.Forms.ToolStripMenuItem $site.Name
                $item.Tag = $site
                $item.add_Click({ SignIn_ShowLogin $this.Tag.Name $this.Tag.Url })
                [void]$Menu.DropDownItems.Add($item)
            }
            [void]$Menu.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
            $other = New-Object System.Windows.Forms.ToolStripMenuItem 'Other site...'
            $other.add_Click({ SignIn_ShowOther })
            [void]$Menu.DropDownItems.Add($other)
            $clear = New-Object System.Windows.Forms.ToolStripMenuItem 'Clear saved login'
            $clear.Enabled = [bool]$signedIn
            $clear.add_Click({ SignIn_ClearLogin })
            [void]$Menu.DropDownItems.Add($clear)
        }

        # After start-up, remind the user to sign in (unless they turned the reminder off)
        if (SignIn_GetShowReminder) {
            $script:SignIn_ReminderTimer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 1200 }
            $script:SignIn_ReminderTimer.add_Tick({
                $this.Stop()
                try { SignIn_ShowStartupReminder } catch { & $script:SignIn_App.Log "Sign-In: reminder failed ($($_.Exception.Message))." }
            })
            $script:SignIn_ReminderTimer.Start()
        }
    }

    # Addons > Sign In: opens the options window (where the start-up reminder can be turned back on)
    MenuAction = { param($App) SignIn_ShowOptions }

    # A top-level "Sign In" menu on the menu bar (after Addons): the list of sites to log in to
    TopMenuText  = 'Sign In'
    TopMenuBuild = { param($App, $Menu) SignIn_BuildSiteMenu $Menu }
}