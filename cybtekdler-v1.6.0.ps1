#Requires -Version 5.1
<#
.SYNOPSIS
    Cybtek Downloader - an audio and video downloader for Windows, built on yt-dlp.

.DESCRIPTION
    Paste (or just copy) a link from YouTube, TikTok, Instagram, Twitter / X, Twitch and other
    sites and download it as a video or an audio file. yt-dlp (https://github.com/yt-dlp/yt-dlp)
    does the downloading and ffmpeg does the converting. On start-up the app checks that both
    are installed and up to date. Addons (PowerShell scripts) can extend the app.

.NOTES
    Splash   : Cybtek-Downloader.png, downloaded from the project's GitHub on first run and kept next to this script (also the window icon)
    Settings : %APPDATA%\CybtekDownloader\settings.json
    Tools    : %APPDATA%\CybtekDownloader\bin      (yt-dlp.exe, ffmpeg.exe, ffprobe.exe, deno.exe installed by this app)
    Addons   : the Addons folder next to this script (or %APPDATA%\CybtekDownloader\addons if that can't be written)
    Archives : %APPDATA%\CybtekDownloader\archive  (zip backups made by Help > Archive Dependencies)
    Run with : powershell -NoProfile -ExecutionPolicy Bypass -File .\CybtekDler-v1.6.0.ps1  (or double-click Cybtek Downloader.cmd)
    Naming   : the file is CybtekDler-vMAJOR.MINOR.PATCH.ps1; keep it in step with $script:AppVersion. The launcher runs the newest.
#>

# WinForms and the clipboard need a single-threaded apartment. Relaunch in STA if needed.
if ([Threading.Thread]::CurrentThread.ApartmentState -ne 'STA') {
    $hostExe = (Get-Process -Id $PID).Path
    Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
    return
}

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
Add-Type -AssemblyName Microsoft.VisualBasic
[System.Windows.Forms.Application]::EnableVisualStyles()
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

# Runs yt-dlp and collects its output on background threads, so the UI never blocks.
# The UI drains the queue from a timer on the UI thread.
if (-not ('YtProcessRunner' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Concurrent;
using System.Diagnostics;
using System.Text;

public class YtProcessRunner
{
    public ConcurrentQueue<string> Lines = new ConcurrentQueue<string>();
    public Process Proc;

    public void Start(string fileName, string arguments)
    {
        ProcessStartInfo psi = new ProcessStartInfo(fileName, arguments);
        psi.UseShellExecute = false;
        psi.RedirectStandardOutput = true;
        psi.RedirectStandardError = true;
        psi.CreateNoWindow = true;
        psi.StandardOutputEncoding = Encoding.UTF8;
        psi.StandardErrorEncoding = Encoding.UTF8;
        Proc = new Process();
        Proc.StartInfo = psi;
        Proc.OutputDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
        Proc.ErrorDataReceived += (s, e) => { if (e.Data != null) Lines.Enqueue(e.Data); };
        Proc.Start();
        Proc.BeginOutputReadLine();
        Proc.BeginErrorReadLine();
    }

    public bool IsRunning { get { return Proc != null && !Proc.HasExited; } }

    // True once the process has exited and all of its output has been read.
    public bool Finished
    {
        get
        {
            if (Proc == null) return true;
            if (!Proc.HasExited) return false;
            Proc.WaitForExit();
            return true;
        }
    }

    public int ExitCode { get { return Proc == null ? -1 : Proc.ExitCode; } }
}
'@
}

# The Cybtek colour scheme: a dark menu renderer and a progress bar that matches it.
# A .NET type is compiled once per PowerShell session and never replaced, so if an older version of the
# app was run earlier in the same console its CyColors is kept, missing newer members like ButtonHover.
# When that is detected, start again in a fresh process so the current definitions are used.
if ('CyColors' -as [type]) {
    if (-not [CyColors].GetField('ButtonHover')) {
        $hostExe = (Get-Process -Id $PID).Path
        Start-Process -FilePath $hostExe -ArgumentList @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-STA', '-File', "`"$PSCommandPath`"")
        return
    }
} else {
    $themeRefs = if ($PSVersionTable.PSEdition -eq 'Core') {
        @('System.Windows.Forms', 'System.Drawing', 'System.Drawing.Common', 'System.Drawing.Primitives', 'System.Windows.Forms.Primitives', 'System.ComponentModel.Primitives')
    } else {
        @('System.Windows.Forms', 'System.Drawing')
    }
    Add-Type -ReferencedAssemblies $themeRefs -TypeDefinition @'
using System;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Windows.Forms;

// The Cybtek Blue scheme. Set-AppColors changes these while the app runs (color scheme addons use it).
public static class CyColors
{
    public static Color Back        = Color.FromArgb(7, 13, 26);
    public static Color Panel       = Color.FromArgb(11, 22, 42);
    public static Color Input       = Color.FromArgb(14, 30, 56);
    public static Color Hover       = Color.FromArgb(20, 52, 90);
    public static Color ButtonHover = Color.FromArgb(28, 72, 122);
    public static Color Border      = Color.FromArgb(32, 74, 120);
    public static Color Accent      = Color.FromArgb(0, 168, 255);
    public static Color AccentLight = Color.FromArgb(90, 222, 255);
    public static Color Text        = Color.FromArgb(232, 241, 255);
    public static Color Muted       = Color.FromArgb(140, 165, 200);
    public static Color Disabled    = Color.FromArgb(85, 105, 135);
    public static Color Good        = Color.FromArgb(70, 220, 160);
    public static Color Warn        = Color.FromArgb(255, 184, 77);
    public static Color Bad         = Color.FromArgb(255, 99, 115);
    // true for schemes with dark text on a light background (they get a light title bar)
    public static bool Light        = false;
}

public static class CyNative
{
    [System.Runtime.InteropServices.DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    // Title bar to match the scheme (dark unless CyColors.Light) on Windows 10 20H1 and later;
    // does nothing on older versions.
    public static void UseDarkTitleBar(IntPtr hwnd)
    {
        int on = CyColors.Light ? 0 : 1;
        try { DwmSetWindowAttribute(hwnd, 20, ref on, 4); } catch { }
    }
}

public class CyColorTable : ProfessionalColorTable
{
    public override Color MenuStripGradientBegin { get { return CyColors.Panel; } }
    public override Color MenuStripGradientEnd { get { return CyColors.Panel; } }
    public override Color MenuItemSelected { get { return CyColors.Hover; } }
    public override Color MenuItemSelectedGradientBegin { get { return CyColors.Hover; } }
    public override Color MenuItemSelectedGradientEnd { get { return CyColors.Hover; } }
    public override Color MenuItemPressedGradientBegin { get { return CyColors.Input; } }
    public override Color MenuItemPressedGradientMiddle { get { return CyColors.Input; } }
    public override Color MenuItemPressedGradientEnd { get { return CyColors.Input; } }
    public override Color MenuItemBorder { get { return CyColors.Border; } }
    public override Color MenuBorder { get { return CyColors.Border; } }
    public override Color ToolStripDropDownBackground { get { return CyColors.Input; } }
    public override Color ImageMarginGradientBegin { get { return CyColors.Input; } }
    public override Color ImageMarginGradientMiddle { get { return CyColors.Input; } }
    public override Color ImageMarginGradientEnd { get { return CyColors.Input; } }
    public override Color SeparatorDark { get { return CyColors.Border; } }
    public override Color SeparatorLight { get { return CyColors.Border; } }
    public override Color CheckBackground { get { return CyColors.Hover; } }
    public override Color CheckSelectedBackground { get { return CyColors.Hover; } }
    public override Color CheckPressedBackground { get { return CyColors.Hover; } }
}

public class CyMenuRenderer : ToolStripProfessionalRenderer
{
    public CyMenuRenderer() : base(new CyColorTable()) { RoundedEdges = false; }

    protected override void OnRenderItemText(ToolStripItemTextRenderEventArgs e)
    {
        e.TextColor = e.Item.Enabled ? CyColors.Text : CyColors.Disabled;
        base.OnRenderItemText(e);
    }

    protected override void OnRenderArrow(ToolStripArrowRenderEventArgs e)
    {
        e.ArrowColor = CyColors.Text;
        base.OnRenderArrow(e);
    }

    // A cyan tick instead of the default black one
    protected override void OnRenderItemCheck(ToolStripItemImageRenderEventArgs e)
    {
        Rectangle r = e.ImageRectangle;
        using (SolidBrush b = new SolidBrush(CyColors.Hover)) { e.Graphics.FillRectangle(b, r); }
        e.Graphics.SmoothingMode = SmoothingMode.AntiAlias;
        using (Pen p = new Pen(CyColors.AccentLight, 2f))
        {
            e.Graphics.DrawLines(p, new Point[] {
                new Point(r.Left + 3, r.Top + r.Height / 2),
                new Point(r.Left + r.Width / 2 - 1, r.Bottom - 4),
                new Point(r.Right - 3, r.Top + 3) });
        }
    }
}

// Same Value / Style / MarqueeAnimationSpeed members as ProgressBar, drawn in the app's colours.
public class CyProgressBar : Control
{
    private int _value;
    private ProgressBarStyle _style = ProgressBarStyle.Continuous;
    private float _offset = -0.3f;
    private Timer _timer = new Timer();

    public CyProgressBar()
    {
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.OptimizedDoubleBuffer |
                 ControlStyles.UserPaint | ControlStyles.ResizeRedraw, true);
        _timer.Interval = 25;
        _timer.Tick += (s, e) => { _offset += 0.025f; if (_offset > 1.0f) _offset = -0.3f; Invalidate(); };
        Height = 14;
    }

    public int MarqueeAnimationSpeed { get; set; }

    public int Value
    {
        get { return _value; }
        set { int v = Math.Max(0, Math.Min(100, value)); if (v != _value) { _value = v; Invalidate(); } }
    }

    public ProgressBarStyle Style
    {
        get { return _style; }
        set { _style = value; _timer.Enabled = value == ProgressBarStyle.Marquee && Visible; Invalidate(); }
    }

    protected override void OnVisibleChanged(EventArgs e)
    {
        base.OnVisibleChanged(e);
        _timer.Enabled = _style == ProgressBarStyle.Marquee && Visible;
    }

    protected override void OnPaint(PaintEventArgs e)
    {
        if (Width < 3 || Height < 3) return;
        Graphics g = e.Graphics;
        Rectangle all = new Rectangle(0, 0, Width, Height);
        using (SolidBrush back = new SolidBrush(CyColors.Input)) { g.FillRectangle(back, all); }

        Rectangle fill;
        if (_style == ProgressBarStyle.Marquee)
        {
            int w = Width * 3 / 10;
            fill = Rectangle.Intersect(all, new Rectangle((int)(_offset * Width), 0, w, Height));
        }
        else
        {
            fill = new Rectangle(0, 0, (int)(Width * _value / 100.0), Height);
        }
        if (fill.Width > 0)
        {
            using (LinearGradientBrush b = new LinearGradientBrush(all, CyColors.Accent, CyColors.AccentLight, LinearGradientMode.Horizontal))
            {
                g.FillRectangle(b, fill);
            }
            using (SolidBrush shine = new SolidBrush(Color.FromArgb(60, 255, 255, 255)))
            {
                g.FillRectangle(shine, new Rectangle(fill.X, 0, fill.Width, Height / 3));
            }
        }
        using (Pen border = new Pen(CyColors.Border)) { g.DrawRectangle(border, 0, 0, Width - 1, Height - 1); }
    }

    protected override void Dispose(bool disposing)
    {
        if (disposing) _timer.Dispose();
        base.Dispose(disposing);
    }
}
'@
}

# ---------------------------------------------------------------------------
# App state and settings
# ---------------------------------------------------------------------------

$script:AppName      = 'Cybtek Downloader'
$script:AppVersion   = '1.6.0'
$script:AppDataDir   = Join-Path $env:APPDATA 'CybtekDownloader'
# The splash image is downloaded from the project's GitHub the first time the app runs and kept next to
# the script, so later runs use the local file. (The link is the raw form of the repo's Cybtek-Downloader.png.)
$script:SplashUrl      = 'https://raw.githubusercontent.com/s0nt3k/Cybtek-Downloader/main/Cybtek-Downloader.png'
$script:SplashFileName = 'Cybtek-Downloader.png'
$script:SplashFile     = if ($PSScriptRoot) { Join-Path $PSScriptRoot $script:SplashFileName } else { $null }
$script:SplashFallback = Join-Path $script:AppDataDir $script:SplashFileName

# Earlier versions were called "YouTube Downloader" and kept their data in %APPDATA%\YtDlpGui.
# Move it across once, so settings, tools, addons and logs carry over.
$script:OldAppDataDir = Join-Path $env:APPDATA 'YtDlpGui'
if (-not (Test-Path -LiteralPath (Join-Path $script:AppDataDir 'settings.json')) -and
    (Test-Path -LiteralPath (Join-Path $script:OldAppDataDir 'settings.json'))) {
    if (-not (Test-Path -LiteralPath $script:AppDataDir)) {
        try { Move-Item -LiteralPath $script:OldAppDataDir -Destination $script:AppDataDir -ErrorAction Stop } catch { }
    }
    # If the move did not happen (folder in use, or the new folder already exists), keep using the old one
    if (-not (Test-Path -LiteralPath (Join-Path $script:AppDataDir 'settings.json'))) { $script:AppDataDir = $script:OldAppDataDir }
}

$script:SettingsFile = Join-Path $script:AppDataDir 'settings.json'
$script:BinDir       = Join-Path $script:AppDataDir 'bin'
# The Addons folder next to the script is the addon directory: it is created when the app starts, every
# addon in it is loaded automatically, and Install Addon... copies into it. If that folder cannot be
# written (for example a read-only location), the app data folder is used instead.
$script:AddonDir     = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Addons' } else { Join-Path $script:AppDataDir 'addons' }
$script:HelpFile     = Join-Path $script:AppDataDir 'help.html'

$script:YtDlpRepoUrl     = 'https://github.com/yt-dlp/yt-dlp'
$script:SupportedSitesUrl = 'https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md'
$script:YtDlpDownloadUrl = 'https://github.com/yt-dlp/yt-dlp/releases/latest/download/yt-dlp.exe'
$script:YtDlpApiUrl      = 'https://api.github.com/repos/yt-dlp/yt-dlp/releases/latest'
$script:FfmpegApiUrl     = 'https://api.github.com/repos/yt-dlp/FFmpeg-Builds/releases/latest'
$script:FfmpegAssetName  = 'ffmpeg-master-latest-win64-gpl.zip'
$script:FfmpegZipUrl     = "https://github.com/yt-dlp/FFmpeg-Builds/releases/download/latest/$($script:FfmpegAssetName)"
$script:FfmpegZipSizeMB  = 0

# Deno is the JavaScript runtime yt-dlp needs for YouTube
$script:DenoArch         = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
$script:DenoZipUrl       = "https://github.com/denoland/deno/releases/latest/download/deno-$($script:DenoArch)-pc-windows-msvc.zip"
$script:DenoApiUrl       = 'https://api.github.com/repos/denoland/deno/releases/latest'

# WebView2 is an embedded browser (Microsoft). It is used only by the Sign-In addon to log in to
# sites, so it is optional: installed on demand when an addon asks for it, not a core download tool.
$script:WebView2Dir        = Join-Path $script:BinDir 'webview2'
$script:WebView2CoreDll    = Join-Path $script:WebView2Dir 'Microsoft.Web.WebView2.Core.dll'
$script:WebView2LoaderDll  = Join-Path $script:WebView2Dir 'WebView2Loader.dll'
$script:WebView2IndexUrl   = 'https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/index.json'
$script:WebView2RuntimeUrl = 'https://go.microsoft.com/fwlink/p/?LinkId=2124703'   # evergreen runtime bootstrapper
$script:WebView2Arch       = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } elseif ($env:PROCESSOR_ARCHITECTURE -eq 'x86') { 'x86' } else { 'x64' }
$script:WebView2RuntimeId  = '{F3017226-FE2A-4295-8BDF-00C3A9A7E4C5}'

# ffmpeg is published as daily builds, so it counts as outdated once the newest
# build is more than this many days newer than the installed one.
$script:FfmpegMaxAgeDays = 30

$script:ActivityLines = New-Object System.Collections.Generic.List[string]
$script:ActivityForm   = $null
$script:ActivityBox    = $null
$script:ActivityStatus = $null
$script:Runner         = $null
$script:IsBusy         = $false
$script:Cancelled      = $false
$script:CurrentMode    = ''
$script:CurrentInfo    = $null
$script:LastError      = ''
$script:LastClipboard  = ''
$script:ChapterFiles   = 0
$script:PrintFile      = $null
$script:Addons         = New-Object System.Collections.Generic.List[object]

# Dependency state, filled in by Update-VersionInfo
$script:YtDlpExe         = $null
$script:YtDlpVersion     = $null
$script:YtDlpLatest      = $null
$script:YtDlpUpdate      = $false
$script:FfmpegExe        = $null
$script:FfmpegVersion    = $null
$script:FfmpegBuildDate  = $null
$script:FfmpegLatestDate = $null
$script:FfmpegUpdate     = $false
$script:DenoExe          = $null
$script:DenoVersion      = $null
$script:DenoLatest       = $null
$script:DenoUpdate       = $false
$script:UpdateCheckRan   = $false
$script:DependencyNames  = @('yt-dlp', 'ffmpeg', 'Deno')

# Sites on the Source menu. Hosts is a regex of the site's domains (used to auto-paste
# copied links); AudioOnly sites have no video to download.
$script:Sources = @(
    [pscustomobject]@{ Name = 'YouTube';     Hosts = 'youtube\.com|youtu\.be|youtube-nocookie\.com'; AudioOnly = $false }
    [pscustomobject]@{ Name = 'TikTok';      Hosts = 'tiktok\.com';                                  AudioOnly = $false }
    [pscustomobject]@{ Name = 'Instagram';   Hosts = 'instagram\.com';                               AudioOnly = $false }
    [pscustomobject]@{ Name = 'Twitter / X'; Hosts = 'twitter\.com|x\.com';                          AudioOnly = $false }
    [pscustomobject]@{ Name = 'Twitch';      Hosts = 'twitch\.tv';                                   AudioOnly = $false }
    [pscustomobject]@{ Name = 'Facebook';    Hosts = 'facebook\.com|fb\.watch';                      AudioOnly = $false }
    [pscustomobject]@{ Name = 'Reddit';      Hosts = 'reddit\.com|redd\.it';                         AudioOnly = $false }
    [pscustomobject]@{ Name = 'Vimeo';       Hosts = 'vimeo\.com';                                   AudioOnly = $false }
    [pscustomobject]@{ Name = 'Dailymotion'; Hosts = 'dailymotion\.com|dai\.ly';                     AudioOnly = $false }
    [pscustomobject]@{ Name = 'Bilibili';    Hosts = 'bilibili\.com|b23\.tv';                        AudioOnly = $false }
    [pscustomobject]@{ Name = 'SoundCloud';  Hosts = 'soundcloud\.com';                              AudioOnly = $true }
    [pscustomobject]@{ Name = 'Bandcamp';    Hosts = 'bandcamp\.com';                                AudioOnly = $true }
    [pscustomobject]@{ Name = 'Other site';  Hosts = $null;                                          AudioOnly = $false }
)
$script:CurrentSource = $script:Sources[0]

$script:AudioFormatOptions = @(
    [pscustomobject]@{ Label = 'MP3';                Value = 'mp3';    Ext = 'MP3' }
    [pscustomobject]@{ Label = 'M4A (AAC)';          Value = 'm4a';    Ext = 'M4A' }
    [pscustomobject]@{ Label = 'Opus';               Value = 'opus';   Ext = 'OPUS' }
    [pscustomobject]@{ Label = 'OGG Vorbis';         Value = 'vorbis'; Ext = 'OGG' }
    [pscustomobject]@{ Label = 'FLAC (lossless)';    Value = 'flac';   Ext = 'FLAC' }
    [pscustomobject]@{ Label = 'WAV (uncompressed)'; Value = 'wav';    Ext = 'WAV' }
)

$script:AudioQualityOptions = @(
    [pscustomobject]@{ Label = 'Best VBR (V0, about 245 kbps)';   Value = '0' }
    [pscustomobject]@{ Label = 'High VBR (V2, about 190 kbps)';   Value = '2' }
    [pscustomobject]@{ Label = 'Medium VBR (V5, about 130 kbps)'; Value = '5' }
    [pscustomobject]@{ Label = '320 kbps (CBR)';                  Value = '320K' }
    [pscustomobject]@{ Label = '256 kbps (CBR)';                  Value = '256K' }
    [pscustomobject]@{ Label = '192 kbps (CBR)';                  Value = '192K' }
    [pscustomobject]@{ Label = '128 kbps (CBR)';                  Value = '128K' }
)

$script:ResolutionOptions = @(
    [pscustomobject]@{ Label = 'Best available'; Value = 'Best' }
    [pscustomobject]@{ Label = '2160p (4K)';     Value = '2160' }
    [pscustomobject]@{ Label = '1440p';          Value = '1440' }
    [pscustomobject]@{ Label = '1080p';          Value = '1080' }
    [pscustomobject]@{ Label = '720p';           Value = '720' }
    [pscustomobject]@{ Label = '480p';           Value = '480' }
    [pscustomobject]@{ Label = '360p';           Value = '360' }
)

$script:FrameRateOptions = @(
    [pscustomobject]@{ Label = 'Any';    Value = 'Any' }
    [pscustomobject]@{ Label = '60 fps'; Value = '60' }
    [pscustomobject]@{ Label = '30 fps'; Value = '30' }
)

$script:ContainerOptions = @(
    [pscustomobject]@{ Label = 'MP4 (plays everywhere)';         Value = 'mp4' }
    [pscustomobject]@{ Label = 'MKV (keeps the original codecs)'; Value = 'mkv' }
)

$script:CookieOptions = @(
    [pscustomobject]@{ Label = 'None';             Value = '' }
    [pscustomobject]@{ Label = 'Firefox';          Value = 'firefox' }
    [pscustomobject]@{ Label = 'Chrome';           Value = 'chrome' }
    [pscustomobject]@{ Label = 'Edge';             Value = 'edge' }
    [pscustomobject]@{ Label = 'Brave';            Value = 'brave' }
    [pscustomobject]@{ Label = 'Opera';            Value = 'opera' }
    [pscustomobject]@{ Label = 'Vivaldi';          Value = 'vivaldi' }
    [pscustomobject]@{ Label = 'cookies.txt file'; Value = 'file' }
)

function Get-DefaultSettings {
    [ordered]@{
        VideoDir             = Join-Path ([Environment]::GetFolderPath('MyVideos')) 'Cybtek Downloader'
        AudioDir             = Join-Path ([Environment]::GetFolderPath('MyMusic')) 'Cybtek Downloader'
        LogDir               = Join-Path $script:AppDataDir 'logs'
        ArchiveDir           = Join-Path $script:AppDataDir 'archive'
        YtDlpPath            = ''
        FfmpegPath           = ''
        DenoPath             = ''
        FfmpegInstalledBuild = ''
        AutoPaste            = $true
        CheckUpdatesOnStart  = $true
        ArchiveBeforeUpdate  = $false
        # Sources
        StartupSource        = 'Default'   # 'Default' or 'Last'
        DefaultSource        = 'YouTube'
        LastSource           = 'YouTube'
        CookieSource         = ''
        CookieFile           = ''
        # Downloads
        DownloadPlaylists    = $false
        SpeedLimit           = ''
        Fragments            = 4
        Retries              = 10
        Proxy                = ''
        UseDownloadHistory   = $false
        OverwriteFiles       = $false
        RestrictFilenames    = $false
        SaveThumbnailImage   = $false
        SaveDescription      = $false
        ExtraArgs            = ''
        # Audio
        AudioFormat          = 'mp3'
        AudioQuality         = '0'
        AudioEmbedThumbnail  = $true
        AudioEmbedMetadata   = $true
        AudioSponsorBlock    = $false
        AudioTemplate        = '%(title)s.%(ext)s'
        AudioSplitChapters   = $false
        AudioKeepFullFile    = $true
        # Video
        VideoMaxHeight       = '1080'
        VideoMaxFps          = 'Any'
        VideoContainer       = 'mp4'
        VideoPreferH264      = $true
        VideoEmbedThumbnail  = $true
        VideoEmbedMetadata   = $true
        VideoEmbedChapters   = $true
        VideoEmbedSubs       = $false
        VideoAutoSubs        = $false
        VideoSubLangs        = 'en'
        VideoSponsorBlock    = $false
        VideoTemplate        = '%(title)s.%(ext)s'
        VideoSplitChapters   = $false
        VideoKeepFullFile    = $true
    }
}

function Read-AppSettings {
    $settings = Get-DefaultSettings
    if (Test-Path -LiteralPath $script:SettingsFile) {
        try {
            $saved = Get-Content -LiteralPath $script:SettingsFile -Raw | ConvertFrom-Json
            foreach ($p in $saved.PSObject.Properties) {
                if (-not $settings.Contains($p.Name)) { continue }
                # Ignore values of the wrong type (e.g. from a damaged file) and keep the default
                $default = $settings[$p.Name]
                $valid = if ($default -is [bool]) { $p.Value -is [bool] }
                         elseif ($default -is [int]) { $p.Value -is [int] -or $p.Value -is [long] }
                         else { $p.Value -is [string] }
                if (-not $valid) { continue }
                $value = $p.Value
                # Paths saved under the old data folder now live in the new one
                if ($value -is [string] -and $script:AppDataDir -ne $script:OldAppDataDir -and
                    $value.StartsWith($script:OldAppDataDir, [StringComparison]::OrdinalIgnoreCase)) {
                    $value = $script:AppDataDir + $value.Substring($script:OldAppDataDir.Length)
                }
                $settings[$p.Name] = $value
            }
        } catch { }
    }
    $settings
}

function Save-AppSettings {
    New-Item -ItemType Directory -Force -Path $script:AppDataDir | Out-Null
    $script:Settings | ConvertTo-Json | Set-Content -LiteralPath $script:SettingsFile -Encoding UTF8
}

$script:Settings = Read-AppSettings

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

function Pt([int]$X, [int]$Y) { New-Object System.Drawing.Point($X, $Y) }
function Sz([int]$W, [int]$H) { New-Object System.Drawing.Size($W, $H) }

function ConvertTo-Arg([string]$Value) { '"' + ($Value -replace '"', '\"') + '"' }

function Find-Option($Options, [string]$Value) {
    $match = $Options | Where-Object { $_.Value -eq $Value } | Select-Object -First 1
    if ($match) { $match } else { $Options[0] }
}

function Get-Source([string]$Name) {
    $match = $script:Sources | Where-Object { $_.Name -eq $Name } | Select-Object -First 1
    if ($match) { $match } else { $script:Sources[0] }
}

# True when the text is a link to the given source's site.
function Test-SourceUrl([string]$Text, $Source) {
    if (-not $Source.Hosts) { return $false }
    $Text -match ('^\s*(https?://)?([\w-]+\.)*(' + $Source.Hosts + ')(/\S*)?\s*$')
}

function Test-DownloadUrl([string]$Text) {
    if ($Text -match '^\s*https?://\S+\s*$') { return $true }
    foreach ($s in $script:Sources) { if (Test-SourceUrl $Text $s) { return $true } }
    $false
}

function Get-NormalizedUrl([string]$Text) {
    $url = $Text.Trim()
    if ($url -notmatch '^https?://') { $url = 'https://' + $url }
    $url
}

function Write-Activity([string]$Message) {
    $line = '{0:HH:mm:ss}  {1}' -f (Get-Date), $Message
    $script:ActivityLines.Add($line)
    if ($script:ActivityLines.Count -gt 5000) { $script:ActivityLines.RemoveRange(0, 1000) }
    try {
        New-Item -ItemType Directory -Force -Path $script:Settings.LogDir | Out-Null
        $logFile = Join-Path $script:Settings.LogDir ('cybtek-downloader_{0:yyyy-MM-dd}.log' -f (Get-Date))
        Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8
    } catch { }
    if ($script:ActivityBox -and -not $script:ActivityBox.IsDisposed) {
        $script:ActivityBox.AppendText($line + [Environment]::NewLine)
    }
}

function Set-Status([string]$Text) {
    $lblStatus.Text = $Text
    if ($script:ActivityStatus -and -not $script:ActivityStatus.IsDisposed) { $script:ActivityStatus.Text = $Text }
}

function Open-Folder([string]$Path) {
    if (-not $Path) { return }
    New-Item -ItemType Directory -Force -Path $Path | Out-Null
    Start-Process -FilePath 'explorer.exe' -ArgumentList (ConvertTo-Arg $Path)
}

function Show-Message([string]$Text, [string]$Buttons = 'OK', [string]$Icon = 'Information') {
    [System.Windows.Forms.MessageBox]::Show($form, $Text, $script:AppName, $Buttons, $Icon)
}

# Runs a program and returns everything it printed (used for --version / -version).
function Get-ProgramOutput([string]$Path, [string]$Arguments) {
    try {
        $psi = New-Object System.Diagnostics.ProcessStartInfo($Path, $Arguments)
        $psi.UseShellExecute = $false
        $psi.RedirectStandardOutput = $true
        $psi.CreateNoWindow = $true
        $p = [System.Diagnostics.Process]::Start($psi)
        $out = $p.StandardOutput.ReadToEnd()
        [void]$p.WaitForExit(30000)
        return $out
    } catch {
        return $null
    }
}

# ---------------------------------------------------------------------------
# Sources
# ---------------------------------------------------------------------------

function Set-Source([string]$Name, [switch]$NoSave) {
    $src = Get-Source $Name
    $script:CurrentSource = $src
    foreach ($mi in $miSource.DropDownItems) {
        if ($mi -is [System.Windows.Forms.ToolStripMenuItem] -and $mi.Tag -is [string]) { $mi.Checked = ($mi.Tag -eq $src.Name) }
    }
    $lblUrl.Text = if ($src.Hosts) { "$($src.Name) URL (type, paste, or just copy a $($src.Name) link):" }
                   else { 'Video URL (type or paste a link from any site yt-dlp supports):' }
    if (-not $NoSave) {
        $script:Settings.LastSource = $src.Name
        Save-AppSettings
        Write-Activity "Source set to $($src.Name)."
    }
    Update-ButtonState
    # Re-check the clipboard so a link already copied from the new site is picked up
    $script:LastClipboard = ''
    Invoke-ClipboardCheck
}

# ---------------------------------------------------------------------------
# Dependencies: finding them and checking their versions
# ---------------------------------------------------------------------------

function Resolve-Tool([string]$ConfiguredPath, [string]$ExeName) {
    $candidates = @()
    if ($ConfiguredPath) { $candidates += $ConfiguredPath }
    $candidates += (Join-Path $script:BinDir "$ExeName.exe")
    if ($PSScriptRoot) { $candidates += (Join-Path $PSScriptRoot "$ExeName.exe") }
    foreach ($c in $candidates) {
        if ($c -and (Test-Path -LiteralPath $c -PathType Leaf)) { return $c }
    }
    $cmd = Get-Command $ExeName -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($cmd) { return $cmd.Source }
    return $null
}

function Resolve-YtDlp  { Resolve-Tool $script:Settings.YtDlpPath 'yt-dlp' }
function Resolve-Ffmpeg { Resolve-Tool $script:Settings.FfmpegPath 'ffmpeg' }
function Resolve-Deno   { Resolve-Tool $script:Settings.DenoPath 'deno' }

# "a", "a and b", "a, b and c"
function Join-Names([string[]]$Names) {
    $Names = @($Names)
    if ($Names.Count -le 2) { return $Names -join ' and ' }
    ($Names[0..($Names.Count - 2)] -join ', ') + ' and ' + $Names[-1]
}

function Get-DenoVersion([string]$Path) {
    $out = Get-ProgramOutput $Path '--version'
    if ($out -match '(?m)^deno (\d+\.\d+\.\d+)') { $Matches[1] } else { $null }
}

function Get-LatestDenoVersion {
    try {
        $release = Invoke-RestMethod -Uri $script:DenoApiUrl -TimeoutSec 10 -Headers @{ 'User-Agent' = 'CybtekDownloader' }
        return ("$($release.tag_name)" -replace '^v', '')
    } catch {
        return $null
    }
}

function Get-FfmpegInfo([string]$Path) {
    $out = Get-ProgramOutput $Path '-version'
    if (-not $out -or $out -notmatch 'ffmpeg version (\S+)') { return $null }
    $version = $Matches[1]
    $buildDate = $null
    # Daily builds look like "N-121234-g1a2b3c4d5e-20261101"
    if ($version -match '-(\d{8})$') {
        $buildDate = [datetime]::ParseExact($Matches[1], 'yyyyMMdd', [Globalization.CultureInfo]::InvariantCulture)
    } elseif ($script:Settings.FfmpegInstalledBuild -and $Path -eq (Join-Path $script:BinDir 'ffmpeg.exe')) {
        $buildDate = [datetime]::ParseExact($script:Settings.FfmpegInstalledBuild, 'yyyy-MM-dd', [Globalization.CultureInfo]::InvariantCulture)
    }
    [pscustomobject]@{ Version = $version; BuildDate = $buildDate }
}

function Get-LatestYtDlpVersion {
    try {
        $release = Invoke-RestMethod -Uri $script:YtDlpApiUrl -TimeoutSec 10 -Headers @{ 'User-Agent' = 'CybtekDownloader' }
        return $release.tag_name
    } catch {
        return $null
    }
}

function Get-LatestFfmpegBuild {
    try {
        $release = Invoke-RestMethod -Uri $script:FfmpegApiUrl -TimeoutSec 10 -Headers @{ 'User-Agent' = 'CybtekDownloader' }
        $asset = $release.assets | Where-Object { $_.name -eq $script:FfmpegAssetName } | Select-Object -First 1
        if (-not $asset) { return $null }
        [pscustomobject]@{
            Date   = ([datetime]$asset.updated_at).Date
            Url    = $asset.browser_download_url
            SizeMB = [int]($asset.size / 1MB)
        }
    } catch {
        return $null
    }
}

function Test-NewerVersion([string]$Current, [string]$Latest) {
    if (-not $Current -or -not $Latest) { return $false }
    try { return ([version]$Latest) -gt ([version]$Current) } catch { return $Latest -ne $Current }
}

function Format-FfmpegVersion {
    if ($script:FfmpegBuildDate) { 'build {0:yyyy-MM-dd}' -f $script:FfmpegBuildDate } else { $script:FfmpegVersion }
}

# Finds the tools, reads their versions and, with -Online, asks GitHub for the newest ones.
function Update-VersionInfo([switch]$Online) {
    $form.Cursor = 'WaitCursor'
    if ($Online) {
        $lblDeps.Text = "$([char]0x25CF)  Checking dependencies..."
        $lblDeps.ForeColor = [CyColors]::Muted
        $form.Refresh()
    }

    $script:YtDlpExe = Resolve-YtDlp
    $script:YtDlpVersion = if ($script:YtDlpExe) { "$(Get-ProgramOutput $script:YtDlpExe '--version')".Trim() } else { $null }

    $script:FfmpegExe = Resolve-Ffmpeg
    $info = if ($script:FfmpegExe) { Get-FfmpegInfo $script:FfmpegExe } else { $null }
    $script:FfmpegVersion = if ($info) { $info.Version } else { $null }
    $script:FfmpegBuildDate = if ($info) { $info.BuildDate } else { $null }

    $script:DenoExe = Resolve-Deno
    $script:DenoVersion = if ($script:DenoExe) { Get-DenoVersion $script:DenoExe } else { $null }

    if ($Online) {
        $script:UpdateCheckRan = $true
        $script:YtDlpLatest = Get-LatestYtDlpVersion
        $script:DenoLatest = Get-LatestDenoVersion
        $latestFfmpeg = Get-LatestFfmpegBuild
        if ($latestFfmpeg) {
            $script:FfmpegLatestDate = $latestFfmpeg.Date
            $script:FfmpegZipUrl = $latestFfmpeg.Url
            $script:FfmpegZipSizeMB = $latestFfmpeg.SizeMB
        } else {
            $script:FfmpegLatestDate = $null
        }
    }

    $script:YtDlpUpdate = [bool]($script:YtDlpVersion -and (Test-NewerVersion $script:YtDlpVersion $script:YtDlpLatest))
    $script:FfmpegUpdate = [bool]($script:FfmpegBuildDate -and $script:FfmpegLatestDate -and
        (($script:FfmpegLatestDate - $script:FfmpegBuildDate).TotalDays -gt $script:FfmpegMaxAgeDays))
    $script:DenoUpdate = [bool]($script:DenoVersion -and (Test-NewerVersion $script:DenoVersion $script:DenoLatest))

    Update-DependencyStatus
    $form.Cursor = 'Default'
}

# One line under the menu bar: are the dependencies installed and up to date?
# The versions are in the tooltip and in Help > About.
function Update-DependencyStatus {
    $dot = [char]0x25CF
    $actions = Get-DependencyActions
    $missing = @($actions | Where-Object { $_.Action -eq 'install' } | ForEach-Object { $_.Name })
    $outdated = @($actions | Where-Object { $_.Action -eq 'update' } | ForEach-Object { $_.Name })
    $unreadable = @()
    if ($script:YtDlpExe -and -not $script:YtDlpVersion) { $unreadable += 'yt-dlp' }
    if ($script:FfmpegExe -and -not $script:FfmpegVersion) { $unreadable += 'ffmpeg' }
    if ($script:DenoExe -and -not $script:DenoVersion) { $unreadable += 'Deno' }

    $parts = @()
    if ($missing.Count -gt 1) { $parts += "Dependencies not installed ($(Join-Names $missing))" }
    elseif ($missing.Count -eq 1) { $parts += "Dependency missing: $($missing[0])" }
    if ($outdated.Count -gt 1) { $parts += "$(if ($parts) { 'not up to date' } else { 'Dependencies not up to date' }) ($(Join-Names $outdated))" }
    elseif ($outdated.Count -eq 1) { $parts += "$(if ($parts) { 'not up to date' } else { 'Dependency not up to date' }): $($outdated[0])" }
    if ($unreadable.Count) { $parts += "$(Join-Names $unreadable) could not be run" }

    if ($parts) {
        $fix = if ($missing -and $outdated) { 'fix' } elseif ($missing) { 'install' } elseif ($outdated) { 'update' } else { $null }
        $lblDeps.Text = "$dot  $($parts -join '; ')" + $(if ($fix) { "  -  click to $fix" } else { '' })
        $lblDeps.ForeColor = if ($missing -or $unreadable) { [CyColors]::Bad } else { [CyColors]::Warn }
        $lblDeps.Cursor = if ($fix) { 'Hand' } else { 'Default' }
    } elseif ($script:YtDlpLatest -or $script:FfmpegLatestDate -or $script:DenoLatest) {
        $lblDeps.Text = "$dot  Dependencies installed and up to date"
        $lblDeps.ForeColor = [CyColors]::Good
        $lblDeps.Cursor = 'Default'
    } else {
        $how = if ($script:UpdateCheckRan) { 'could not check for updates' } else { 'not checked for updates' }
        $lblDeps.Text = "$dot  Dependencies installed ($how)"
        $lblDeps.ForeColor = [CyColors]::Muted
        $lblDeps.Cursor = 'Default'
    }

    $ytTip = if ($script:YtDlpVersion) { "yt-dlp $($script:YtDlpVersion)" + $(if ($script:YtDlpLatest) { "  (latest $($script:YtDlpLatest))" } else { '' }) }
             elseif ($script:YtDlpExe) { 'yt-dlp: could not be run' } else { 'yt-dlp: not installed' }
    $ffTip = if ($script:FfmpegVersion) { "ffmpeg $(Format-FfmpegVersion)" + $(if ($script:FfmpegLatestDate) { "  (latest build $('{0:yyyy-MM-dd}' -f $script:FfmpegLatestDate))" } else { '' }) }
             elseif ($script:FfmpegExe) { 'ffmpeg: could not be run' } else { 'ffmpeg: not installed' }
    $denoTip = if ($script:DenoVersion) { "Deno $($script:DenoVersion)" + $(if ($script:DenoLatest) { "  (latest $($script:DenoLatest))" } else { '' }) }
               elseif ($script:DenoExe) { 'Deno: could not be run' } else { 'Deno: not installed' }
    $depsTip.SetToolTip($lblDeps, "$ytTip`n$ffTip`n$denoTip")
}

function Invoke-DependencyStatusClick {
    if ($script:IsBusy) { return }
    $actions = Get-DependencyActions
    if ($actions.Count -and (Request-DependencyActions $actions)) { Start-DependencyJobs ($actions | ForEach-Object { $_.Name }) }
}

# What needs doing, based on the last Update-VersionInfo.
function Get-DependencyActions([switch]$MissingOnly) {
    $actions = @()
    if (-not $script:YtDlpExe) {
        $actions += [pscustomobject]@{ Name = 'yt-dlp'; Action = 'install'; Detail = 'not installed' }
    } elseif ($script:YtDlpUpdate -and -not $MissingOnly) {
        $actions += [pscustomobject]@{ Name = 'yt-dlp'; Action = 'update'; Detail = "$($script:YtDlpVersion)  ->  $($script:YtDlpLatest)" }
    }
    if (-not $script:FfmpegExe) {
        $actions += [pscustomobject]@{ Name = 'ffmpeg'; Action = 'install'; Detail = 'not installed' }
    } elseif ($script:FfmpegUpdate -and -not $MissingOnly) {
        $actions += [pscustomobject]@{ Name = 'ffmpeg'; Action = 'update'; Detail = "$(Format-FfmpegVersion)  ->  build $('{0:yyyy-MM-dd}' -f $script:FfmpegLatestDate)" }
    }
    if (-not $script:DenoExe) {
        $actions += [pscustomobject]@{ Name = 'Deno'; Action = 'install'; Detail = 'not installed (needed for YouTube)' }
    } elseif ($script:DenoUpdate -and -not $MissingOnly) {
        $actions += [pscustomobject]@{ Name = 'Deno'; Action = 'update'; Detail = "$($script:DenoVersion)  ->  $($script:DenoLatest)" }
    }
    , $actions
}

# Lists what needs installing or updating and asks Yes/No. Returns $true for Yes.
function Request-DependencyActions($Actions) {
    $Actions = @($Actions)
    $names = Join-Names ($Actions | ForEach-Object { $_.Name })
    $installs = @($Actions | Where-Object { $_.Action -eq 'install' }).Count
    if ($installs -eq $Actions.Count) {
        $verb = 'installed'; $question = 'Install now?'
    } elseif ($installs -eq 0) {
        $verb = 'updated'; $question = 'Update now?'
    } else {
        $verb = 'installed or updated'; $question = 'Install and update now?'
    }
    $head = if ($Actions.Count -gt 2) { "$names all need to be $verb." }
            elseif ($Actions.Count -eq 2) { "$names both need to be $verb." }
            else { "$names needs to be $verb." }
    $lines = $Actions | ForEach-Object { "    {0}:   {1}" -f $_.Name, $_.Detail }
    $msg = $head + "`n`n" + ($lines -join "`n") + "`n`n" + $question
    $sizes = @()
    if ($Actions | Where-Object { $_.Name -eq 'ffmpeg' }) {
        $sizes += "ffmpeg is about $(if ($script:FfmpegZipSizeMB) { $script:FfmpegZipSizeMB } else { 190 }) MB"
    }
    if ($Actions | Where-Object { $_.Name -eq 'Deno' }) { $sizes += 'Deno is about 40 MB' }
    if ($sizes) { $msg += "`n`n(Download size: $($sizes -join ', ').)" }
    (Show-Message $msg 'YesNo' 'Question') -eq 'Yes'
}

# Start-up check: always looks for missing tools; looks for updates when the setting is on.
function Invoke-StartupDependencyCheck {
    Update-VersionInfo -Online:([bool]$script:Settings.CheckUpdatesOnStart)
    $actions = Get-DependencyActions
    if ($actions.Count) {
        Write-Activity ('Dependency check: ' + (($actions | ForEach-Object { "$($_.Name) $($_.Detail)" }) -join '; '))
        if (Request-DependencyActions $actions) { Start-DependencyJobs ($actions | ForEach-Object { $_.Name }) }
    } else {
        Write-Activity 'Dependency check: yt-dlp, ffmpeg and Deno are installed.'
    }
}

function Invoke-InstallDependencies {
    if ($script:IsBusy) { return }
    Update-VersionInfo
    $actions = Get-DependencyActions -MissingOnly
    if ($actions.Count) {
        if (Request-DependencyActions $actions) { Start-DependencyJobs ($actions | ForEach-Object { $_.Name }) }
    } elseif ((Show-Message "yt-dlp, ffmpeg and Deno are all installed.`n`nReinstall the latest versions of all three?" 'YesNo' 'Question') -eq 'Yes') {
        Update-VersionInfo -Online
        Start-DependencyJobs $script:DependencyNames
    }
}

function Invoke-UpdateDependencies([switch]$CheckOnly) {
    if ($script:IsBusy) { return }
    Update-VersionInfo -Online
    $actions = Get-DependencyActions
    $updates = @($actions | Where-Object { $_.Action -eq 'update' })
    if ($CheckOnly -and $actions.Count) { $updates = $actions }
    if ($updates.Count) {
        if (Request-DependencyActions $updates) { Start-DependencyJobs ($updates | ForEach-Object { $_.Name }) }
        return
    }
    if (-not $script:YtDlpLatest -and -not $script:FfmpegLatestDate -and -not $script:DenoLatest) {
        [void](Show-Message 'Could not reach GitHub to check for updates. Check your internet connection and try again.' 'OK' 'Warning')
    } elseif ($actions.Count) {
        $notInstalled = @($actions | ForEach-Object { $_.Name })
        [void](Show-Message "Nothing to update. $(Join-Names $notInstalled) $(if ($notInstalled.Count -gt 1) { 'are' } else { 'is' }) not installed yet - use Help > Install Dependencies.")
    } else {
        [void](Show-Message 'yt-dlp, ffmpeg and Deno are all up to date.')
    }
}

# ---------------------------------------------------------------------------
# Dependencies: installing, updating and archiving
# ---------------------------------------------------------------------------

# Zips the current copies of the given tools into the archive folder.
function Save-DependencyArchive([string[]]$Names = $script:DependencyNames, [switch]$Quiet) {
    $files = @()
    $ytdlp = Resolve-YtDlp
    $ffmpeg = Resolve-Ffmpeg
    $deno = Resolve-Deno
    if ($Names -contains 'yt-dlp' -and $ytdlp) { $files += $ytdlp }
    if ($Names -contains 'ffmpeg' -and $ffmpeg) {
        $files += $ffmpeg
        $ffprobe = Join-Path (Split-Path -Parent $ffmpeg) 'ffprobe.exe'
        if (Test-Path -LiteralPath $ffprobe) { $files += $ffprobe }
    }
    if ($Names -contains 'Deno' -and $deno) { $files += $deno }
    if (-not $files) {
        if (-not $Quiet) { [void](Show-Message 'There is nothing to archive: yt-dlp, ffmpeg and Deno are not installed.' 'OK' 'Warning') }
        return
    }

    $parts = @()
    if ($Names -contains 'yt-dlp' -and $script:YtDlpVersion) { $parts += "yt-dlp-$($script:YtDlpVersion)" }
    if ($Names -contains 'ffmpeg' -and $script:FfmpegVersion) { $parts += 'ffmpeg-' + (Format-FfmpegVersion) }
    if ($Names -contains 'Deno' -and $script:DenoVersion) { $parts += "deno-$($script:DenoVersion)" }
    $label = (($parts -join '_') -replace '[^\w\.-]+', '-')
    $zipPath = Join-Path $script:Settings.ArchiveDir ('dependencies_{0:yyyy-MM-dd_HHmmss}_{1}.zip' -f (Get-Date), $label)

    $form.Cursor = 'WaitCursor'
    Set-Status 'Archiving dependencies...'
    $form.Refresh()
    try {
        New-Item -ItemType Directory -Force -Path $script:Settings.ArchiveDir | Out-Null
        $zip = [System.IO.Compression.ZipFile]::Open($zipPath, [System.IO.Compression.ZipArchiveMode]::Create)
        try {
            foreach ($f in $files) {
                [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($zip, $f, [IO.Path]::GetFileName($f), [System.IO.Compression.CompressionLevel]::Fastest)
            }
        } finally {
            $zip.Dispose()
        }
        Write-Activity "Archived $(($files | ForEach-Object { [IO.Path]::GetFileName($_) }) -join ', ') to $zipPath"
        Set-Status 'Dependencies archived.'
        if (-not $Quiet -and (Show-Message "Archived to:`n$zipPath`n`nOpen the archive folder?" 'YesNo' 'Information') -eq 'Yes') {
            Open-Folder $script:Settings.ArchiveDir
        }
    } catch {
        Write-Activity "Archiving failed: $($_.Exception.Message)"
        Set-Status 'Archiving failed.'
        if (-not $Quiet) { [void](Show-Message "Archiving failed:`n$($_.Exception.Message)" 'OK' 'Error') }
    } finally {
        $form.Cursor = 'Default'
    }
}

# Installs or updates the named tools one after another.
function Start-DependencyJobs([string[]]$Names) {
    if ($script:IsBusy -or -not $Names) { return }
    if ($script:Settings.ArchiveBeforeUpdate) {
        $installed = @($Names | Where-Object {
            ($_ -eq 'yt-dlp' -and $script:YtDlpExe) -or ($_ -eq 'ffmpeg' -and $script:FfmpegExe) -or ($_ -eq 'Deno' -and $script:DenoExe) })
        if ($installed) { Save-DependencyArchive -Names $installed -Quiet }
    }
    $script:DepQueue = New-Object System.Collections.Generic.Queue[string]
    foreach ($n in $Names) { $script:DepQueue.Enqueue($n) }
    $script:DepFailures = 0
    Start-NextDependencyJob
}

function Start-NextDependencyJob {
    if ($script:DepQueue.Count -eq 0) {
        Set-Busy $false
        Update-VersionInfo
        if ($script:DepFailures) { Set-Status 'Some dependencies could not be installed. See File > Activity.' }
        else { Set-Status 'Dependencies are installed and up to date.' }
        return
    }
    switch ($script:DepQueue.Dequeue()) {
        'yt-dlp' { Start-YtDlpInstall }
        'ffmpeg' { Start-FfmpegInstall }
        'Deno'   { Start-DenoInstall }
    }
}

function Start-WebDownload([string]$Url, [string]$Destination, [string]$Label, [scriptblock]$OnSuccess) {
    $script:WebOnSuccess = $OnSuccess
    $script:WebLabel = $Label
    $script:WebDestination = $Destination
    $script:WebLastPct = -1
    Set-Busy $true
    Set-Status "Downloading $Label..."
    Write-Activity "Downloading $Label from $Url"

    $wc = New-Object System.Net.WebClient
    $wc.Headers.Add('User-Agent', 'CybtekDownloader')
    $wc.add_DownloadProgressChanged({
        param($s, $e)
        if ($e.ProgressPercentage -eq $script:WebLastPct) { return }
        $script:WebLastPct = $e.ProgressPercentage
        $progress.Value = [Math]::Min(100, [Math]::Max(0, $e.ProgressPercentage))
        if ($e.TotalBytesToReceive -gt 0) {
            Set-Status ('Downloading {0}... {1}%  ({2:N1} of {3:N1} MB)' -f $script:WebLabel, $e.ProgressPercentage, ($e.BytesReceived / 1MB), ($e.TotalBytesToReceive / 1MB))
        } else {
            Set-Status ('Downloading {0}... {1:N1} MB' -f $script:WebLabel, ($e.BytesReceived / 1MB))
        }
    })
    $wc.add_DownloadFileCompleted({
        param($s, $e)
        $s.Dispose()
        if ($e.Error) {
            $script:DepFailures++
            Write-Activity "Downloading $($script:WebLabel) failed: $($e.Error.Message)"
            Remove-Item -LiteralPath $script:WebDestination -Force -ErrorAction SilentlyContinue
            [void](Show-Message "Downloading $($script:WebLabel) failed:`n$($e.Error.Message)" 'OK' 'Error')
        } else {
            try {
                & $script:WebOnSuccess $script:WebDestination
                Write-Activity "$($script:WebLabel) installed."
            } catch {
                $script:DepFailures++
                Write-Activity "Installing $($script:WebLabel) failed: $($_.Exception.Message)"
                [void](Show-Message "Installing $($script:WebLabel) failed:`n$($_.Exception.Message)" 'OK' 'Error')
            }
        }
        Start-NextDependencyJob
    })
    $wc.DownloadFileAsync([uri]$Url, $Destination)
}

function Start-YtDlpInstall {
    # Replace our own copy in place; a copy installed by winget, pip, scoop etc. is left
    # alone and this app switches to its own copy in the bin folder instead.
    $current = Resolve-YtDlp
    $ownDirs = @($script:BinDir, $PSScriptRoot) | Where-Object { $_ }
    if ($current -and ($ownDirs -contains (Split-Path -Parent $current))) {
        $script:YtDlpTarget = $current
    } else {
        $script:YtDlpTarget = Join-Path $script:BinDir 'yt-dlp.exe'
    }

    $tmp = Join-Path $env:TEMP ('yt-dlp_{0}.exe' -f [guid]::NewGuid().ToString('N'))
    Start-WebDownload -Url $script:YtDlpDownloadUrl -Destination $tmp -Label 'yt-dlp' -OnSuccess {
        param($file)
        New-Item -ItemType Directory -Force -Path (Split-Path -Parent $script:YtDlpTarget) | Out-Null
        Move-Item -LiteralPath $file -Destination $script:YtDlpTarget -Force
        $script:Settings.YtDlpPath = $script:YtDlpTarget
        Save-AppSettings
        Write-Activity "yt-dlp saved to $($script:YtDlpTarget)"
    }
}

function Start-FfmpegInstall {
    $tmp = Join-Path $env:TEMP ('ffmpeg_{0}.zip' -f [guid]::NewGuid().ToString('N'))
    Start-WebDownload -Url $script:FfmpegZipUrl -Destination $tmp -Label 'ffmpeg' -OnSuccess {
        param($file)
        Set-Status 'Extracting ffmpeg...'
        $progress.Style = 'Marquee'
        $form.Refresh()
        New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
        $zip = [IO.Compression.ZipFile]::OpenRead($file)
        try {
            foreach ($entry in $zip.Entries) {
                if ($entry.Name -in @('ffmpeg.exe', 'ffprobe.exe')) {
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $script:BinDir $entry.Name), $true)
                }
            }
        } finally {
            $zip.Dispose()
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
        $script:Settings.FfmpegPath = Join-Path $script:BinDir 'ffmpeg.exe'
        $build = if ($script:FfmpegLatestDate) { $script:FfmpegLatestDate } else { Get-Date }
        $script:Settings.FfmpegInstalledBuild = '{0:yyyy-MM-dd}' -f $build
        Save-AppSettings
        Write-Activity "ffmpeg saved to $($script:BinDir)"
    }
}

# Deno comes from its official releases as a zip holding a single deno.exe
function Start-DenoInstall {
    $tmp = Join-Path $env:TEMP ('deno_{0}.zip' -f [guid]::NewGuid().ToString('N'))
    Start-WebDownload -Url $script:DenoZipUrl -Destination $tmp -Label 'Deno' -OnSuccess {
        param($file)
        Set-Status 'Extracting Deno...'
        $progress.Style = 'Marquee'
        $form.Refresh()
        New-Item -ItemType Directory -Force -Path $script:BinDir | Out-Null
        $target = Join-Path $script:BinDir 'deno.exe'
        $zip = [IO.Compression.ZipFile]::OpenRead($file)
        try {
            $entry = $zip.Entries | Where-Object { $_.Name -eq 'deno.exe' } | Select-Object -First 1
            if (-not $entry) { throw 'The download did not contain deno.exe.' }
            [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
        } finally {
            $zip.Dispose()
            Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
        }
        $script:Settings.DenoPath = $target
        Save-AppSettings
        Write-Activity "Deno saved to $target"
    }
}

# ---------------------------------------------------------------------------
# WebView2 (embedded browser for the Sign-In addon)
# ---------------------------------------------------------------------------

# The installed WebView2 runtime version, or $null if it is not installed.
function Test-WebView2Runtime {
    foreach ($root in @('HKLM:\SOFTWARE\WOW6432Node\Microsoft\EdgeUpdate\Clients',
                        'HKLM:\SOFTWARE\Microsoft\EdgeUpdate\Clients',
                        'HKCU:\SOFTWARE\Microsoft\EdgeUpdate\Clients')) {
        $pv = (Get-ItemProperty -LiteralPath (Join-Path $root $script:WebView2RuntimeId) -ErrorAction SilentlyContinue).pv
        if ($pv -and $pv -ne '0.0.0.0') { return $pv }
    }
    $null
}

# The folder holding our WebView2 SDK, or $null if it is not there yet.
function Resolve-WebView2 {
    if ((Test-Path -LiteralPath $script:WebView2CoreDll) -and (Test-Path -LiteralPath $script:WebView2LoaderDll)) { return $script:WebView2Dir }
    $null
}

# Downloads the WebView2 .NET SDK from NuGet and extracts the DLLs we need into the webview2 folder.
function Install-WebView2Sdk {
    $tmp = Join-Path $env:TEMP ('wv2_{0}.nupkg' -f [guid]::NewGuid().ToString('N'))
    try {
        $idx = Invoke-RestMethod $script:WebView2IndexUrl -TimeoutSec 20 -Headers @{ 'User-Agent' = 'CybtekDownloader' }
        $ver = ($idx.versions | Where-Object { $_ -match '^1\.0\.' -and $_ -notmatch '-' })[-1]
        if (-not $ver) { throw 'No WebView2 SDK version was found on NuGet.' }
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'CybtekDownloader')
        $wc.DownloadFile("https://api.nuget.org/v3-flatcontainer/microsoft.web.webview2/$ver/microsoft.web.webview2.$ver.nupkg", $tmp)
        New-Item -ItemType Directory -Force -Path $script:WebView2Dir | Out-Null
        $map = @{
            'lib/net462/Microsoft.Web.WebView2.Core.dll'     = 'Microsoft.Web.WebView2.Core.dll'
            'lib/net462/Microsoft.Web.WebView2.WinForms.dll' = 'Microsoft.Web.WebView2.WinForms.dll'
            "runtimes/win-$($script:WebView2Arch)/native/WebView2Loader.dll" = 'WebView2Loader.dll'
        }
        $zip = [IO.Compression.ZipFile]::OpenRead($tmp)
        try {
            foreach ($entryName in $map.Keys) {
                $entry = $zip.Entries | Where-Object { $_.FullName -eq $entryName } | Select-Object -First 1
                if ($entry) { [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, (Join-Path $script:WebView2Dir $map[$entryName]), $true) }
            }
        } finally {
            $zip.Dispose()
        }
        Write-Activity "WebView2 SDK $ver installed to $($script:WebView2Dir)"
        return [bool](Resolve-WebView2)
    } catch {
        Write-Activity "WebView2 SDK install failed: $($_.Exception.Message)"
        [void](Show-Message "Could not download the browser component (WebView2):`n$($_.Exception.Message)" 'OK' 'Error')
        return $false
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Downloads and runs Microsoft's evergreen WebView2 runtime installer (a per-user install, no admin).
function Install-WebView2Runtime {
    $tmp = Join-Path $env:TEMP ('MicrosoftEdgeWebview2Setup_{0}.exe' -f [guid]::NewGuid().ToString('N'))
    try {
        $wc = New-Object System.Net.WebClient
        $wc.Headers.Add('User-Agent', 'CybtekDownloader')
        $wc.DownloadFile($script:WebView2RuntimeUrl, $tmp)
        Start-Process -FilePath $tmp -ArgumentList '/silent', '/install' -Wait
        return [bool](Test-WebView2Runtime)
    } catch {
        Write-Activity "WebView2 runtime install failed: $($_.Exception.Message)"
        return $false
    } finally {
        Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue
    }
}

# Makes sure both the WebView2 runtime and our SDK are present, installing them (with the user's OK)
# if needed. Returns the SDK folder, or $null if it is not available. Addons call this via $App.EnsureWebView2.
function Ensure-WebView2 {
    if ($script:IsBusy) {
        [void](Show-Message 'Please wait for the current download to finish first.' 'OK' 'Warning')
        return $null
    }
    $haveSdk = [bool](Resolve-WebView2)
    $haveRuntime = [bool](Test-WebView2Runtime)
    if ($haveSdk -and $haveRuntime) { return $script:WebView2Dir }

    $need = @()
    if (-not $haveRuntime) { $need += 'the Microsoft WebView2 runtime' }
    if (-not $haveSdk) { $need += 'a browser component (about 10 MB)' }
    $msg = "Signing in uses a built-in browser (Microsoft WebView2).`n`nThis needs to download $($need -join ' and '). Download and set it up now?"
    if ((Show-Message $msg 'YesNo' 'Question') -ne 'Yes') { return $null }

    $form.Cursor = 'WaitCursor'
    try {
        if (-not $haveRuntime) {
            Set-Status 'Installing the WebView2 runtime...'; $form.Refresh()
            Write-Activity 'Installing the WebView2 runtime from Microsoft...'
            if (-not (Install-WebView2Runtime)) {
                [void](Show-Message "The WebView2 runtime could not be installed automatically.`n`nYou can install it by hand from:`nhttps://developer.microsoft.com/microsoft-edge/webview2/" 'OK' 'Warning')
                return $null
            }
        }
        if (-not (Resolve-WebView2)) {
            Set-Status 'Downloading the browser component...'; $form.Refresh()
            if (-not (Install-WebView2Sdk)) { return $null }
        }
    } finally {
        $form.Cursor = 'Default'
        Set-Status 'Ready.'
    }
    Resolve-WebView2
}

# ---------------------------------------------------------------------------
# Addons
#
# An addon is a .ps1 file in the addons folder that returns a hashtable:
#   @{ Name = '...'; Version = '...'; Author = '...'; Description = '...'
#      OnLoad             = { param($App, $Self) }  # once, when the app starts or the addon is installed;
#                                                   # $Self.File / $Self.Folder say where the addon lives
#      OnDownloadStarting = { param($Info) }        # may return extra yt-dlp arguments as a string
#      OnDownloadComplete = { param($Info) }        # $Info.Success, $Info.ExitCode, $Info.Folder, ...
#      MenuAction         = { param($App) }         # runs when the addon is clicked on the Addons menu
#      MenuText           = '...'                   # text for the addon on the Addons menu (default: name and version)
#      BuildMenu          = { param($App, $Menu) }  # gives the addon a pop-out submenu: fill $Menu.DropDownItems
#                                                   # each time it opens (MenuAction is then not used)
#      TopMenuText        = '...'                   # adds a top-level menu to the menu bar (after Addons) while installed
#      TopMenuBuild       = { param($App, $Menu) }  # fills that top-level menu's dropdown each time it opens
#   }
# See Help > Help Documents for the details.
# ---------------------------------------------------------------------------

function Import-AddonFile([string]$Path) {
    try {
        $def = @(& $Path) | Where-Object { $_ -is [hashtable] } | Select-Object -Last 1
        if (-not $def) { throw 'The file does not return an addon definition (a hashtable with a Name).' }
        $addon = [pscustomobject]@{
            Name        = if ($def.Name) { [string]$def.Name } else { [IO.Path]::GetFileNameWithoutExtension($Path) }
            Version     = [string]$def.Version
            Author      = [string]$def.Author
            Description = [string]$def.Description
            File        = $Path
            Def         = $def
        }
        $self = [pscustomobject]@{ Name = $addon.Name; File = $Path; Folder = (Split-Path -Parent $Path) }
        if ($def.OnLoad -is [scriptblock]) { $null = & $def.OnLoad $script:AddonApi $self }
        Write-Activity "Addon loaded: $($addon.Name) $($addon.Version)"
        return $addon
    } catch {
        $script:LastAddonError = $_.Exception.Message
        Write-Activity "Addon $([IO.Path]::GetFileName($Path)) failed to load: $($_.Exception.Message)"
        return $null
    }
}

# Copies any .ps1 in $From into $To that isn't already there (used to carry addons between folders).
function Copy-MissingAddons([string]$From, [string]$To) {
    if (-not (Test-Path -LiteralPath $From)) { return }
    foreach ($file in (Get-ChildItem -LiteralPath $From -Filter '*.ps1' -File -ErrorAction SilentlyContinue)) {
        $dest = Join-Path $To $file.Name
        if (Test-Path -LiteralPath $dest) { continue }
        try {
            Copy-Item -LiteralPath $file.FullName -Destination $dest -Force
            Write-Activity "Addon added to the Addons folder: $($file.Name)"
        } catch { }
    }
}

# Works out the addon directory and creates it. It is the Addons folder next to the script when that can
# be written, otherwise the app data folder. Addons from the other location are carried across once, so
# nothing installed by an earlier version (or shipped read-only next to the script) is lost.
function Initialize-AddonDir {
    $appdata = Join-Path $script:AppDataDir 'addons'
    $scriptDir = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'Addons' } else { $null }
    $usable = $null
    if ($scriptDir) {
        try {
            New-Item -ItemType Directory -Force -Path $scriptDir -ErrorAction Stop | Out-Null
            $probe = Join-Path $scriptDir ('.write_{0}.tmp' -f [guid]::NewGuid().ToString('N'))
            [IO.File]::WriteAllText($probe, 'x'); Remove-Item -LiteralPath $probe -Force
            $usable = $scriptDir
        } catch { $usable = $null }
    }
    if ($usable) {
        $script:AddonDir = $usable
        Copy-MissingAddons -From $appdata -To $usable          # bring in addons an earlier version installed
    } else {
        $script:AddonDir = $appdata
        New-Item -ItemType Directory -Force -Path $appdata | Out-Null
        if ($scriptDir) { Copy-MissingAddons -From $scriptDir -To $appdata }   # load read-only bundled addons
    }
}

function Import-Addons {
    $script:Addons.Clear()
    Initialize-AddonDir
    if (Test-Path -LiteralPath $script:AddonDir) {
        foreach ($file in (Get-ChildItem -LiteralPath $script:AddonDir -Filter '*.ps1' -File | Sort-Object Name)) {
            $addon = Import-AddonFile $file.FullName
            if ($addon) { $script:Addons.Add($addon) }
        }
    }
    Update-AddonsMenu
}

# Calls one hook on every addon that has it and returns what the hooks returned.
function Invoke-AddonHook([string]$Hook, $Argument) {
    $results = @()
    foreach ($a in $script:Addons.ToArray()) {
        $sb = $a.Def[$Hook]
        if ($sb -isnot [scriptblock]) { continue }
        try {
            $results += @(& $sb $Argument)
        } catch {
            Write-Activity "Addon '$($a.Name)' failed in ${Hook}: $($_.Exception.Message)"
        }
    }
    $results
}

function Update-AddonsMenu {
    $miAddons.DropDownItems.Clear()
    if ($script:Addons.Count) {
        foreach ($a in $script:Addons) {
            $text = if ($a.Def.MenuText) { [string]$a.Def.MenuText } elseif ($a.Version) { "$($a.Name)  ($($a.Version))" } else { $a.Name }
            $mi = New-Object System.Windows.Forms.ToolStripMenuItem $text
            $mi.ToolTipText = $a.Description
            $mi.Tag = $a
            if ($a.Def.BuildMenu -is [scriptblock]) {
                # A placeholder makes the pop-out arrow show; the addon fills the submenu as it opens
                [void]$mi.DropDownItems.Add('...')
                $mi.add_DropDownOpening({
                    $this.DropDownItems.Clear()
                    try { $null = & $this.Tag.Def.BuildMenu $script:AddonApi $this }
                    catch { Write-Activity "Addon '$($this.Tag.Name)' failed to build its menu: $($_.Exception.Message)" }
                })
            } else {
                $mi.add_Click({ Invoke-AddonMenu $this.Tag })
            }
            [void]$miAddons.DropDownItems.Add($mi)
        }
    } else {
        $none = New-Object System.Windows.Forms.ToolStripMenuItem '(No addons installed)'
        $none.Enabled = $false
        [void]$miAddons.DropDownItems.Add($none)
    }
    [void]$miAddons.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
    [void]$miAddons.DropDownItems.Add($miInstallAddon)
    [void]$miAddons.DropDownItems.Add($miUninstallAddon)
    $miUninstallAddon.Enabled = $script:Addons.Count -gt 0
    Update-AddonTopMenus
}

# Top-level menus that addons add to the menu bar (via TopMenuText + TopMenuBuild), placed just after
# the Addons menu. Rebuilt whenever the installed addons change, so a menu appears only while its addon
# is installed.
$script:AddonTopMenus = New-Object System.Collections.Generic.List[object]
function Update-AddonTopMenus {
    foreach ($mi in $script:AddonTopMenus) { if ($menu.Items.Contains($mi)) { [void]$menu.Items.Remove($mi) } }
    $script:AddonTopMenus.Clear()
    $base = $menu.Items.IndexOf($miAddons) + 1
    $offset = 0
    foreach ($a in $script:Addons) {
        if (-not $a.Def.TopMenuText) { continue }
        $mi = New-Object System.Windows.Forms.ToolStripMenuItem ([string]$a.Def.TopMenuText)
        $mi.ToolTipText = $a.Description
        $mi.Tag = $a
        if ($a.Def.TopMenuBuild -is [scriptblock]) {
            [void]$mi.DropDownItems.Add('...')
            $mi.add_DropDownOpening({
                $this.DropDownItems.Clear()
                try { $null = & $this.Tag.Def.TopMenuBuild $script:AddonApi $this }
                catch { Write-Activity "Addon '$($this.Tag.Name)' failed to build its menu: $($_.Exception.Message)" }
            })
        } elseif ($a.Def.TopMenuAction -is [scriptblock]) {
            $mi.add_Click({ try { $null = & $this.Tag.Def.TopMenuAction $script:AddonApi } catch { Write-Activity "Addon '$($this.Tag.Name)' failed: $($_.Exception.Message)" } })
        }
        $menu.Items.Insert($base + $offset, $mi)
        $offset++
        $script:AddonTopMenus.Add($mi)
    }
}

function Invoke-AddonMenu($Addon) {
    if ($Addon.Def.MenuAction -is [scriptblock]) {
        try { $null = & $Addon.Def.MenuAction $script:AddonApi }
        catch { Write-Activity "Addon '$($Addon.Name)' failed: $($_.Exception.Message)" }
        return
    }
    $lines = @($Addon.Name)
    if ($Addon.Version) { $lines += "Version: $($Addon.Version)" }
    if ($Addon.Author) { $lines += "Author: $($Addon.Author)" }
    if ($Addon.Description) { $lines += '', $Addon.Description }
    $lines += '', "File: $($Addon.File)"
    [void](Show-Message ($lines -join "`n"))
}

function Install-Addon {
    $d = New-Object System.Windows.Forms.OpenFileDialog
    $d.Title = 'Choose an addon to install'
    $d.Filter = 'PowerShell addon (*.ps1)|*.ps1'
    $ok = $d.ShowDialog($form) -eq 'OK'
    $source = $d.FileName
    $d.Dispose()
    if (-not $ok) { return }

    $warning = "Addons are PowerShell scripts. They run with your permissions and can do anything you can do on this computer.`n`n" +
               "Only install addons from people you trust.`n`nInstall $([IO.Path]::GetFileName($source))?"
    if ((Show-Message $warning 'YesNo' 'Warning') -ne 'Yes') { return }

    New-Item -ItemType Directory -Force -Path $script:AddonDir | Out-Null
    $dest = Join-Path $script:AddonDir ([IO.Path]::GetFileName($source))
    $existing = $script:Addons | Where-Object { $_.File -eq $dest } | Select-Object -First 1
    $sameFile = [IO.Path]::GetFullPath($source) -eq [IO.Path]::GetFullPath($dest)
    if ((Test-Path -LiteralPath $dest) -and -not $sameFile) {
        if ((Show-Message "An addon with this file name is already installed. Replace it?" 'YesNo' 'Question') -ne 'Yes') { return }
    }
    # Copy the chosen addon into the addon folder (unless it is already that exact file)
    if (-not $sameFile) {
        try {
            Copy-Item -LiteralPath $source -Destination $dest -Force
        } catch {
            [void](Show-Message "Could not copy the addon:`n$($_.Exception.Message)" 'OK' 'Error')
            return
        }
    }

    $addon = Import-AddonFile $dest
    if (-not $addon) {
        Remove-Item -LiteralPath $dest -Force -ErrorAction SilentlyContinue
        [void](Show-Message "The addon could not be loaded, so it was not installed.`n`n$($script:LastAddonError)" 'OK' 'Error')
        return
    }
    if ($existing) { [void]$script:Addons.Remove($existing) }
    $script:Addons.Add($addon)
    Update-AddonsMenu
    Write-Activity "Addon installed: $($addon.Name)"
    [void](Show-Message "Installed the addon '$($addon.Name)'.")
}

function Show-UninstallAddonDialog {
    if (-not $script:Addons.Count) { return }
    $dlg = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Uninstall Addon'; ClientSize = (Sz 400 280); StartPosition = 'CenterParent'; Font = $form.Font
        FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; ShowInTaskbar = $false
    }
    [void](New-Label $dlg 'Choose the addon to uninstall:' 12 12)
    $list = New-Object System.Windows.Forms.ListBox -Property @{ Location = (Pt 12 34); Size = (Sz 376 190) }
    foreach ($a in $script:Addons) { [void]$list.Items.Add($(if ($a.Version) { "$($a.Name)  ($($a.Version))" } else { $a.Name })) }
    $list.SelectedIndex = 0
    $btnOk = New-Object System.Windows.Forms.Button -Property @{ Text = 'Uninstall'; Location = (Pt 218 240); Width = 80; DialogResult = 'OK' }
    $btnNo = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (Pt 308 240); Width = 80; DialogResult = 'Cancel' }
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnNo
    $dlg.Controls.AddRange(@($list, $btnOk, $btnNo))
    Set-DarkTheme $dlg
    if ($script:AppIcon) { $dlg.Icon = $script:AppIcon }
    $result = $dlg.ShowDialog($form)
    $index = $list.SelectedIndex
    $dlg.Dispose()
    if ($result -ne 'OK' -or $index -lt 0) { return }

    $addon = $script:Addons[$index]
    if ((Show-Message "Uninstall the addon '$($addon.Name)'?`n`nIts file will be moved to the Recycle Bin." 'YesNo' 'Question') -ne 'Yes') { return }
    try {
        if (Test-Path -LiteralPath $addon.File) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($addon.File, 'OnlyErrorDialogs', 'SendToRecycleBin')
        }
    } catch {
        [void](Show-Message "Could not remove the addon file:`n$($_.Exception.Message)" 'OK' 'Error')
        return
    }
    [void]$script:Addons.Remove($addon)
    Update-AddonsMenu
    Write-Activity "Addon uninstalled: $($addon.Name)"
    [void](Show-Message "Uninstalled '$($addon.Name)'. Anything it changed while running stays until you restart the app.")
}

# ---------------------------------------------------------------------------
# yt-dlp command line
# ---------------------------------------------------------------------------

function Get-DownloadArguments([string]$Url, [string]$Mode, [string]$PrintFile, [string[]]$AddonArgs) {
    $s = $script:Settings
    $a = New-Object System.Collections.Generic.List[string]
    $a.Add('--newline')
    $a.Add('--no-colors')
    $a.Add('--encoding utf-8')
    $a.Add('--no-mtime')
    if ($s.DownloadPlaylists) { $a.Add('--yes-playlist') } else { $a.Add('--no-playlist') }

    $ffmpeg = Resolve-Ffmpeg
    if ($ffmpeg) { $a.Add('--ffmpeg-location ' + (ConvertTo-Arg $ffmpeg)) }
    # Deno runs YouTube's JavaScript; point yt-dlp at our copy, which isn't on the PATH
    $deno = Resolve-Deno
    if ($deno) { $a.Add('--js-runtimes ' + (ConvertTo-Arg "deno:$deno")) }

    # Network and download behaviour
    if ("$($s.SpeedLimit)".Trim()) { $a.Add('-r ' + (ConvertTo-Arg "$($s.SpeedLimit)".Trim())) }
    if ([int]$s.Fragments -gt 1) { $a.Add('-N ' + [int]$s.Fragments) }
    $a.Add('-R ' + [int]$s.Retries)
    if ("$($s.Proxy)".Trim()) { $a.Add('--proxy ' + (ConvertTo-Arg "$($s.Proxy)".Trim())) }
    if ($s.CookieSource -eq 'file') {
        if ($s.CookieFile) { $a.Add('--cookies ' + (ConvertTo-Arg $s.CookieFile)) }
    } elseif ($s.CookieSource) {
        $a.Add('--cookies-from-browser ' + $s.CookieSource)
    }
    if ($s.UseDownloadHistory) {
        # Separate histories, so downloading the audio of a video you already have still works
        $a.Add('--download-archive ' + (ConvertTo-Arg (Join-Path $script:AppDataDir "download-history-$($Mode.ToLower()).txt")))
    }
    if ($s.OverwriteFiles)     { $a.Add('--force-overwrites') }
    if ($s.RestrictFilenames)  { $a.Add('--restrict-filenames') }
    if ($s.SaveThumbnailImage) { $a.Add('--write-thumbnail'); $a.Add('--convert-thumbnails jpg') }
    if ($s.SaveDescription)    { $a.Add('--write-description') }

    if ($Mode -eq 'Audio') {
        $dir = $s.AudioDir
        $template = $s.AudioTemplate
        $split = $s.AudioSplitChapters
        $format = (Find-Option $script:AudioFormatOptions $s.AudioFormat).Value
        $a.Add('-x')
        $a.Add('--audio-format ' + $format)
        if ($format -notin @('flac', 'wav')) { $a.Add('--audio-quality ' + $s.AudioQuality) }
        # WAV files can't hold cover art or tags
        if ($format -ne 'wav') {
            if ($s.AudioEmbedThumbnail) { $a.Add('--embed-thumbnail') }
            if ($s.AudioEmbedMetadata)  { $a.Add('--embed-metadata') }
        }
        if ($s.AudioSponsorBlock) { $a.Add('--sponsorblock-remove "sponsor,selfpromo,interaction,music_offtopic"') }
    } else {
        $dir = $s.VideoDir
        $template = $s.VideoTemplate
        $split = $s.VideoSplitChapters
        $container = (Find-Option $script:ContainerOptions $s.VideoContainer).Value
        # Sorting instead of filtering: "res:720" picks the largest size up to 720p, or the
        # smallest one there is when a site has nothing that small.
        $a.Add('-f "bv*+ba/b"')
        $sort = @()
        if ($s.VideoPreferH264) { $sort += 'vcodec:h264' }
        if ($s.VideoMaxHeight -and $s.VideoMaxHeight -ne 'Best') { $sort += "res:$($s.VideoMaxHeight)" }
        if ($s.VideoMaxFps -and $s.VideoMaxFps -ne 'Any') { $sort += "fps:$($s.VideoMaxFps)" }
        if ($container -eq 'mp4') { $sort += 'ext:mp4:m4a' }
        if ($sort) { $a.Add('-S ' + (ConvertTo-Arg ($sort -join ','))) }
        $a.Add('--merge-output-format ' + $container)
        $a.Add('--remux-video ' + $container)
        if ($s.VideoEmbedThumbnail) { $a.Add('--embed-thumbnail') }
        if ($s.VideoEmbedMetadata)  { $a.Add('--embed-metadata') }
        if ($s.VideoEmbedChapters)  { $a.Add('--embed-chapters') }
        if ($s.VideoEmbedSubs) {
            $a.Add('--write-subs')
            if ($s.VideoAutoSubs) { $a.Add('--write-auto-subs') }
            $a.Add('--embed-subs')
            $a.Add('--sub-langs ' + (ConvertTo-Arg $s.VideoSubLangs))
        }
        if ($s.VideoSponsorBlock) { $a.Add('--sponsorblock-remove "sponsor,selfpromo,interaction"') }
    }

    if (-not $template) { $template = '%(title)s.%(ext)s' }
    $a.Add('-o ' + (ConvertTo-Arg (Join-Path $dir $template)))

    if ($split) {
        # One file per chapter, in a folder named after the video
        $a.Add('--split-chapters')
        $a.Add('-o ' + (ConvertTo-Arg ('chapter:' + (Join-Path $dir '%(title)s\%(section_number)02d - %(section_title)s.%(ext)s'))))
        if ($PrintFile) {
            # Records the full-length file's final path so it can be removed afterwards
            $a.Add('--print-to-file after_move:filepath ' + (ConvertTo-Arg $PrintFile))
        }
    }

    if ("$($s.ExtraArgs)".Trim()) { $a.Add("$($s.ExtraArgs)".Trim()) }
    foreach ($extra in $AddonArgs) { if ("$extra".Trim()) { $a.Add("$extra".Trim()) } }

    $a.Add('--')
    $a.Add((ConvertTo-Arg $Url))
    $a -join ' '
}

# ---------------------------------------------------------------------------
# Downloads (yt-dlp)
# ---------------------------------------------------------------------------

function Set-Busy([bool]$Busy, [bool]$CanCancel = $false) {
    $script:IsBusy = $Busy
    $txtUrl.Enabled = -not $Busy
    $btnPaste.Enabled = -not $Busy
    $btnClear.Enabled = -not $Busy
    $btnCancel.Visible = $Busy -and $CanCancel
    $progress.Visible = $Busy
    foreach ($mi in @($miInstallDeps, $miUpdateDeps, $miArchiveDeps, $miCheckUpdates)) { $mi.Enabled = -not $Busy }
    if ($Busy) {
        $lnkOpenFolder.Visible = $false
        $progress.Style = 'Continuous'
        $progress.Value = 0
    }
    Update-ButtonState
}

function Update-ButtonState {
    $ok = (-not $script:IsBusy) -and (Test-DownloadUrl $txtUrl.Text)
    $btnVideo.Enabled = $ok -and -not $script:CurrentSource.AudioOnly
    $btnAudio.Enabled = $ok
}

function Update-DownloadButtonText {
    $btnVideo.Text = 'Download Video ({0})' -f (Find-Option $script:ContainerOptions $script:Settings.VideoContainer).Value.ToUpper()
    $btnAudio.Text = 'Download Audio ({0})' -f (Find-Option $script:AudioFormatOptions $script:Settings.AudioFormat).Ext
}

function Start-YtDlpDownload([string]$Mode) {
    if ($script:IsBusy) { return }
    if (-not (Test-DownloadUrl $txtUrl.Text)) {
        [void](Show-Message 'Please enter a valid video URL.' 'OK' 'Warning')
        return
    }

    $ytdlp = Resolve-YtDlp
    $ffmpeg = Resolve-Ffmpeg
    if (-not $ytdlp -or -not $ffmpeg) {
        Update-VersionInfo
        $missing = Get-DependencyActions -MissingOnly
        if (-not $ytdlp) {
            if (Request-DependencyActions $missing) { Start-DependencyJobs ($missing | ForEach-Object { $_.Name }) }
            return
        }
        $msg = "ffmpeg is not installed. It is needed to convert audio and to merge video and audio into one file.`n`n" +
               "Yes = install ffmpeg now`nNo = try without it`nCancel = do nothing"
        $answer = Show-Message $msg 'YesNoCancel' 'Warning'
        if ($answer -eq 'Yes') { Start-DependencyJobs @('ffmpeg'); return }
        if ($answer -eq 'Cancel') { return }
    }
    if (-not (Resolve-Deno) -and (Test-SourceUrl $txtUrl.Text (Get-Source 'YouTube'))) {
        $msg = "Deno is not installed. yt-dlp needs this JavaScript runtime to download from YouTube reliably.`n`n" +
               "Yes = install Deno now (about 40 MB)`nNo = try without it`nCancel = do nothing"
        $answer = Show-Message $msg 'YesNoCancel' 'Warning'
        if ($answer -eq 'Yes') { Start-DependencyJobs @('Deno'); return }
        if ($answer -eq 'Cancel') { return }
    }

    $url = Get-NormalizedUrl $txtUrl.Text
    $dir = if ($Mode -eq 'Audio') { $script:Settings.AudioDir } else { $script:Settings.VideoDir }
    try {
        New-Item -ItemType Directory -Force -Path $dir -ErrorAction Stop | Out-Null
    } catch {
        [void](Show-Message "Cannot create the download folder:`n$dir`n`n$($_.Exception.Message)" 'OK' 'Error')
        return
    }

    $split = if ($Mode -eq 'Audio') { $script:Settings.AudioSplitChapters } else { $script:Settings.VideoSplitChapters }
    $keepFull = if ($Mode -eq 'Audio') { $script:Settings.AudioKeepFullFile } else { $script:Settings.VideoKeepFullFile }
    $script:PrintFile = if ($split -and -not $keepFull) { Join-Path $env:TEMP ('cybtek-downloader_{0}.txt' -f [guid]::NewGuid().ToString('N')) } else { $null }

    $script:CurrentInfo = [pscustomobject]@{
        Url = $url; Mode = $Mode; Source = $script:CurrentSource.Name; Folder = $dir; Success = $false; ExitCode = $null
    }
    $addonArgs = @(Invoke-AddonHook 'OnDownloadStarting' $script:CurrentInfo | Where-Object { $_ -is [string] })

    $argLine = Get-DownloadArguments -Url $url -Mode $Mode -PrintFile $script:PrintFile -AddonArgs $addonArgs
    Write-Activity "Starting $($Mode.ToLower()) download ($($script:CurrentSource.Name)): $url"
    Write-Activity "Command: `"$ytdlp`" $argLine"

    $script:CurrentMode = $Mode
    $script:CurrentDir = $dir
    $script:Cancelled = $false
    $script:LastError = ''
    $script:ChapterFiles = 0
    $script:Runner = New-Object YtProcessRunner
    try {
        $script:Runner.Start($ytdlp, $argLine)
    } catch {
        Write-Activity "Could not start yt-dlp: $($_.Exception.Message)"
        [void](Show-Message "Could not start yt-dlp:`n$($_.Exception.Message)" 'OK' 'Error')
        $script:Runner = $null
        return
    }

    Set-Busy $true $true
    Set-Status "Starting $($Mode.ToLower()) download..."
    $pollTimer.Start()
}

function Invoke-OutputLine([string]$Line) {
    if ([string]::IsNullOrWhiteSpace($Line)) { return }

    $m = [regex]::Match($Line, '^\[download\]\s+(?<pct>\d+(?:\.\d+)?)%\s*(?<rest>.*)$')
    if ($m.Success) {
        $pct = [double]::Parse($m.Groups['pct'].Value, [Globalization.CultureInfo]::InvariantCulture)
        $progress.Style = 'Continuous'
        $progress.Value = [int][Math]::Min(100, [Math]::Max(0, $pct))
        Set-Status ('Downloading {0}: {1}%  {2}' -f $script:CurrentMode.ToLower(), $m.Groups['pct'].Value, ($m.Groups['rest'].Value -replace '\s+', ' '))
        if ($pct -ge 100) { Write-Activity $Line }
        return
    }

    Write-Activity $Line
    if ($Line -match '^\[download\] Destination: (.+)$') {
        Set-Status ('Downloading: ' + [IO.Path]::GetFileName($Matches[1]))
    } elseif ($Line -match '^\[SplitChapters\] Chapter (\d+);') {
        $script:ChapterFiles++
        $progress.Style = 'Marquee'
        Set-Status "Saving chapter $([int]$Matches[1])..."
    } elseif ($Line -match '^\[(Merger|ExtractAudio|EmbedThumbnail|Metadata|FixupM3u8|FixupM4a|VideoRemuxer|EmbedSubtitle|ThumbnailsConvertor|SplitChapters|ModifyChapters|SponsorBlock)\]') {
        $progress.Style = 'Marquee'
        Set-Status "Processing ($($Matches[1]))..."
    } elseif ($Line -match 'has already been (downloaded|recorded in the archive)') {
        Set-Status 'This has already been downloaded.'
    } elseif ($Line -match '^ERROR:') {
        $script:LastError = $Line
    }
}

# After a chapter split, moves the full-length file(s) to the Recycle Bin when the
# user chose not to keep them. Videos without chapters keep their full file.
function Remove-FullLengthFiles {
    if (-not $script:PrintFile) { return }
    try {
        if (-not (Test-Path -LiteralPath $script:PrintFile)) { return }
        if ($script:ChapterFiles -eq 0) {
            Write-Activity 'No chapters were found, so the full-length file was kept.'
            return
        }
        foreach ($path in (Get-Content -LiteralPath $script:PrintFile -Encoding UTF8)) {
            $path = $path.Trim()
            if ($path -and (Test-Path -LiteralPath $path -PathType Leaf)) {
                [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($path, 'OnlyErrorDialogs', 'SendToRecycleBin')
                Write-Activity "Moved the full-length file to the Recycle Bin: $path"
            }
        }
    } catch {
        Write-Activity "Could not remove the full-length file: $($_.Exception.Message)"
    } finally {
        Remove-Item -LiteralPath $script:PrintFile -Force -ErrorAction SilentlyContinue
        $script:PrintFile = $null
    }
}

function Complete-YtDlpDownload {
    $code = $script:Runner.ExitCode
    $progress.Style = 'Continuous'
    if ($script:Cancelled) {
        Set-Status 'Download cancelled.'
        Write-Activity 'Download cancelled by user.'
    } elseif ($code -eq 0) {
        Remove-FullLengthFiles
        $progress.Value = 100
        $chapters = if ($script:ChapterFiles) { " ($($script:ChapterFiles) chapter files)" } else { '' }
        Set-Status "Done$chapters. Saved to $($script:CurrentDir)"
        Write-Activity "Finished$chapters. Saved to $($script:CurrentDir)"
        $lnkOpenFolder.Tag = $script:CurrentDir
        $lnkOpenFolder.Visible = $true
        [System.Media.SystemSounds]::Asterisk.Play()
    } else {
        Set-Status "Download failed (exit code $code). See File > Activity for details."
        Write-Activity "yt-dlp exited with code $code."
        $cookieProblem = Get-CookieProblem $script:LastError
        if (-not $cookieProblem) {
            $detail = if ($script:LastError) { "`n`n$($script:LastError)" } else { '' }
            [void](Show-Message "The download failed.$detail" 'OK' 'Error')
        }
    }
    if ($script:PrintFile) {
        Remove-Item -LiteralPath $script:PrintFile -Force -ErrorAction SilentlyContinue
        $script:PrintFile = $null
    }
    Set-Busy $false

    if ($script:CurrentInfo) {
        $script:CurrentInfo.ExitCode = $code
        $script:CurrentInfo.Success = (-not $script:Cancelled) -and $code -eq 0
        $null = Invoke-AddonHook 'OnDownloadComplete' $script:CurrentInfo
    }

    # Offered last, because choosing a browser there starts the download again
    if ($cookieProblem) { Show-CookieHelp $cookieProblem $script:CurrentMode }
}

# ---------------------------------------------------------------------------
# Login cookies: help when a site wants you signed in
# ---------------------------------------------------------------------------

# Browsers yt-dlp can read login cookies from: where each keeps its profile, and its process name
$script:CookieBrowsers = @(
    [pscustomobject]@{ Value = 'firefox'; Name = 'Firefox';        Profile = "$env:APPDATA\Mozilla\Firefox\Profiles";            Process = 'firefox' }
    [pscustomobject]@{ Value = 'edge';    Name = 'Microsoft Edge'; Profile = "$env:LOCALAPPDATA\Microsoft\Edge\User Data";         Process = 'msedge' }
    [pscustomobject]@{ Value = 'chrome';  Name = 'Google Chrome';  Profile = "$env:LOCALAPPDATA\Google\Chrome\User Data";          Process = 'chrome' }
    [pscustomobject]@{ Value = 'brave';   Name = 'Brave';          Profile = "$env:LOCALAPPDATA\BraveSoftware\Brave-Browser\User Data"; Process = 'brave' }
    [pscustomobject]@{ Value = 'opera';   Name = 'Opera';          Profile = "$env:APPDATA\Opera Software\Opera Stable";         Process = 'opera' }
    [pscustomobject]@{ Value = 'vivaldi'; Name = 'Vivaldi';        Profile = "$env:LOCALAPPDATA\Vivaldi\User Data";              Process = 'vivaldi' }
)
$script:CookieHelpUrl = 'https://github.com/yt-dlp/yt-dlp/wiki/FAQ#how-do-i-pass-cookies-to-yt-dlp'

# 'signin' when the site wants a signed-in user, 'cookies' when the browser's cookies could not be read
function Get-CookieProblem([string]$ErrorLine) {
    if ($ErrorLine -match '(?i)sign in to confirm|confirm your age|use --cookies|login required|members.only|private video') { return 'signin' }
    if ($script:Settings.CookieSource -and $ErrorLine -match '(?i)cookie') { return 'cookies' }
    $null
}

function Get-CookieBrowserName([string]$Value) {
    $b = $script:CookieBrowsers | Where-Object { $_.Value -eq $Value } | Select-Object -First 1
    if ($b) { $b.Name } elseif ($Value -eq 'file') { 'your cookies.txt file' } else { $Value }
}

# yt-dlp can't read a browser's cookies while it is running. Returns $false if the user gives up.
function Wait-CookieBrowserClosed([string]$Value) {
    $browser = $script:CookieBrowsers | Where-Object { $_.Value -eq $Value } | Select-Object -First 1
    while ($browser -and (Get-Process -Name $browser.Process -ErrorAction SilentlyContinue)) {
        $msg = "$($browser.Name) is still running, so its login can't be read.`n`n" +
               "Close every $($browser.Name) window. If it keeps running in the background, right-click its icon in the " +
               "system tray and choose Exit (or turn off 'Startup boost' / 'Continue running background apps' in its settings).`n`n" +
               "Click Retry when it is closed."
        if ((Show-Message $msg 'RetryCancel' 'Warning') -ne 'Retry') { return $false }
    }
    $true
}

# Tells the user what is going on and what to do: sign in to the site in their browser, then select
# that browser in Settings > Sources. "Open Settings" goes straight to that tab and offers to retry.
function Show-CookieHelp([string]$Problem, [string]$Mode) {
    $current = $script:Settings.CookieSource
    $browserName = Get-CookieBrowserName $current
    $site = if ($script:CurrentSource -and $script:CurrentSource.Hosts) { $script:CurrentSource.Name } else { 'This site' }
    $settingsStep = 'Click Open Settings below (or File > Settings), go to the Sources tab, and under "Use login cookies from" select'

    if ($Problem -eq 'cookies') {
        $heading = "Your browser's login couldn't be read"
        $what = "Cybtek Downloader is set to use your login from $browserName, but yt-dlp couldn't read it. " +
                "This usually means the browser is still open."
        $steps = @(
            "Close every $browserName window. If it keeps running in the background, right-click its icon in the system tray and choose Exit.",
            'Download again.',
            "If it still fails: $settingsStep a different browser, or a cookies.txt file (Help explains how to make one).")
    } elseif ($current) {
        $heading = "$site still wants you to sign in"
        $what = "$site is still blocking this download, even with your login from $browserName."
        $steps = @(
            "Open $browserName and make sure you are signed in to $site.",
            "Close $browserName completely (also check the system tray).",
            'Download again.',
            "If it still fails: $settingsStep a different browser, or a cookies.txt file (Help explains how to make one).")
    } else {
        $heading = "$site wants you to sign in"
        $what = "$site has blocked this download until it can check that you are not a bot. Sites do this to stop automated " +
                "downloading, and it often happens after several downloads in a row. Signing in fixes it: Cybtek Downloader " +
                "can use your login from your web browser."
        $steps = @(
            "Open your web browser and sign in to $site.",
            "$settingsStep that browser. Click OK.",
            "Close the browser completely. yt-dlp can't read your login while the browser is open.",
            'Download again.')
    }

    $numbered = for ($i = 0; $i -lt $steps.Count; $i++) { "  $($i + 1).  $($steps[$i])" }
    $text = $what + "`r`n`r`nWhat to do:`r`n" + ($numbered -join "`r`n")
    $installed = @($script:CookieBrowsers | Where-Object { Test-Path -LiteralPath $_.Profile } | ForEach-Object { $_.Name })
    if ($installed) { $text += "`r`n`r`nBrowsers found on this computer: $($installed -join ', ')." }

    $dlg = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Sign-in needed'; StartPosition = 'CenterParent'; Font = $form.Font; ClientSize = (Sz 560 300)
        FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; ShowInTaskbar = $false
    }
    $lblHeading = New-Object System.Windows.Forms.Label -Property @{
        Text = $heading; Location = (Pt 18 16); AutoSize = $true; Font = (New-Object System.Drawing.Font('Segoe UI Semibold', 12))
    }
    $lblText = New-Object System.Windows.Forms.Label -Property @{
        Text = $text; Location = (Pt 18 52); AutoSize = $true; MaximumSize = (Sz 524 0)
    }
    $dlg.Controls.AddRange(@($lblHeading, $lblText))
    $buttonsTop = $lblText.Top + $lblText.GetPreferredSize((Sz 524 0)).Height + 22
    $btnSettings = New-Object System.Windows.Forms.Button -Property @{ Text = 'Open Settings'; Location = (Pt 322 $buttonsTop); Width = 120; Height = 30; DialogResult = 'Yes' }
    $btnClose    = New-Object System.Windows.Forms.Button -Property @{ Text = 'Close'; Location = (Pt 452 $buttonsTop); Width = 90; Height = 30; DialogResult = 'Cancel' }
    $btnHelp     = New-Object System.Windows.Forms.Button -Property @{ Text = 'Help'; Location = (Pt 18 $buttonsTop); Width = 80; Height = 30 }
    $btnHelp.add_Click({ Start-Process $script:CookieHelpUrl })
    $dlg.Controls.AddRange(@($btnSettings, $btnClose, $btnHelp))
    $dlg.ClientSize = Sz 560 ($buttonsTop + 46)
    $dlg.AcceptButton = $btnSettings
    $dlg.CancelButton = $btnClose
    Set-DarkTheme $dlg
    $lblHeading.ForeColor = [CyColors]::AccentLight
    if ($script:AppIcon) { $dlg.Icon = $script:AppIcon }
    $result = $dlg.ShowDialog($form)
    $dlg.Dispose()
    Write-Activity "Sign-in needed: $heading."
    if ($result -ne 'Yes') { return }

    $before = "$($script:Settings.CookieSource)|$($script:Settings.CookieFile)"
    Show-SettingsDialog 'Sources'
    $choice = $script:Settings.CookieSource
    if (-not $choice -or "$choice|$($script:Settings.CookieFile)" -eq $before) { return }

    $again = "Cybtek Downloader will now use your login from $(Get-CookieBrowserName $choice).`n`nDownload again now?"
    if ((Show-Message $again 'YesNo' 'Question') -ne 'Yes') { return }
    if (-not (Wait-CookieBrowserClosed $choice)) { return }
    Write-Activity "Login cookies: now using $(Get-CookieBrowserName $choice). Retrying the download."
    Start-YtDlpDownload $Mode
}

function Stop-YtDlpDownload {
    if ($script:Runner -and $script:Runner.IsRunning) {
        $script:Cancelled = $true
        Set-Status 'Cancelling...'
        # /T also stops the ffmpeg child processes yt-dlp may have started
        Start-Process -FilePath 'taskkill.exe' -ArgumentList @('/PID', $script:Runner.Proc.Id, '/T', '/F') -WindowStyle Hidden -Wait
    }
}

# ---------------------------------------------------------------------------
# Clipboard watcher
# ---------------------------------------------------------------------------

function Invoke-ClipboardCheck {
    if (-not $script:Settings.AutoPaste -or $script:IsBusy) { return }
    try {
        if (-not [System.Windows.Forms.Clipboard]::ContainsText()) { return }
        $text = [System.Windows.Forms.Clipboard]::GetText().Trim()
    } catch {
        return   # clipboard is locked by another app; try again next tick
    }
    if ($text -eq $script:LastClipboard) { return }
    $script:LastClipboard = $text
    if ((Test-SourceUrl $text $script:CurrentSource) -and $txtUrl.Text.Trim() -ne $text) {
        $txtUrl.Text = $text
        Set-Status "$($script:CurrentSource.Name) link pasted from the clipboard."
        Write-Activity "$($script:CurrentSource.Name) link pasted from clipboard: $text"
    }
}

# ---------------------------------------------------------------------------
# Help documents
# ---------------------------------------------------------------------------

function Show-HelpDocuments {
    $html = @'
<!doctype html>
<html lang="en"><head><meta charset="utf-8"><title>{{APP}} - Help</title>
<style>
  :root { --back: #070d1a; --panel: #0b162a; --input: #0e1e38; --border: #204a78; --accent: #00a8ff; --accent-light: #5adeff; --text: #e8f1ff; --muted: #8ca5c8; }
  body { font: 15px/1.6 "Segoe UI", sans-serif; max-width: 880px; margin: 0 auto; padding: 24px; color: var(--text); background: var(--back); }
  .banner { width: 100%; border-radius: 10px; border: 1px solid var(--border); box-shadow: 0 0 30px rgba(0, 168, 255, .25); }
  h1 { font-size: 28px; margin: 18px 0 4px; color: #fff; }
  h2 { margin-top: 38px; color: var(--accent-light); border-bottom: 1px solid var(--border); padding-bottom: 6px; }
  h3 { margin-top: 24px; color: #fff; }
  a { color: var(--accent-light); } b { color: #fff; }
  code, pre { font-family: Consolas, monospace; background: var(--input); border: 1px solid var(--border); border-radius: 4px; }
  code { padding: 1px 5px; } pre { padding: 12px; overflow-x: auto; }
  nav { background: var(--panel); border: 1px solid var(--border); border-radius: 8px; padding: 10px 14px; }
  nav a { margin-right: 14px; text-decoration: none; }
  table { border-collapse: collapse; width: 100%; } td, th { border: 1px solid var(--border); padding: 7px 10px; text-align: left; vertical-align: top; }
  th { background: var(--panel); color: var(--accent-light); }
  .muted { color: var(--muted); }
</style></head><body>
{{BANNER}}
<h1>{{APP}}</h1>
<p class="muted">Version {{VERSION}} &middot; Audio &amp; Video Downloader &middot; powered by <a href="https://github.com/yt-dlp/yt-dlp">yt-dlp</a> and ffmpeg</p>
<nav><a href="#start">Getting started</a><a href="#download">Downloading</a><a href="#sources">Sources</a><a href="#settings">Settings</a><a href="#deps">Dependencies</a><a href="#addons">Addons</a><a href="#trouble">Troubleshooting</a><a href="#files">Files</a></nav>

<h2 id="start">Getting started</h2>
<ol>
  <li>Start the app. If yt-dlp or ffmpeg is missing, it offers to install them. Say <b>Yes</b>.</li>
  <li>Pick the site you are downloading from on the <b>Source</b> menu (YouTube is the default).</li>
  <li>Copy a link from your browser. The app pastes it into the URL box for you.</li>
  <li>Click <b>Download Video</b> or <b>Download Audio</b>.</li>
</ol>

<h2 id="download">Downloading</h2>
<p>The progress bar shows how far the download is, with its speed and the time left. Video and audio are often downloaded
separately and then combined, so the bar can run twice. While ffmpeg converts, merges or splits the file, the bar moves
back and forth. Click <b>Cancel</b> to stop a download. When it finishes, click <b>Open download folder</b>.</p>
<p><b>File &gt; Activity</b> shows everything yt-dlp reported, including the exact command it ran. Use it when something goes wrong.</p>

<h2 id="sources">Sources</h2>
<p>The <b>Source</b> menu sets which site's links are pasted automatically from the clipboard. Only one source can be selected at a time.
You can still type or paste a link from any site that yt-dlp supports, whatever the source is set to. SoundCloud and Bandcamp are audio-only, so
<b>Download Video</b> is turned off for them. <b>Other site</b> works with any of the
<a href="https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md">sites yt-dlp supports</a>, but does not auto-paste.</p>
<p>In <b>Settings &gt; Sources</b> you choose whether the app starts with the source you used last or with your default source.</p>
<p>Some sites (Instagram, Facebook, private or age-restricted videos) only work when you are signed in. In <b>Settings &gt; Sources</b>, set
<b>Use login cookies from</b> to the browser you are signed in with. Firefox works best. Chrome-based browsers may need to be closed first.
If that does not work, export a <code>cookies.txt</code> file with a browser extension and choose it there.</p>

<h2 id="settings">Settings</h2>
<table>
<tr><th>Tab</th><th>What it controls</th></tr>
<tr><td>General</td><td>Download, log and archive folders, where yt-dlp, ffmpeg and Deno are, checking for updates at start-up, archiving before updates, auto-paste.</td></tr>
<tr><td>Sources</td><td>Which source the app starts with, the default source, and login cookies.</td></tr>
<tr><td>Audio</td><td>Format (MP3, M4A, Opus, OGG, FLAC, WAV), quality, cover art, tags, removing sponsor and non-music segments, file names, one file per chapter.</td></tr>
<tr><td>Video</td><td>Maximum resolution and frame rate, MP4 or MKV, H.264 preference, thumbnail, tags, chapter markers, subtitles, removing sponsor segments, file names, one file per chapter.</td></tr>
<tr><td>Downloads</td><td>Playlists, speed limit, parallel downloads, retries, proxy, download history, overwriting, plain file names, saving the thumbnail and description, and extra yt-dlp arguments.</td></tr>
</table>
<h3>File names</h3>
<p>File names use yt-dlp <a href="https://github.com/yt-dlp/yt-dlp#output-template">output templates</a>. Useful fields:
<code>%(title)s</code>, <code>%(uploader)s</code>, <code>%(upload_date)s</code>, <code>%(id)s</code>, <code>%(playlist_index)s</code>.
Use a backslash to make subfolders, for example <code>%(uploader)s\%(title)s.%(ext)s</code>.</p>
<h3>Chapters</h3>
<p>With <b>Save each chapter as a separate file</b>, a video with chapters is saved as one file per chapter in a folder named after the video
(for example <code>01 - Intro.mp3</code>). If you turn off <b>Also keep the full-length file</b>, the full file is moved to the Recycle Bin
after the chapters are saved. Videos without chapters are always kept as one file.</p>
<h3>SponsorBlock</h3>
<p>Removes sponsor messages, self-promotion and "like and subscribe" reminders from YouTube videos, using the community
<a href="https://sponsor.ajay.app/">SponsorBlock</a> database. For audio it also removes non-music parts of music videos. It has no effect on other sites.</p>
<h3>Download history</h3>
<p>With <b>Skip videos already downloaded</b> on, the app remembers what you downloaded and skips it next time. Video and audio are remembered
separately. This is handy for re-downloading a playlist to pick up only the new videos.</p>

<h2 id="deps">Dependencies</h2>
<p>The app needs three programs: <b>yt-dlp</b> does the downloading, <b>ffmpeg</b> does the converting and merging, and
<b>Deno</b> is the JavaScript runtime yt-dlp needs to download from YouTube. The line under the menu bar shows
whether they are ready: green means both are installed and up to date, orange means one or both need updating, and red means
one or both are missing. When it says to, click the line to install or update them. Hover over it to see the exact versions.</p>
<ul>
  <li><b>Help &gt; Install Dependencies</b> installs whichever is missing.</li>
  <li><b>Help &gt; Update Dependencies</b> updates whichever is out of date. Sites change often, so keep yt-dlp updated.</li>
  <li><b>Help &gt; Archive Dependencies</b> saves a zip backup of the current versions, so you can go back if an update breaks something.
      To go back, unzip the backup into the <code>bin</code> folder.</li>
  <li><b>Help &gt; Check for Updates</b> checks GitHub now.</li>
</ul>
<p>ffmpeg is published as daily builds, so it counts as out of date once your copy is more than {{FFDAYS}} days older than the newest build.</p>

<h2 id="addons">Addons</h2>
<p>Addons add features to the app. The <b>Addons</b> menu lists the installed addons. Click one to run it or see what it does.
Use <b>Install Addon</b> to add one and <b>Uninstall Addon</b> to remove one (its file goes to the Recycle Bin).</p>
<p>The addon directory is the <code>Addons</code> folder next to the script. The app creates it when it starts, and every addon in it
is loaded automatically (that is how the included addons arrive). <b>Install Addon</b> copies the file you pick into that folder, and
deleting a file from it removes that addon.</p>
<p><b>Only install addons from people you trust.</b> An addon is a PowerShell script and can do anything you can do on your computer.</p>
<h3>Writing an addon</h3>
<p>An addon is a <code>.ps1</code> file that returns a hashtable. Every entry is optional except <code>Name</code>:</p>
<pre>@{
    Name        = 'My Addon'
    Version     = '1.0'
    Author      = 'Your name'
    Description = 'What it does (shown as a tooltip on the Addons menu).'

    # Runs once when the app starts or the addon is installed.
    # $Self.Folder is the folder the addon file is in (for its own files).
    OnLoad = { param($App, $Self) &amp; $App.Log 'My Addon is ready' }

    # Runs before each download. Return a string to add yt-dlp arguments.
    OnDownloadStarting = { param($Info) if ($Info.Source -eq 'TikTok') { '--write-description' } }

    # Runs after each download.
    OnDownloadComplete = { param($Info) if ($Info.Success) { Start-Process $Info.Folder } }

    # Runs when the addon is clicked on the Addons menu.
    MenuAction = { param($App) [System.Windows.Forms.MessageBox]::Show('Hello') }

    # Optional: the text on the Addons menu, and a pop-out submenu instead of MenuAction.
    # BuildMenu runs each time the submenu opens; add ToolStripMenuItems to $Menu.DropDownItems.
    MenuText  = 'My Addon'
    BuildMenu = { param($App, $Menu) [void]$Menu.DropDownItems.Add('Hello') }

    # Optional: a top-level menu on the menu bar (after Addons), shown only while the addon is installed.
    TopMenuText  = 'My Menu'
    TopMenuBuild = { param($App, $Menu) [void]$Menu.DropDownItems.Add('Do something') }
}</pre>
<p><code>$Info</code> has <code>Url</code>, <code>Mode</code> (<code>Video</code> or <code>Audio</code>), <code>Source</code>, <code>Folder</code>,
and after the download <code>Success</code> and <code>ExitCode</code>.
<code>$App</code> has <code>Form</code> (the main window), <code>Settings</code>, and the script blocks <code>Log</code> (write to the Activity window)
and <code>SetStatus</code> (set the status line). Call them like this: <code>&amp; $App.Log 'message'</code>.
For colour schemes there is also <code>GetColors</code> (the current colours as <code>#RRGGBB</code> values, plus <code>Light</code>),
<code>SetColors</code> (switch the whole app to new colours: <code>&amp; $App.SetColors @{ Back = '#101010'; Accent = '#FF8800' }</code>)
and <code>ColorNames</code> (the names of the colours a scheme can set). <code>SaveSettings</code> saves settings changes to disk,
and <code>EnsureWebView2</code> installs the embedded browser (Microsoft WebView2) on demand and returns its folder (the Sign-In addon uses it).</p>
<p>If an addon fails, the error is written to <b>File &gt; Activity</b> and the app carries on.</p>

<h2 id="trouble">Troubleshooting</h2>
<table>
<tr><th>Problem</th><th>Try this</th></tr>
<tr><td>A download that used to work now fails</td><td>Update yt-dlp (<b>Help &gt; Update Dependencies</b>). Sites change all the time and yt-dlp keeps up.</td></tr>
<tr><td>YouTube says a JavaScript runtime is needed, or formats are missing</td><td>Make sure the line under the menu bar says the dependencies are installed: <a href="https://deno.com/">Deno</a> is one of them. Use <b>Help &gt; Install Dependencies</b> if it is missing.</td></tr>
<tr><td>"Sign in to confirm" or private/age-restricted videos</td><td>Use login cookies (<b>Settings &gt; Sources</b>).</td></tr>
<tr><td>MP3 or merging fails</td><td>Make sure the line under the menu bar says the dependencies are installed.</td></tr>
<tr><td>Nothing gets pasted automatically</td><td>Check the <b>Source</b> menu matches the site, and that auto-paste is on in <b>Settings &gt; General</b>.</td></tr>
<tr><td>Anything else</td><td>Open <b>File &gt; Activity</b>, click <b>Copy all</b>, and look at the lines starting with <code>ERROR</code>.</td></tr>
</table>

<h2 id="files">Files</h2>
<table>
<tr><td>Settings</td><td><code>{{SETTINGS}}</code></td></tr>
<tr><td>yt-dlp, ffmpeg and Deno</td><td><code>{{BIN}}</code></td></tr>
<tr><td>Addons</td><td><code>{{ADDONS}}</code></td></tr>
<tr><td>Logs</td><td><code>{{LOGS}}</code></td></tr>
<tr><td>Dependency backups</td><td><code>{{ARCHIVE}}</code></td></tr>
</table>
</body></html>
'@
    $values = [ordered]@{
        '{{APP}}'      = $script:AppName
        '{{VERSION}}'  = $script:AppVersion
        '{{FFDAYS}}'   = [string]$script:FfmpegMaxAgeDays
        '{{SETTINGS}}' = $script:SettingsFile
        '{{BIN}}'      = $script:BinDir
        '{{ADDONS}}'   = $script:AddonDir
        '{{LOGS}}'     = $script:Settings.LogDir
        '{{ARCHIVE}}'  = $script:Settings.ArchiveDir
    }
    foreach ($key in $values.Keys) { $html = $html.Replace($key, [System.Net.WebUtility]::HtmlEncode($values[$key])) }
    $banner = ''
    if ($script:SplashFile -and (Test-Path -LiteralPath $script:SplashFile)) {
        $banner = '<img class="banner" src="{0}" alt="{1}">' -f ([uri]$script:SplashFile).AbsoluteUri, [System.Net.WebUtility]::HtmlEncode($script:AppName)
    }
    $html = $html.Replace('{{BANNER}}', $banner)
    try {
        New-Item -ItemType Directory -Force -Path $script:AppDataDir | Out-Null
        [IO.File]::WriteAllText($script:HelpFile, $html, (New-Object System.Text.UTF8Encoding($false)))
        Start-Process -FilePath $script:HelpFile
    } catch {
        [void](Show-Message "Could not open the help documents:`n$($_.Exception.Message)" 'OK' 'Error')
    }
}

# ---------------------------------------------------------------------------
# Settings window
# ---------------------------------------------------------------------------

function Invoke-BrowseDialog($Info) {
    $box = $Info.Box
    if ($Info.Kind -eq 'Folder') {
        $d = New-Object System.Windows.Forms.FolderBrowserDialog
        $d.Description = "Choose the $($Info.Title.ToLower())"
        if ($box.Text -and (Test-Path -LiteralPath $box.Text -PathType Container)) { $d.SelectedPath = $box.Text }
        if ($d.ShowDialog() -eq 'OK') { $box.Text = $d.SelectedPath }
    } else {
        $d = New-Object System.Windows.Forms.OpenFileDialog
        $d.Title = "Choose $($Info.Title)"
        $d.Filter = if ($Info.Kind -eq 'Text') { 'Text files (*.txt)|*.txt|All files (*.*)|*.*' } else { 'Programs (*.exe)|*.exe|All files (*.*)|*.*' }
        if ($box.Text -and (Test-Path -LiteralPath $box.Text -PathType Leaf)) { $d.FileName = $box.Text }
        if ($d.ShowDialog() -eq 'OK') { $box.Text = $d.FileName }
    }
    $d.Dispose()
}

function New-Label($Parent, [string]$Text, [int]$X, [int]$Y, [switch]$Hint) {
    $lbl = New-Object System.Windows.Forms.Label -Property @{ Text = $Text; Location = (Pt $X $Y); AutoSize = $true }
    if ($Hint) { $lbl.Tag = 'hint'; $lbl.ForeColor = [CyColors]::Muted }
    $Parent.Controls.Add($lbl)
    $lbl
}

function New-TextBox($Parent, [string]$Text, [int]$X, [int]$Y, [int]$Width) {
    $txt = New-Object System.Windows.Forms.TextBox -Property @{ Text = $Text; Location = (Pt $X $Y); Width = $Width }
    $Parent.Controls.Add($txt)
    $txt
}

function New-PathRow($Parent, [string]$Label, [string]$Value, [int]$Y, [string]$Kind = 'Folder') {
    [void](New-Label $Parent $Label 12 ($Y + 4))
    $txt = New-TextBox $Parent $Value 130 $Y 338
    $btn = New-Object System.Windows.Forms.Button -Property @{
        Text = 'Browse...'; Location = (Pt 475 ($Y - 1)); Width = 80
        Tag = @{ Box = $txt; Kind = $Kind; Title = $Label.TrimEnd(':') }
    }
    $btn.add_Click({ Invoke-BrowseDialog $this.Tag })
    $Parent.Controls.Add($btn)
    $txt
}

function New-CheckBox($Parent, [string]$Text, [bool]$Checked, [int]$Y, [int]$X = 12) {
    $cb = New-Object System.Windows.Forms.CheckBox -Property @{ Text = $Text; Checked = $Checked; Location = (Pt $X $Y); AutoSize = $true }
    $Parent.Controls.Add($cb)
    $cb
}

function New-OptionCombo($Parent, $Options, [string]$Value, [int]$X, [int]$Y, [int]$Width) {
    $combo = New-Object System.Windows.Forms.ComboBox -Property @{ DropDownStyle = 'DropDownList'; Location = (Pt $X $Y); Width = $Width }
    foreach ($o in $Options) { [void]$combo.Items.Add($o.Label) }
    $index = 0
    for ($i = 0; $i -lt $Options.Count; $i++) { if ($Options[$i].Value -eq $Value) { $index = $i } }
    $combo.SelectedIndex = $index
    $Parent.Controls.Add($combo)
    $combo
}

function New-Number($Parent, [int]$Value, [int]$Min, [int]$Max, [int]$X, [int]$Y) {
    $num = New-Object System.Windows.Forms.NumericUpDown -Property @{ Minimum = $Min; Maximum = $Max; Location = (Pt $X $Y); Width = 70 }
    $num.Value = [Math]::Min($Max, [Math]::Max($Min, $Value))
    $Parent.Controls.Add($num)
    $num
}

# "Save each chapter as a separate file" plus the indented "Also keep the full-length file".
function New-ChapterOptions($Parent, [bool]$Split, [bool]$KeepFull, [int]$Y) {
    $cbSplit = New-CheckBox $Parent 'Save each chapter as a separate file' $Split $Y
    $cbKeep = New-CheckBox $Parent 'Also keep the full-length file (otherwise it goes to the Recycle Bin)' $KeepFull ($Y + 24) 32
    [void](New-Label $Parent "Chapter files are saved in a folder named after the video.`nVideos without chapters are saved as one file." 32 ($Y + 50) -Hint)
    $cbKeep.Enabled = $Split
    $cbSplit.Tag = $cbKeep
    $cbSplit.add_CheckedChanged({ $this.Tag.Enabled = $this.Checked })
    $cbSplit
    $cbKeep
}

# -Tab picks the tab to open on, e.g. 'Sources'
function Show-SettingsDialog([string]$Tab) {
    $s = $script:Settings
    $dlg = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Settings'; ClientSize = (Sz 620 500); StartPosition = 'CenterParent'; Font = $form.Font
        FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; ShowInTaskbar = $false
    }
    $tabs = New-Object System.Windows.Forms.TabControl -Property @{ Location = (Pt 10 10); Size = (Sz 600 440) }
    $tabGeneral   = New-Object System.Windows.Forms.TabPage 'General'
    $tabSources   = New-Object System.Windows.Forms.TabPage 'Sources'
    $tabAudio     = New-Object System.Windows.Forms.TabPage 'Audio'
    $tabVideo     = New-Object System.Windows.Forms.TabPage 'Video'
    $tabDownloads = New-Object System.Windows.Forms.TabPage 'Downloads'
    $tabs.TabPages.AddRange(@($tabGeneral, $tabSources, $tabAudio, $tabVideo, $tabDownloads))
    $startTab = $tabs.TabPages | Where-Object { $_.Text -eq $Tab } | Select-Object -First 1
    if ($startTab) { $tabs.SelectedTab = $startTab }

    # General tab: folders, tools and start-up behaviour
    $txtVideoDir   = New-PathRow $tabGeneral 'Video folder:'   $s.VideoDir   14
    $txtAudioDir   = New-PathRow $tabGeneral 'Audio folder:'   $s.AudioDir   46
    $txtLogDir     = New-PathRow $tabGeneral 'Log folder:'     $s.LogDir     78
    $txtArchiveDir = New-PathRow $tabGeneral 'Archive folder:' $s.ArchiveDir 110
    $txtYtDlp      = New-PathRow $tabGeneral 'yt-dlp.exe:'     $s.YtDlpPath  142 'File'
    $txtFfmpeg     = New-PathRow $tabGeneral 'ffmpeg.exe:'     $s.FfmpegPath 174 'File'
    $txtDeno       = New-PathRow $tabGeneral 'deno.exe:'       $s.DenoPath   206 'File'
    [void](New-Label $tabGeneral 'Leave yt-dlp.exe, ffmpeg.exe or deno.exe empty to find them automatically.' 130 232 -Hint)
    $cbCheckUpdates = New-CheckBox $tabGeneral 'Check for yt-dlp, ffmpeg and Deno updates when the app starts' $s.CheckUpdatesOnStart 262
    $cbArchive      = New-CheckBox $tabGeneral 'Archive the current yt-dlp, ffmpeg and Deno before updating them' $s.ArchiveBeforeUpdate 286
    $cbAutoPaste    = New-CheckBox $tabGeneral 'Automatically paste links copied to the clipboard (for the selected source)' $s.AutoPaste 310

    # Sources tab
    [void](New-Label $tabSources 'When the app starts, select:' 12 16)
    $rbLast    = New-Object System.Windows.Forms.RadioButton -Property @{ Text = 'The source I used last'; Location = (Pt 24 40); AutoSize = $true; Checked = ($s.StartupSource -eq 'Last') }
    $rbDefault = New-Object System.Windows.Forms.RadioButton -Property @{ Text = 'The default source'; Location = (Pt 24 66); AutoSize = $true; Checked = ($s.StartupSource -ne 'Last') }
    $tabSources.Controls.AddRange(@($rbLast, $rbDefault))
    [void](New-Label $tabSources 'Default source:' 12 108)
    $sourceOptions = $script:Sources | ForEach-Object { [pscustomobject]@{ Label = $_.Name; Value = $_.Name } }
    $cmbDefaultSource = New-OptionCombo $tabSources $sourceOptions $s.DefaultSource 130 104 180
    [void](New-Label $tabSources 'Use login cookies from:' 12 158)
    $cmbCookies = New-OptionCombo $tabSources $script:CookieOptions $s.CookieSource 160 154 180
    $txtCookieFile = New-PathRow $tabSources 'cookies.txt file:' $s.CookieFile 190 'Text'
    [void](New-Label $tabSources ("Needed for Instagram, Facebook, and private or age-restricted videos. Sign in to the site in`n" +
        "that browser first. Firefox works best; Chrome-based browsers may need to be closed.") 12 222 -Hint)

    # Audio tab
    [void](New-Label $tabAudio 'Format:' 12 18)
    $cmbAudioFormat = New-OptionCombo $tabAudio $script:AudioFormatOptions $s.AudioFormat 130 14 200
    [void](New-Label $tabAudio 'Quality:' 12 50)
    $cmbQuality = New-OptionCombo $tabAudio $script:AudioQualityOptions $s.AudioQuality 130 46 260
    [void](New-Label $tabAudio 'Not used for FLAC and WAV' 398 50 -Hint)
    $cbAudioThumb  = New-CheckBox $tabAudio 'Embed the video thumbnail as cover art' $s.AudioEmbedThumbnail 84
    $cbAudioMeta   = New-CheckBox $tabAudio 'Embed metadata (title, artist, date, description)' $s.AudioEmbedMetadata 108
    $cbAudioSponsor = New-CheckBox $tabAudio 'Remove sponsors and non-music parts (YouTube SponsorBlock)' $s.AudioSponsorBlock 132
    [void](New-Label $tabAudio 'File name:' 12 172)
    $txtAudioTemplate = New-TextBox $tabAudio $s.AudioTemplate 130 168 425
    [void](New-Label $tabAudio "yt-dlp output template, e.g. %(title)s.%(ext)s or %(uploader)s - %(title)s.%(ext)s" 130 194 -Hint)
    $cbAudioSplit, $cbAudioKeep = New-ChapterOptions $tabAudio $s.AudioSplitChapters $s.AudioKeepFullFile 230

    # Video tab
    [void](New-Label $tabVideo 'Max resolution:' 12 18)
    $cmbResolution = New-OptionCombo $tabVideo $script:ResolutionOptions $s.VideoMaxHeight 130 14 160
    [void](New-Label $tabVideo 'Max frame rate:' 320 18)
    $cmbFps = New-OptionCombo $tabVideo $script:FrameRateOptions $s.VideoMaxFps 425 14 100
    [void](New-Label $tabVideo 'Container:' 12 50)
    $cmbContainer = New-OptionCombo $tabVideo $script:ContainerOptions $s.VideoContainer 130 46 240
    $cbH264       = New-CheckBox $tabVideo 'Prefer H.264 video (plays on every device; may be lower quality)' $s.VideoPreferH264 82
    $cbVideoThumb = New-CheckBox $tabVideo 'Embed the thumbnail' $s.VideoEmbedThumbnail 106
    $cbVideoMeta  = New-CheckBox $tabVideo 'Embed metadata (title, channel, date, description)' $s.VideoEmbedMetadata 130
    $cbVideoChap  = New-CheckBox $tabVideo 'Embed chapter markers' $s.VideoEmbedChapters 154
    $cbSubs       = New-CheckBox $tabVideo 'Embed subtitles' $s.VideoEmbedSubs 178
    [void](New-Label $tabVideo 'Languages:' 200 180)
    $txtSubLangs  = New-TextBox $tabVideo $s.VideoSubLangs 270 176 120
    [void](New-Label $tabVideo 'e.g. en or en,es or all' 398 180 -Hint)
    $cbAutoSubs   = New-CheckBox $tabVideo 'Include auto-generated subtitles when there are no others' $s.VideoAutoSubs 202 32
    $cbVideoSponsor = New-CheckBox $tabVideo 'Remove sponsor segments (YouTube SponsorBlock)' $s.VideoSponsorBlock 226
    [void](New-Label $tabVideo 'File name:' 12 264)
    $txtVideoTemplate = New-TextBox $tabVideo $s.VideoTemplate 130 260 425
    [void](New-Label $tabVideo "yt-dlp output template, e.g. %(title)s.%(ext)s or %(uploader)s\%(title)s.%(ext)s" 130 286 -Hint)
    $cbVideoSplit, $cbVideoKeep = New-ChapterOptions $tabVideo $s.VideoSplitChapters $s.VideoKeepFullFile 316
    $cbAutoSubs.Enabled = $cbSubs.Checked
    $cbSubs.Tag = $cbAutoSubs
    $cbSubs.add_CheckedChanged({ $this.Tag.Enabled = $this.Checked })

    # Downloads tab
    $cbPlaylist = New-CheckBox $tabDownloads 'Download the whole playlist when a link contains one' $s.DownloadPlaylists 14
    [void](New-Label $tabDownloads 'Speed limit:' 12 50)
    $txtSpeed = New-TextBox $tabDownloads $s.SpeedLimit 160 46 90
    [void](New-Label $tabDownloads 'e.g. 5M or 500K per second; empty for no limit' 260 50 -Hint)
    [void](New-Label $tabDownloads 'Parallel fragments:' 12 82)
    $numFragments = New-Number $tabDownloads $s.Fragments 1 16 160 78
    [void](New-Label $tabDownloads 'Download pieces at the same time (faster on many sites)' 260 82 -Hint)
    [void](New-Label $tabDownloads 'Retries:' 12 114)
    $numRetries = New-Number $tabDownloads $s.Retries 0 100 160 110
    [void](New-Label $tabDownloads 'Proxy:' 12 146)
    $txtProxy = New-TextBox $tabDownloads $s.Proxy 160 142 250
    [void](New-Label $tabDownloads 'e.g. socks5://127.0.0.1:1080' 418 146 -Hint)
    $cbHistory   = New-CheckBox $tabDownloads 'Skip videos already downloaded (keeps a download history)' $s.UseDownloadHistory 182
    $cbOverwrite = New-CheckBox $tabDownloads 'Overwrite files that already exist' $s.OverwriteFiles 206
    $cbRestrict  = New-CheckBox $tabDownloads 'Use only plain letters and numbers in file names (no spaces or symbols)' $s.RestrictFilenames 230
    $cbThumbFile = New-CheckBox $tabDownloads 'Also save the thumbnail as a .jpg image' $s.SaveThumbnailImage 254
    $cbDescFile  = New-CheckBox $tabDownloads 'Also save the description as a text file' $s.SaveDescription 278
    [void](New-Label $tabDownloads 'Extra arguments:' 12 318)
    $txtExtra = New-TextBox $tabDownloads $s.ExtraArgs 130 314 425
    [void](New-Label $tabDownloads 'Advanced: added to every yt-dlp command, e.g. --geo-bypass' 130 340 -Hint)

    $btnOk = New-Object System.Windows.Forms.Button -Property @{ Text = 'OK'; Location = (Pt 440 462); Width = 80; DialogResult = 'OK' }
    $btnCancelDlg = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (Pt 530 462); Width = 80; DialogResult = 'Cancel' }
    $dlg.AcceptButton = $btnOk
    $dlg.CancelButton = $btnCancelDlg
    $dlg.Controls.AddRange(@($tabs, $btnOk, $btnCancelDlg))
    Set-DarkTheme $dlg
    if ($script:AppIcon) { $dlg.Icon = $script:AppIcon }

    if ($dlg.ShowDialog($form) -eq 'OK') {
        $oldTools = "$($s.YtDlpPath)|$($s.FfmpegPath)|$($s.DenoPath)"
        $defaults = Get-DefaultSettings
        $s.VideoDir   = if ($txtVideoDir.Text.Trim())   { $txtVideoDir.Text.Trim() }   else { $defaults.VideoDir }
        $s.AudioDir   = if ($txtAudioDir.Text.Trim())   { $txtAudioDir.Text.Trim() }   else { $defaults.AudioDir }
        $s.LogDir     = if ($txtLogDir.Text.Trim())     { $txtLogDir.Text.Trim() }     else { $defaults.LogDir }
        $s.ArchiveDir = if ($txtArchiveDir.Text.Trim()) { $txtArchiveDir.Text.Trim() } else { $defaults.ArchiveDir }
        $s.YtDlpPath  = $txtYtDlp.Text.Trim()
        $s.FfmpegPath = $txtFfmpeg.Text.Trim()
        $s.DenoPath   = $txtDeno.Text.Trim()
        $s.CheckUpdatesOnStart = $cbCheckUpdates.Checked
        $s.ArchiveBeforeUpdate = $cbArchive.Checked
        $s.AutoPaste           = $cbAutoPaste.Checked

        $s.StartupSource = if ($rbLast.Checked) { 'Last' } else { 'Default' }
        $s.DefaultSource = $sourceOptions[$cmbDefaultSource.SelectedIndex].Value
        $s.CookieSource  = $script:CookieOptions[$cmbCookies.SelectedIndex].Value
        $s.CookieFile    = $txtCookieFile.Text.Trim()

        $s.AudioFormat         = $script:AudioFormatOptions[$cmbAudioFormat.SelectedIndex].Value
        $s.AudioQuality        = $script:AudioQualityOptions[$cmbQuality.SelectedIndex].Value
        $s.AudioEmbedThumbnail = $cbAudioThumb.Checked
        $s.AudioEmbedMetadata  = $cbAudioMeta.Checked
        $s.AudioSponsorBlock   = $cbAudioSponsor.Checked
        $s.AudioTemplate       = if ($txtAudioTemplate.Text.Trim()) { $txtAudioTemplate.Text.Trim() } else { $defaults.AudioTemplate }
        $s.AudioSplitChapters  = $cbAudioSplit.Checked
        $s.AudioKeepFullFile   = $cbAudioKeep.Checked

        $s.VideoMaxHeight      = $script:ResolutionOptions[$cmbResolution.SelectedIndex].Value
        $s.VideoMaxFps         = $script:FrameRateOptions[$cmbFps.SelectedIndex].Value
        $s.VideoContainer      = $script:ContainerOptions[$cmbContainer.SelectedIndex].Value
        $s.VideoPreferH264     = $cbH264.Checked
        $s.VideoEmbedThumbnail = $cbVideoThumb.Checked
        $s.VideoEmbedMetadata  = $cbVideoMeta.Checked
        $s.VideoEmbedChapters  = $cbVideoChap.Checked
        $s.VideoEmbedSubs      = $cbSubs.Checked
        $s.VideoAutoSubs       = $cbAutoSubs.Checked
        $s.VideoSubLangs       = if ($txtSubLangs.Text.Trim()) { $txtSubLangs.Text.Trim() } else { 'en' }
        $s.VideoSponsorBlock   = $cbVideoSponsor.Checked
        $s.VideoTemplate       = if ($txtVideoTemplate.Text.Trim()) { $txtVideoTemplate.Text.Trim() } else { $defaults.VideoTemplate }
        $s.VideoSplitChapters  = $cbVideoSplit.Checked
        $s.VideoKeepFullFile   = $cbVideoKeep.Checked

        $s.DownloadPlaylists  = $cbPlaylist.Checked
        $s.SpeedLimit         = $txtSpeed.Text.Trim()
        $s.Fragments          = [int]$numFragments.Value
        $s.Retries            = [int]$numRetries.Value
        $s.Proxy              = $txtProxy.Text.Trim()
        $s.UseDownloadHistory = $cbHistory.Checked
        $s.OverwriteFiles     = $cbOverwrite.Checked
        $s.RestrictFilenames  = $cbRestrict.Checked
        $s.SaveThumbnailImage = $cbThumbFile.Checked
        $s.SaveDescription    = $cbDescFile.Checked
        $s.ExtraArgs          = $txtExtra.Text.Trim()

        Save-AppSettings
        Write-Activity 'Settings saved.'
        Update-DownloadButtonText
        if ($oldTools -ne "$($s.YtDlpPath)|$($s.FfmpegPath)|$($s.DenoPath)" -and -not $script:IsBusy) { Update-VersionInfo }
    }
    $dlg.Dispose()
}

# ---------------------------------------------------------------------------
# Activity window
# ---------------------------------------------------------------------------

function Show-ActivityWindow {
    if ($script:ActivityForm -and -not $script:ActivityForm.IsDisposed) {
        $script:ActivityForm.Activate()
        return
    }

    $f = New-Object System.Windows.Forms.Form -Property @{
        Text = 'Activity'; ClientSize = (Sz 780 420); StartPosition = 'CenterScreen'
        MinimumSize = (Sz 420 250); Font = $form.Font; ShowInTaskbar = $false
    }
    $lbl = New-Object System.Windows.Forms.Label -Property @{
        Text = $lblStatus.Text; Dock = 'Top'; Height = 30; Padding = (New-Object System.Windows.Forms.Padding(8, 8, 8, 0))
    }
    $box = New-Object System.Windows.Forms.TextBox -Property @{
        Multiline = $true; ReadOnly = $true; ScrollBars = 'Both'; WordWrap = $false; Dock = 'Fill'
        Font = (New-Object System.Drawing.Font('Consolas', 9)); BackColor = [System.Drawing.SystemColors]::Window
    }
    $buttons = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
        Dock = 'Bottom'; Height = 42; FlowDirection = 'RightToLeft'; Padding = (New-Object System.Windows.Forms.Padding(6))
    }
    $btnClose    = New-Object System.Windows.Forms.Button -Property @{ Text = 'Close'; Width = 90 }
    $btnLogs     = New-Object System.Windows.Forms.Button -Property @{ Text = 'Open log folder'; Width = 120 }
    $btnCopy     = New-Object System.Windows.Forms.Button -Property @{ Text = 'Copy all'; Width = 90 }
    $btnClearLog = New-Object System.Windows.Forms.Button -Property @{ Text = 'Clear'; Width = 90 }
    $btnClose.add_Click({ $script:ActivityForm.Close() })
    $btnLogs.add_Click({ Open-Folder $script:Settings.LogDir })
    $btnCopy.add_Click({ if ($script:ActivityBox.Text) { [System.Windows.Forms.Clipboard]::SetText($script:ActivityBox.Text) } })
    $btnClearLog.add_Click({ $script:ActivityLines.Clear(); $script:ActivityBox.Clear() })
    $buttons.Controls.AddRange(@($btnClose, $btnLogs, $btnCopy, $btnClearLog))

    $f.Controls.Add($box)
    $f.Controls.Add($lbl)
    $f.Controls.Add($buttons)

    if ($script:ActivityLines.Count) { $box.Text = ($script:ActivityLines -join "`r`n") + "`r`n" }
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()

    $script:ActivityForm = $f
    $script:ActivityBox = $box
    $script:ActivityStatus = $lbl
    $f.add_FormClosed({
        $script:ActivityForm = $null
        $script:ActivityBox = $null
        $script:ActivityStatus = $null
    })
    Set-DarkTheme $f
    $lbl.ForeColor = [CyColors]::AccentLight
    if ($script:AppIcon) { $f.Icon = $script:AppIcon }
    $f.Show($form)
}

# ---------------------------------------------------------------------------
# Colour scheme, icon and splash screen
# ---------------------------------------------------------------------------

# Applies the Cybtek colours to a window and everything in it.
function Set-DarkTheme($Control) {
    $c = $Control
    if ($c -is [System.Windows.Forms.MenuStrip]) {
        $c.Renderer = New-Object CyMenuRenderer
        $c.BackColor = [CyColors]::Panel
        $c.ForeColor = [CyColors]::Text
    } elseif ($c -is [System.Windows.Forms.Button]) {
        $c.FlatStyle = 'Flat'
        $c.UseVisualStyleBackColor = $false
        $c.BackColor = [CyColors]::Hover
        $c.ForeColor = [CyColors]::Text
        $c.FlatAppearance.BorderColor = [CyColors]::Border
        $c.FlatAppearance.MouseOverBackColor = [CyColors]::ButtonHover
        $c.FlatAppearance.MouseDownBackColor = [CyColors]::Accent
    } elseif ($c -is [System.Windows.Forms.TextBox] -or $c -is [System.Windows.Forms.ListBox]) {
        $c.BackColor = [CyColors]::Input
        $c.ForeColor = [CyColors]::Text
        $c.BorderStyle = 'FixedSingle'
    } elseif ($c -is [System.Windows.Forms.ComboBox]) {
        $c.FlatStyle = 'Flat'
        $c.BackColor = [CyColors]::Input
        $c.ForeColor = [CyColors]::Text
    } elseif ($c -is [System.Windows.Forms.NumericUpDown]) {
        $c.BackColor = [CyColors]::Input
        $c.ForeColor = [CyColors]::Text
        $c.BorderStyle = 'FixedSingle'
    } elseif ($c -is [System.Windows.Forms.LinkLabel]) {
        $c.LinkColor = $c.VisitedLinkColor = [CyColors]::AccentLight
        $c.ActiveLinkColor = [CyColors]::Text
    } elseif ($c -is [System.Windows.Forms.Label]) {
        $c.ForeColor = if ($c.Tag -eq 'hint') { [CyColors]::Muted } else { [CyColors]::Text }
    } elseif ($c -is [System.Windows.Forms.CheckBox] -or $c -is [System.Windows.Forms.RadioButton]) {
        $c.ForeColor = [CyColors]::Text
    } elseif ($c -is [System.Windows.Forms.TabControl]) {
        # Owner-drawn tab headers, so they match the pages. They read the colours when they draw,
        # so a later colour change only needs a repaint.
        if ($c.DrawMode -eq 'OwnerDrawFixed') { $c.Invalidate() }
        else {
        $c.DrawMode = 'OwnerDrawFixed'
        $c.add_DrawItem({
            param($s, $e)
            $selected = $s.SelectedIndex -eq $e.Index
            $brush = New-Object System.Drawing.SolidBrush($(if ($selected) { [CyColors]::Back } else { [CyColors]::Panel }))
            $e.Graphics.FillRectangle($brush, $e.Bounds)
            $brush.Dispose()
            $fore = if ($selected) { [CyColors]::AccentLight } else { [CyColors]::Text }
            [System.Windows.Forms.TextRenderer]::DrawText($e.Graphics, $s.TabPages[$e.Index].Text, $s.Font, $e.Bounds, $fore, 'HorizontalCenter, VerticalCenter')
        })
        }
    } elseif ($c -is [System.Windows.Forms.TabPage]) {
        $c.UseVisualStyleBackColor = $false
        $c.BackColor = [CyColors]::Back
        $c.ForeColor = [CyColors]::Text
    } elseif ($c -is [System.Windows.Forms.Form]) {
        $c.BackColor = [CyColors]::Back
        $c.ForeColor = [CyColors]::Text
        if ($c.IsHandleCreated) { [CyNative]::UseDarkTitleBar($c.Handle) }
        elseif ($c.Tag -ne 'themed') { $c.add_HandleCreated({ [CyNative]::UseDarkTitleBar($this.Handle) }) }
        if ($null -eq $c.Tag) { $c.Tag = 'themed' }
    } elseif ($c -is [System.Windows.Forms.Panel]) {
        $c.BackColor = [CyColors]::Back
        $c.ForeColor = [CyColors]::Text
    }
    foreach ($child in $c.Controls) { Set-DarkTheme $child }
}

# The splash image: use the copy we downloaded before, else download it once from GitHub (kept next to the
# script, or in the app data folder if the script's folder can't be written), else an image from an older
# version if we are offline. Later runs use the local file.
$script:SplashImage = $null
$splashLocal = $null
foreach ($p in @($script:SplashFile, $script:SplashFallback)) {
    if ($p -and (Test-Path -LiteralPath $p)) { $splashLocal = $p; break }
}
if (-not $splashLocal) {
    foreach ($dest in @($script:SplashFile, $script:SplashFallback)) {
        if (-not $dest) { continue }
        try {
            New-Item -ItemType Directory -Force -Path (Split-Path -Parent $dest) | Out-Null
            $prevProgress = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest -Uri $script:SplashUrl -OutFile $dest -TimeoutSec 15 -UseBasicParsing
            $ProgressPreference = $prevProgress
            $splashLocal = $dest
            Write-Activity "Splash image downloaded to $dest"
            break
        } catch { }
    }
}
if (-not $splashLocal) {
    $legacy = @()
    if ($PSScriptRoot) { $legacy += (Join-Path $PSScriptRoot 'CybtekDownloader-splash.jpg') }
    $legacy += (Join-Path $script:AppDataDir 'splash.jpg')
    $splashLocal = $legacy | Where-Object { Test-Path -LiteralPath $_ } | Select-Object -First 1
}
if ($splashLocal) {
    $script:SplashFile = $splashLocal
    # Load from a copy of the bytes, so the file itself is not locked
    try { $script:SplashImage = [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(, ([IO.File]::ReadAllBytes($splashLocal))))) } catch { }
}

# The window icon is the "C" logo cut out of the splash image.
$script:AppIcon = $null
if ($script:SplashImage) {
    try {
        $scale = $script:SplashImage.Width / 1672.0
        $srcRect = New-Object System.Drawing.Rectangle([int](175 * $scale), [int](160 * $scale), [int](500 * $scale), [int](500 * $scale))
        $iconBmp = New-Object System.Drawing.Bitmap(64, 64)
        $g = [System.Drawing.Graphics]::FromImage($iconBmp)
        $g.InterpolationMode = 'HighQualityBicubic'
        $g.DrawImage($script:SplashImage, (New-Object System.Drawing.Rectangle(0, 0, 64, 64)), $srcRect, 'Pixel')
        $g.Dispose()
        $script:AppIcon = [System.Drawing.Icon]::FromHandle($iconBmp.GetHicon())
    } catch { }
}

# Shows the splash image with a "Loading" bar that fills from 0 to 100% in 3 seconds.
function Show-SplashScreen {
    $width = 760
    $imageHeight = if ($script:SplashImage) { [int]($width * $script:SplashImage.Height / $script:SplashImage.Width) } else { 300 }
    $splash = New-Object System.Windows.Forms.Form -Property @{
        Text = $script:AppName; FormBorderStyle = 'None'; StartPosition = 'CenterScreen'
        ClientSize = (Sz $width ($imageHeight + 46)); BackColor = [CyColors]::Back; TopMost = $true
    }
    if ($script:AppIcon) { $splash.Icon = $script:AppIcon }

    if ($script:SplashImage) {
        $picture = New-Object System.Windows.Forms.PictureBox -Property @{
            Image = $script:SplashImage; SizeMode = 'Zoom'; Location = (Pt 0 0); Size = (Sz $width $imageHeight)
        }
        $splash.Controls.Add($picture)
    } else {
        $title = New-Object System.Windows.Forms.Label -Property @{
            Text = $script:AppName; ForeColor = [CyColors]::AccentLight; TextAlign = 'MiddleCenter'
            Font = (New-Object System.Drawing.Font('Segoe UI Semibold', 36)); Location = (Pt 0 0); Size = (Sz $width $imageHeight)
        }
        $splash.Controls.Add($title)
    }

    $font = New-Object System.Drawing.Font('Segoe UI', 10)
    $lblLoading = New-Object System.Windows.Forms.Label -Property @{
        Text = 'Loading'; ForeColor = [CyColors]::Text; Font = $font; Location = (Pt 18 ($imageHeight + 13)); Size = (Sz 70 20)
    }
    $bar = New-Object CyProgressBar -Property @{ Location = (Pt 92 ($imageHeight + 17)); Size = (Sz ($width - 92 - 72) 12) }
    $lblPercent = New-Object System.Windows.Forms.Label -Property @{
        Text = '0%'; ForeColor = [CyColors]::AccentLight; TextAlign = 'MiddleRight'
        Font = (New-Object System.Drawing.Font('Segoe UI Semibold', 10)); Location = (Pt ($width - 70) ($imageHeight + 12)); Size = (Sz 54 22)
    }
    $splash.Controls.AddRange(@($lblLoading, $bar, $lblPercent))

    # Fills by elapsed milliseconds, so it reaches 100% at 3 seconds whatever the timer does
    $script:SplashClock = [System.Diagnostics.Stopwatch]::StartNew()
    $script:SplashParts = @{ Form = $splash; Bar = $bar; Percent = $lblPercent; Loading = $lblLoading }
    $splashTimer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 15 }
    $splashTimer.add_Tick({
        $ms = $script:SplashClock.ElapsedMilliseconds
        $pct = [int][Math]::Min(100, [Math]::Floor($ms / 30))
        $script:SplashParts.Bar.Value = $pct
        $script:SplashParts.Percent.Text = "$pct%"
        $script:SplashParts.Loading.Text = 'Loading' + ('.' * ([int]($ms / 400) % 4))
        if ($ms -ge 3250) { $this.Stop(); $script:SplashParts.Form.Close() }   # hold 100% briefly
    })
    $splash.add_Shown({ $splashTimer.Start() })
    [void]$splash.ShowDialog()
    $splashTimer.Dispose()
    $splash.Dispose()
}

Show-SplashScreen

# ---------------------------------------------------------------------------
# Main window
# ---------------------------------------------------------------------------

$form = New-Object System.Windows.Forms.Form -Property @{
    Text = $script:AppName; ClientSize = (Sz 640 250); StartPosition = 'CenterScreen'
    MinimumSize = (Sz 560 300); Font = (New-Object System.Drawing.Font('Segoe UI', 9))
}

# Menu bar
$menu = New-Object System.Windows.Forms.MenuStrip
$menu.ShowItemToolTips = $true
$miFile = New-Object System.Windows.Forms.ToolStripMenuItem '&File'
$miSettings = New-Object System.Windows.Forms.ToolStripMenuItem '&Settings...'
$miActivity = New-Object System.Windows.Forms.ToolStripMenuItem '&Activity...'
$miOpenVideo = New-Object System.Windows.Forms.ToolStripMenuItem 'Open &video folder'
$miOpenAudio = New-Object System.Windows.Forms.ToolStripMenuItem 'Open a&udio folder'
$miOpenLogs = New-Object System.Windows.Forms.ToolStripMenuItem 'Open &log folder'
$miOpenArchive = New-Object System.Windows.Forms.ToolStripMenuItem 'Open a&rchive folder'
$miExit = New-Object System.Windows.Forms.ToolStripMenuItem 'E&xit'
$miSettings.ShortcutKeys = 'Control, Oemcomma'
$miActivity.ShortcutKeys = 'Control, L'
$miFile.DropDownItems.AddRange(@(
    $miSettings, $miActivity, (New-Object System.Windows.Forms.ToolStripSeparator),
    $miOpenVideo, $miOpenAudio, $miOpenLogs, $miOpenArchive, (New-Object System.Windows.Forms.ToolStripSeparator),
    $miExit))

# Source: one site at a time, shown with a check mark
$miSource = New-Object System.Windows.Forms.ToolStripMenuItem '&Source'
foreach ($src in $script:Sources) {
    if ($src.Name -eq 'Other site') { [void]$miSource.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator)) }
    $mi = New-Object System.Windows.Forms.ToolStripMenuItem $src.Name
    $mi.Tag = $src.Name
    $mi.ToolTipText = if ($src.AudioOnly) { 'Audio only' } elseif ($src.Hosts) { "Auto-pastes copied $($src.Name) links" } else { 'Any site yt-dlp supports (no auto-paste)' }
    $mi.add_Click({ Set-Source $this.Tag })
    [void]$miSource.DropDownItems.Add($mi)
}
$miSupportedSites = New-Object System.Windows.Forms.ToolStripMenuItem 'All supported sites...'
$miSupportedSites.add_Click({ Start-Process $script:SupportedSitesUrl })
[void]$miSource.DropDownItems.Add((New-Object System.Windows.Forms.ToolStripSeparator))
[void]$miSource.DropDownItems.Add($miSupportedSites)

# Addons: filled in by Update-AddonsMenu
$miAddons = New-Object System.Windows.Forms.ToolStripMenuItem '&Addons'
$miInstallAddon = New-Object System.Windows.Forms.ToolStripMenuItem '&Install Addon...'
$miUninstallAddon = New-Object System.Windows.Forms.ToolStripMenuItem '&Uninstall Addon...'

$miHelp = New-Object System.Windows.Forms.ToolStripMenuItem '&Help'
$miHelpDocs = New-Object System.Windows.Forms.ToolStripMenuItem '&Help Documents'
$miInstallDeps = New-Object System.Windows.Forms.ToolStripMenuItem '&Install Dependencies'
$miUpdateDeps = New-Object System.Windows.Forms.ToolStripMenuItem '&Update Dependencies'
$miArchiveDeps = New-Object System.Windows.Forms.ToolStripMenuItem '&Archive Dependencies'
$miCheckUpdates = New-Object System.Windows.Forms.ToolStripMenuItem '&Check for Updates'
$miGitHub = New-Object System.Windows.Forms.ToolStripMenuItem 'yt-dlp on &GitHub'
$miAbout = New-Object System.Windows.Forms.ToolStripMenuItem 'A&bout'
$miHelpDocs.ShortcutKeys = 'F1'
$miHelp.DropDownItems.AddRange(@(
    $miHelpDocs, (New-Object System.Windows.Forms.ToolStripSeparator),
    $miInstallDeps, $miUpdateDeps, $miArchiveDeps, $miCheckUpdates, (New-Object System.Windows.Forms.ToolStripSeparator),
    $miGitHub, $miAbout))

$menu.Items.AddRange(@($miFile, $miSource, $miAddons, $miHelp))

# Version number, aligned to the right of the menu bar (two trailing spaces keep it off the edge)
$miVersion = New-Object System.Windows.Forms.ToolStripLabel ("v.$($script:AppVersion)  ")
$miVersion.Alignment = 'Right'
[void]$menu.Items.Add($miVersion)

$form.MainMenuStrip = $menu

# Dependency status strip under the menu bar
$versionPanel = New-Object System.Windows.Forms.Panel -Property @{
    Dock = 'Top'; Height = 30; Padding = (New-Object System.Windows.Forms.Padding(10, 0, 10, 0))
}
$lblDeps = New-Object System.Windows.Forms.Label -Property @{
    Text = "$([char]0x25CF)  Checking dependencies..."; Dock = 'Fill'; TextAlign = 'MiddleLeft'; AutoEllipsis = $true
}
$depsTip = New-Object System.Windows.Forms.ToolTip
$versionPanel.Controls.Add($lblDeps)
$versionLine = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Bottom'; Height = 1; Tag = 'line' }
$versionPanel.Controls.Add($versionLine)

# Content. The panel gets the form's width up front: anchored children remember their
# distance to the panel's right edge when added, so a narrow default panel would make
# them stretch past the window once it is docked.
$content = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Fill'; Size = (Sz 640 190) }
$lblUrl = New-Object System.Windows.Forms.Label -Property @{ Text = 'Video URL:'; Location = (Pt 12 12); AutoSize = $true }
$txtUrl = New-Object System.Windows.Forms.TextBox -Property @{ Location = (Pt 12 34); Width = 460; Anchor = 'Top, Left, Right' }
$btnPaste = New-Object System.Windows.Forms.Button -Property @{ Text = 'Paste'; Location = (Pt 480 33); Width = 70; Anchor = 'Top, Right' }
$btnClear = New-Object System.Windows.Forms.Button -Property @{ Text = 'Clear'; Location = (Pt 556 33); Width = 70; Anchor = 'Top, Right' }

$btnVideo = New-Object System.Windows.Forms.Button -Property @{ Text = 'Download Video'; Location = (Pt 12 72); Size = (Sz 180 36); Enabled = $false }
$btnAudio = New-Object System.Windows.Forms.Button -Property @{ Text = 'Download Audio'; Location = (Pt 200 72); Size = (Sz 180 36); Enabled = $false }
$btnCancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (Pt 388 72); Size = (Sz 90 36); Visible = $false }

$progress = New-Object CyProgressBar -Property @{
    Location = (Pt 12 124); Width = 614; Height = 16; Anchor = 'Top, Left, Right'; Visible = $false
}
$lblStatus = New-Object System.Windows.Forms.Label -Property @{
    Text = 'Ready.'; Location = (Pt 12 150); Width = 614; Height = 20; Anchor = 'Top, Left, Right'; AutoEllipsis = $true
}
$lnkOpenFolder = New-Object System.Windows.Forms.LinkLabel -Property @{ Text = 'Open download folder'; Location = (Pt 12 172); AutoSize = $true; Visible = $false }

$content.Controls.AddRange(@($lblUrl, $txtUrl, $btnPaste, $btnClear, $btnVideo, $btnAudio, $btnCancel, $progress, $lblStatus, $lnkOpenFolder))

# Docking runs from the last-added control, so add Fill first and the menu last.
$form.Controls.Add($content)
$form.Controls.Add($versionPanel)
$form.Controls.Add($menu)

# The parts of the main window that use colours other than the standard ones
function Set-MainThemeExtras {
    $versionPanel.BackColor = [CyColors]::Panel
    $versionLine.BackColor = [CyColors]::Border
    $lblUrl.ForeColor = [CyColors]::AccentLight
}

Set-DarkTheme $form
Set-MainThemeExtras
$btnVideo.Font = $btnAudio.Font = New-Object System.Drawing.Font('Segoe UI Semibold', 9.5)
if ($script:AppIcon) { $form.Icon = $script:AppIcon }

# Colour scheme: the names of the colours a scheme sets (as "#RRGGBB"), plus Light (true/false)
$script:ThemeColorNames = @('Back', 'Panel', 'Input', 'Hover', 'Border', 'Accent', 'AccentLight', 'Text', 'Muted', 'Disabled', 'Good', 'Warn', 'Bad')

function Get-AppColors {
    $colors = [ordered]@{}
    foreach ($n in $script:ThemeColorNames) { $colors[$n] = [System.Drawing.ColorTranslator]::ToHtml([CyColors]::$n) }
    $colors['Light'] = [CyColors]::Light
    $colors
}

# Switches the whole app to new colours and repaints every open window. $Colors can be a
# hashtable or an object read from JSON; colours it leaves out keep their current value.
function Set-AppColors($Colors) {
    foreach ($n in $script:ThemeColorNames) {
        $value = $Colors.$n
        if (-not $value) { continue }
        try { [CyColors]::$n = [System.Drawing.ColorTranslator]::FromHtml([string]$value) }
        catch { Write-Activity "Colour scheme: '$value' is not a valid colour for $n." }
    }
    if ($null -ne $Colors.Light) { [CyColors]::Light = [bool]$Colors.Light }
    # Button hover: a quarter of the way from Hover towards Accent
    $h = [CyColors]::Hover; $a = [CyColors]::Accent
    [CyColors]::ButtonHover = [System.Drawing.Color]::FromArgb(
        [int]($h.R + ($a.R - $h.R) / 4), [int]($h.G + ($a.G - $h.G) / 4), [int]($h.B + ($a.B - $h.B) / 4))

    foreach ($f in @([System.Windows.Forms.Application]::OpenForms)) {
        Set-DarkTheme $f
        if ($f.IsHandleCreated) { [CyNative]::UseDarkTitleBar($f.Handle) }
        $f.Refresh()
    }
    if ($script:ActivityStatus -and -not $script:ActivityStatus.IsDisposed) { $script:ActivityStatus.ForeColor = [CyColors]::AccentLight }
    Set-MainThemeExtras
    Update-DependencyStatus
    $menu.Invalidate()
}

# What addons get as $App
$script:AddonApi = [pscustomobject]@{
    Form       = $form
    Settings   = $script:Settings
    Log        = { param($Message) Write-Activity $Message }
    SetStatus  = { param($Text) Set-Status $Text }
    GetColors  = { Get-AppColors }
    SetColors  = { param($Colors) Set-AppColors $Colors }
    ColorNames = $script:ThemeColorNames
    SaveSettings   = { Save-AppSettings }
    EnsureWebView2 = { Ensure-WebView2 }
    AppVersion     = $script:AppVersion
}

# Timers
$pollTimer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 200 }
$clipTimer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 1000 }

# ---------------------------------------------------------------------------
# Events
# ---------------------------------------------------------------------------

$pollTimer.add_Tick({
    if (-not $script:Runner) { $pollTimer.Stop(); return }
    $line = $null
    while ($script:Runner.Lines.TryDequeue([ref]$line)) { Invoke-OutputLine $line }
    if ($script:Runner.Finished) {
        while ($script:Runner.Lines.TryDequeue([ref]$line)) { Invoke-OutputLine $line }
        $pollTimer.Stop()
        Complete-YtDlpDownload
    }
})
$clipTimer.add_Tick({ Invoke-ClipboardCheck })

$txtUrl.add_TextChanged({ Update-ButtonState; $lnkOpenFolder.Visible = $false })
$btnPaste.add_Click({
    try { $txtUrl.Text = [System.Windows.Forms.Clipboard]::GetText().Trim() } catch { }
})
$btnClear.add_Click({ $txtUrl.Clear(); $txtUrl.Focus() })
$btnVideo.add_Click({ Start-YtDlpDownload 'Video' })
$btnAudio.add_Click({ Start-YtDlpDownload 'Audio' })
$btnCancel.add_Click({ Stop-YtDlpDownload })
$lnkOpenFolder.add_LinkClicked({ Open-Folder $lnkOpenFolder.Tag })
$lblDeps.add_Click({ Invoke-DependencyStatusClick })

$miSettings.add_Click({ Show-SettingsDialog })
$miActivity.add_Click({ Show-ActivityWindow })
$miOpenVideo.add_Click({ Open-Folder $script:Settings.VideoDir })
$miOpenAudio.add_Click({ Open-Folder $script:Settings.AudioDir })
$miOpenLogs.add_Click({ Open-Folder $script:Settings.LogDir })
$miOpenArchive.add_Click({ Open-Folder $script:Settings.ArchiveDir })
$miExit.add_Click({ $form.Close() })
$miInstallAddon.add_Click({ Install-Addon })
$miUninstallAddon.add_Click({ Show-UninstallAddonDialog })
$miHelpDocs.add_Click({ Show-HelpDocuments })
$miInstallDeps.add_Click({ Invoke-InstallDependencies })
$miUpdateDeps.add_Click({ Invoke-UpdateDependencies })
$miArchiveDeps.add_Click({ if (-not $script:IsBusy) { Save-DependencyArchive } })
$miCheckUpdates.add_Click({ Invoke-UpdateDependencies -CheckOnly })
$miGitHub.add_Click({ Start-Process $script:YtDlpRepoUrl })
$miAbout.add_Click({
    $yt = if ($script:YtDlpVersion) { $script:YtDlpVersion } else { 'not installed' }
    $ff = if ($script:FfmpegVersion) { $script:FfmpegVersion } else { 'not installed' }
    $dn = if ($script:DenoVersion) { $script:DenoVersion } else { 'not installed' }
    $msg = "$($script:AppName) $($script:AppVersion)`n`nyt-dlp: $yt`nffmpeg: $ff`nDeno: $dn`nAddons: $($script:Addons.Count)`n`n$($script:YtDlpRepoUrl)`n`nSettings: $($script:SettingsFile)"
    [void](Show-Message $msg)
})

$form.add_Shown({
    Write-Activity "$($script:AppName) $($script:AppVersion) started."
    Update-DownloadButtonText
    Import-Addons
    $startSource = if ($script:Settings.StartupSource -eq 'Last') { $script:Settings.LastSource } else { $script:Settings.DefaultSource }
    Set-Source $startSource -NoSave
    $clipTimer.Start()
    Invoke-StartupDependencyCheck
})
$form.add_Activated({ Invoke-ClipboardCheck })

$form.add_FormClosing({
    param($s, $e)
    if ($script:Runner -and $script:Runner.IsRunning) {
        $answer = Show-Message 'A download is still running. Stop it and exit?' 'YesNo' 'Warning'
        if ($answer -ne 'Yes') { $e.Cancel = $true; return }
        Stop-YtDlpDownload
    }
    $clipTimer.Stop()
    $pollTimer.Stop()
})

[void]$form.ShowDialog()
$clipTimer.Dispose()
$pollTimer.Dispose()
$form.Dispose()