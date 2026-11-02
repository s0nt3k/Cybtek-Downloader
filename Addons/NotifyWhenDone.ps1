# Example addon for Cybtek Downloader.
# Shows a Windows notification when a download finishes, so you can leave the app in the background.
# Install it from the app with Addons > Install Addon...

@{
    Name        = 'Notify When Done'
    Version     = '1.0'
    Author      = 'Cybtek Downloader'
    Description = 'Shows a Windows notification when a download finishes. Click it on the Addons menu to see a test notification.'

    OnDownloadComplete = {
        param($Info)
        $title = if ($Info.Success) { "$($Info.Mode) download finished" } else { "$($Info.Mode) download failed" }
        $icon = if ($Info.Success) { 'Info' } else { 'Error' }
        $tray = New-Object System.Windows.Forms.NotifyIcon
        $tray.Icon = [System.Drawing.SystemIcons]::Information
        $tray.Visible = $true
        $tray.ShowBalloonTip(5000, $title, "$($Info.Source): $($Info.Url)", $icon)

        # Remove the tray icon once the notification has had time to show
        $timer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 10000 }
        $timer.Tag = $tray
        $timer.add_Tick({ $this.Stop(); $this.Tag.Dispose(); $this.Dispose() })
        $timer.Start()
    }

    MenuAction = {
        param($App)
        & $App.Log 'Notify When Done: showing a test notification.'
        $tray = New-Object System.Windows.Forms.NotifyIcon
        $tray.Icon = [System.Drawing.SystemIcons]::Information
        $tray.Visible = $true
        $tray.ShowBalloonTip(5000, 'Notify When Done', 'This is how you will be told a download has finished.', 'Info')
        $timer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 10000 }
        $timer.Tag = $tray
        $timer.add_Tick({ $this.Stop(); $this.Tag.Dispose(); $this.Dispose() })
        $timer.Start()
    }
}
