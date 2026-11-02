![Cybtek Downloader](Cybtek-Downloader.png)

# Cybtek Downloader

**A fast, friendly Windows interface for [yt-dlp](https://github.com/yt-dlp/yt-dlp) and [FFmpeg](https://ffmpeg.org/).**
Copy a link, click a button, and get the video (MP4/MKV) or the audio (MP3, M4A, Opus, OGG, FLAC, WAV) from YouTube, TikTok,
Instagram, Twitter / X, Twitch, Vimeo and [over a thousand other sites](https://github.com/yt-dlp/yt-dlp/blob/master/supportedsites.md).

It is a single PowerShell script. There is nothing to compile and nothing to install. It runs on the PowerShell that already
comes with Windows.

## Download

**Latest version: 1.6.0**

| | |
|---|---|
| **[Download the latest release](../../releases/latest)** | Recommended. A zip with everything you need |
| **[Download the whole repository as a ZIP](../../archive/refs/heads/main.zip)** | The newest code on the `main` branch |
| **[CybtekDler-v1.6.0.ps1](CybtekDler-v1.6.0.ps1)** | The PowerShell script on its own — this one file is all you need. It downloads its splash image from this repo the first time it runs. The file name carries the version (`CybtekDler-vMAJOR.MINOR.PATCH.ps1`) |

Unzip it anywhere, then double-click **`Cybtek Downloader.cmd`**.

---

## Why I built it

yt-dlp and FFmpeg are two of the best open-source tools there are, but they are command-line programs. To grab one song you
have to open a terminal, remember the right flags (`-x --audio-format mp3 --audio-quality 0 --embed-thumbnail ...`), quote
your paths correctly, and keep both programs updated by hand. Sites change all the time, so an out-of-date yt-dlp is the most
common reason a download fails.

I wanted the power of those tools without the typing:

- **Copy a link in your browser** and it is already in the app.
- **One click** for video, one click for audio.
- **The app looks after yt-dlp, FFmpeg and Deno itself**: it installs them, checks for updates when it starts, and updates them on request.
- **Every option I kept looking up** lives in a settings window instead of my notes.

## Features

| | |
|---|---|
| **One-click downloads** | Download Video (MP4 or MKV) and Download Audio (MP3, M4A, Opus, OGG, FLAC or WAV) buttons, with a live progress bar, speed and time left |
| **Clipboard auto-paste** | Copy a link from the selected source and it appears in the URL box |
| **Sources** | YouTube (the default), TikTok, Instagram, Twitter / X, Twitch, Facebook, Reddit, Vimeo, Dailymotion, Bilibili, SoundCloud, Bandcamp, or any other site yt-dlp supports |
| **Dependency manager** | Checks at start-up that yt-dlp, FFmpeg and Deno (the JavaScript runtime yt-dlp needs for YouTube) are installed and up to date, and installs or updates them from GitHub. Can also archive the current versions so you can roll back |
| **Chapters** | Save each chapter of a video as its own file (great for albums and mixes) |
| **SponsorBlock** | Cut sponsor segments, self-promotion and non-music parts out of YouTube videos |
| **Quality control** | Maximum resolution and frame rate, MP3 bitrate or VBR quality, H.264 preference for older devices |
| **Extras** | Embed thumbnails, metadata, chapter markers and subtitles; download playlists; keep a download history; speed limit; proxy; browser cookies for sites that need a login |
| **Addons** | Extend the app with your own PowerShell scripts (see [Writing an addon](#writing-an-addon)) |
| **Activity window** | Shows every line yt-dlp prints, plus the exact command it ran. Also written to daily log files |
| **Help documents** | Built-in help page (Help > Help Documents, or F1) |

## Getting started

### Requirements

- Windows 10 or 11
- Windows PowerShell 5.1 (built in) or PowerShell 7+
- An internet connection the first time, to download yt-dlp, FFmpeg and [Deno](https://deno.com/) (the app offers to do this for you)

### Run it

1. Download or clone this repository.
2. Double-click **`Cybtek Downloader.cmd`**.
   Or, from a terminal:
   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\CybtekDler-v1.6.0.ps1
   ```
3. When it asks to install yt-dlp, FFmpeg and Deno, click **Yes**.
4. Copy a link, then click **Download Video** or **Download Audio**.

> If Windows blocks the script because it was downloaded from the internet, right-click it, open **Properties**, and tick
> **Unblock**, or run `Unblock-File .\CybtekDler-v1.6.0.ps1`.

### Repository contents

| File | What it is |
|---|---|
| `CybtekDler-v1.6.0.ps1` | The whole app. The version is in the file name (`CybtekDler-vMAJOR.MINOR.PATCH.ps1`); it downloads its splash image on first run |
| `Cybtek Downloader.cmd` | Double-click launcher. It runs the newest `CybtekDler-v*.ps1` in the folder, so it never needs changing when you update |
| `Cybtek-Downloader.png` | The splash image, also the window icon and help-page banner. The app downloads it from this repo on first run if it isn't already next to the script; replace it to use your own artwork |
| `Addons/Sign-In.ps1` | Addon: log in to a site in a built-in browser so sign-in-only downloads work (see [Included addons](#included-addons)) |
| `Addons/Color-Schemes.ps1` | Addon: seven colour schemes for the app, plus your own custom ones (see [Included addons](#included-addons)) |
| `Addons/Get-Metadata.ps1` | Addon: looks up movie, TV show, song or book details for each download (see [Included addons](#included-addons)) |
| `Addons/NotifyWhenDone.ps1` | A sample addon that shows a Windows notification when a download finishes |
| `addon.txt` | A ready-made prompt to paste into an AI chat to have it write an addon for you |

### Where things are stored

| | |
|---|---|
| Settings | `%APPDATA%\CybtekDownloader\settings.json` |
| yt-dlp, FFmpeg and Deno | `%APPDATA%\CybtekDownloader\bin` |
| Addons | `%APPDATA%\CybtekDownloader\addons` |
| Logs | `%APPDATA%\CybtekDownloader\logs` |
| Dependency backups | `%APPDATA%\CybtekDownloader\archive` |
| Downloads | `Videos\Cybtek Downloader` and `Music\Cybtek Downloader` (change them in Settings) |

---

## How it works

The app is a WinForms window written in PowerShell. It doesn't download anything itself: it builds the right yt-dlp command
line from your settings, runs it, and turns yt-dlp's output into a progress bar.

```
 You copy a link ──► clipboard watcher ──► URL box
                                              │
 Settings (JSON) ──► Get-DownloadArguments ───┤
                                              ▼
                     yt-dlp.exe  ──(uses)──►  ffmpeg.exe
                         │  stdout/stderr
                         ▼
        background reader (C#) ──► queue ──► UI timer ──► progress bar, status, Activity window, log file
```

How it was put together:

- **Pure PowerShell + WinForms.** Windows already has everything needed, so the app is one `.ps1` file with no installer.
  It relaunches itself in STA mode when needed, because WinForms and the clipboard require it.
- **A non-blocking UI.** yt-dlp runs as a child process. A small C# class (compiled at start-up with `Add-Type`) reads its
  output on background threads into a thread-safe queue, and a WinForms timer drains that queue on the UI thread.
  PowerShell script blocks are never called from a background thread, which is the usual cause of PowerShell GUIs freezing or crashing.
- **Progress parsing.** yt-dlp runs with `--newline`, so every progress update is its own line. A regular expression picks
  out the percentage, size, speed and time left. Lines such as `[Merger]`, `[ExtractAudio]` and `[SplitChapters]` switch the bar to "working" mode.
- **Smart format selection.** Video uses `-f "bv*+ba/b"` with yt-dlp's format sorting (`-S res:1080,fps:30,vcodec:h264,ext:mp4:m4a`)
  rather than hard filters. You get the best match under your limits, or the closest available when a site has nothing smaller.
- **Dependency management.** Versions are read from `yt-dlp --version` and `ffmpeg -version`, and the latest releases come
  from the GitHub API (`yt-dlp/yt-dlp` and `yt-dlp/FFmpeg-Builds`). FFmpeg comes as daily builds, so it counts as out of date
  once it is more than 30 days older than the newest build. Updates download with a progress bar, and the current versions can be zipped first.
- **Custom theme.** A small C# menu renderer and a custom progress bar give the dark navy and electric-blue look. Windows' DWM API is used for the dark title bar.
- **Addons.** At start-up the app runs each `.ps1` in the addons folder and keeps the hashtable it returns. The app then calls that hashtable's script blocks at set points.

---

## Included addons

These ship in the `Addons` folder and **install automatically the first time you open the app** (see
[Bundled addons](#bundled-addons-auto-install)). You can also install any `.ps1` by hand with **Addons > Install Addon...**.

### Sign-In

Fixes downloads that fail with *"Sign in to confirm you're not a bot"* or that need an account. Once installed it adds a
**Sign In** menu to the menu bar (after **Addons**). Open it, pick a site, and log in — including 2FA — in a built-in browser
window. Click **Use this login** and the addon saves the browser's cookies to a `cookies.txt` and points Cybtek Downloader at
it, so yt-dlp can use your session.

- **Start-up reminder:** while this addon is installed, the app shows a short reminder at start-up to sign in via the Sign In
  menu. Untick **Show this reminder each time Cybtek Downloader starts** to stop it; turn it back on from **Addons > Sign In**.
- Works for **YouTube, TikTok, Instagram, Twitter/X, Twitch, Facebook, Reddit, Vimeo, Dailymotion, Bilibili, SoundCloud,
  Bandcamp**, and any other site via **Other site…**.
- The login happens in **Microsoft WebView2**, an embedded browser on your own PC. The first time, the app offers to download
  it (the runtime, if your Windows doesn't already have it, plus a ~10 MB component). Nothing is sent anywhere by the addon —
  cookies are written only to the addon's own folder.
- **Clear saved login** signs out and deletes the saved cookies and browser profile.
- This is cleaner than reading cookies from Chrome/Edge: there's no file lock to work around and no browser to close. The one
  catch is that Google sometimes refuses sign-in inside an embedded browser; if that happens, the Firefox or cookies.txt options
  on the Sources tab still work.

### Color Schemes

Changes the colours of the whole app. It comes with seven schemes:

| Scheme | Look |
|---|---|
| Cybtek Blue | The standard dark navy and electric blue |
| Metro Dark | Charcoal with Windows Metro cyan |
| Metro Light | White and light grey with Windows blue (the only light scheme) |
| Midnight Purple | Deep purple with violet highlights |
| Emerald Forest | Dark green with emerald highlights |
| Sunset Orange | Dark brown with orange highlights |
| Crimson Night | Dark red with crimson highlights |

- **First install:** a window opens so you can pick a scheme. The app changes as you click, and a preview shows the colours.
- **Changing it later:** click **Addons > Color Scheme** and choose from the pop-out list. The current scheme has a tick.
- **Your own scheme:** **Create Custom...** at the bottom of that list opens an editor. Name your scheme, start from any existing
  one, click a colour box to change it (or type a value like `#1E90FF`), and click **Preview** to see it on the app. **Save** stores it
  and adds it to the list.
- **Where schemes are kept:** each scheme is a `.json` file in the `color-schemes` folder next to the addon
  (`%APPDATA%\CybtekDownloader\addons\color-schemes`). Copy a file there to share a scheme, or delete one you no longer want.
- Uninstalling the addon puts the standard colours back the next time the app starts.

### Get-Metadata

After every download, Get-Metadata looks the title up online and shows what it finds in a popup: cover art or a poster, the
details and a description, with buttons to open the web page or copy the details.

| Download | What it looks for | Where it looks |
|---|---|---|
| Video | Movies and TV shows | [Wikipedia](https://www.wikipedia.org/) (movies), [TVmaze](https://www.tvmaze.com/api) (TV shows) |
| Audio | Songs and books | [iTunes Search API](https://performance-partners.apple.com/search-api) (songs), [Open Library](https://openlibrary.org/developers/api) (books) |

- It works out the title from the downloaded file name and removes clutter such as "(Official Video)", "[1080p]", "S01E01" and "Lyrics".
  For "Artist - Title" names it also tries each side on its own.
- The lookup runs in the background, so the app never freezes. The popup usually appears a few seconds after the download finishes.
- Several matches are listed, best first. Click one to see its details.
- Click **Get-Metadata** on the Addons menu to look up any title by hand.
- Only the title is sent to these services. They are free and need no account or API key.

### Notify When Done

Shows a Windows notification when a download finishes, so you can leave the app in the background. Click it on the Addons
menu to see a test notification.

---

## Writing an addon

An addon is a PowerShell script that adds behaviour to the app.

<a id="bundled-addons-auto-install"></a>
**The addon directory is the `Addons` folder next to the script.** The app creates it on startup, and every `.ps1`
in it is loaded automatically when the app opens — that is how the included addons arrive. Drop an addon in there (or use
**Addons > Install Addon...**, which copies the file into that folder) and it's active next launch; delete a file from the folder
to remove the addon. If that folder can't be written (for example a read-only location), the app uses
`%APPDATA%\CybtekDownloader\addons` instead.

> **Want an AI to write one for you?** Open [`addon.txt`](addon.txt), copy all of it into an AI chat, and describe the addon
> you want at the bottom. The rest of this section is for writing one yourself.

### What you need to know

- **PowerShell basics:** script blocks (`{ ... }`), hashtables (`@{ }`), `param(...)`.
- **A little WinForms** if you want to show windows or notifications. `System.Windows.Forms` and `System.Drawing` are already loaded.
- **The yt-dlp command-line options** if your addon changes how downloads run. See the [yt-dlp README](https://github.com/yt-dlp/yt-dlp#usage-and-options).

### The addon contract

An addon file must **return a hashtable** as its last output. Every key is optional except `Name`:

```powershell
@{
    Name        = 'My Addon'                 # shown on the Addons menu
    Version     = '1.0'                      # shown next to the name
    Author      = 'Your name'
    Description = 'One sentence on what it does.'   # tooltip on the Addons menu

    OnLoad             = { param($App, $Self) }  # once, when the app starts or the addon is installed
    OnDownloadStarting = { param($Info) }        # before each download; return a string to add yt-dlp arguments
    OnDownloadComplete = { param($Info) }        # after each download (successful, failed or cancelled)
    MenuAction         = { param($App) }         # when the user clicks the addon on the Addons menu

    MenuText           = 'My Addon'              # the text on the Addons menu (default: name and version)
    BuildMenu          = { param($App, $Menu) }  # gives the addon a pop-out submenu instead of MenuAction

    TopMenuText        = 'My Menu'               # adds a top-level menu to the menu bar (after Addons) while installed
    TopMenuBuild       = { param($App, $Menu) }  # fills that top-level menu's dropdown each time it opens
}
```

- If there is no `MenuAction` or `BuildMenu`, clicking the addon shows its name, version, author, description and file path.
- **`TopMenuText` + `TopMenuBuild`** add a menu of the addon's own to the menu bar, right after **Addons**, that appears only
  while the addon is installed (that is how the Sign-In addon adds its **Sign In** menu). `TopMenuBuild` fills its dropdown
  just like `BuildMenu`.
- **`$Self`** (second argument to `OnLoad`) has `Name`, `File` and `Folder`. Use `$Self.Folder` for files your addon keeps
  next to itself (the Color Schemes addon keeps its schemes in `$Self.Folder\color-schemes`).
- **`BuildMenu`** runs every time the submenu opens. `$Menu` is the addon's `ToolStripMenuItem`; add items to `$Menu.DropDownItems`:

  ```powershell
  BuildMenu = {
      param($App, $Menu)
      $item = New-Object System.Windows.Forms.ToolStripMenuItem 'Say hello'
      $item.add_Click({ [System.Windows.Forms.MessageBox]::Show('Hello') })
      [void]$Menu.DropDownItems.Add($item)
  }
  ```

### What the app passes in

**`$App`** (passed to `OnLoad`, `MenuAction` and `BuildMenu`):

| Member | Type | Use |
|---|---|---|
| `$App.Form` | `System.Windows.Forms.Form` | The main window. Use it as the owner for your own dialogs |
| `$App.Settings` | ordered dictionary | The live settings (`VideoDir`, `AudioDir`, `AudioFormat`, `VideoContainer`, ...). Read them freely; changes take effect at once but are only saved if the user later saves Settings |
| `$App.Log` | script block | Writes a line to the Activity window and the log file: `& $App.Log 'Hello'` |
| `$App.SetStatus` | script block | Sets the status line under the progress bar: `& $App.SetStatus 'Working...'` |
| `$App.GetColors` | script block | The current colours as `#RRGGBB` values, plus `Light`: `$c = & $App.GetColors` |
| `$App.SetColors` | script block | Switches the whole app to new colours and repaints every open window: `& $App.SetColors @{ Back = '#101010'; Accent = '#FF8800' }`. Colours you leave out stay as they are. Set `Light = $true` for dark text on a light background |
| `$App.ColorNames` | string array | The colours a scheme can set: `Back`, `Panel`, `Input`, `Hover`, `Border`, `Accent`, `AccentLight`, `Text`, `Muted`, `Disabled`, `Good`, `Warn`, `Bad` |
| `$App.SaveSettings` | script block | Saves the settings to disk so your changes persist: `& $App.SaveSettings`. (Changing `$App.Settings` alone only lasts the session.) |
| `$App.EnsureWebView2` | script block | Makes sure the embedded browser (Microsoft WebView2) is installed, asking the user to download it if needed, and returns its folder (or `$null`). Load `Microsoft.Web.WebView2.Core.dll` from there. The Sign-In addon uses this |
| `$App.AppVersion` | string | The app version (e.g. `1.6.0`). Check it with `[version]$App.AppVersion -ge [version]'1.6.0'` when your addon needs a newer feature |

**`$Info`** (passed to `OnDownloadStarting` and `OnDownloadComplete`):

| Property | Example | Notes |
|---|---|---|
| `Url` | `https://www.youtube.com/watch?v=...` | The link being downloaded |
| `Mode` | `Video` or `Audio` | Which button was clicked |
| `Source` | `YouTube`, `TikTok`, `Other site`, ... | The source selected on the Source menu |
| `Folder` | `C:\Users\you\Music\Cybtek Downloader` | The download folder |
| `Success` | `$true` / `$false` | Only meaningful in `OnDownloadComplete` |
| `ExitCode` | `0` | yt-dlp's exit code. Only in `OnDownloadComplete` |

### Rules and tips

1. **Return extra yt-dlp arguments as a string** from `OnDownloadStarting`, for example `'--write-description'`. They are
   added before the URL. Quote paths yourself: `'--download-archive "C:\My Folder\history.txt"'`. Return nothing to leave the command alone.
2. **Hooks run on the UI thread.** Anything slow (web requests, big file copies) freezes the window. Use `Start-Job`, `Start-Process`,
   or a `System.Windows.Forms.Timer` for longer work.
3. **Errors are caught.** If your hook throws, the app writes the error to the Activity window and carries on. Open
   **File > Activity** when testing.
4. **Use `$App` instead of the app's internal functions.** You *can* call internal functions such as `Write-Activity`, but they may change between versions.
   `$App` is only passed to `OnLoad` and `MenuAction`. To use it in a download hook, save it in `OnLoad` under a name unique to your addon
   (`$script:MyAddon_App = $App`) and read it back in the hook. Prefix all your `$script:` variables like this, because addons share that space with the app.
5. **The exact file name isn't passed in.** To act on the downloaded file, look for the newest file in `$Info.Folder`, for example
   `Get-ChildItem $Info.Folder -File | Sort-Object LastWriteTime | Select-Object -Last 1`.
6. **Keep the file ASCII, or save it as UTF-8 *with* BOM.** Windows PowerShell 5.1 misreads UTF-8 files without a BOM that contain accented letters or symbols.
7. **Test in both PowerShell 5.1 and 7** if you plan to share your addon.
8. **Uninstalling** moves the file to the Recycle Bin. Anything your addon changed while running (timers, event handlers, settings) stays until the app restarts.
9. **Be trustworthy.** Addons run with the user's full permissions. Don't send data anywhere without saying so in your `Description`.

### Example: open the folder when a download finishes

```powershell
# OpenFolderWhenDone.ps1
@{
    Name        = 'Open Folder When Done'
    Version     = '1.0'
    Author      = 'Your name'
    Description = 'Opens the download folder in Explorer after each successful download.'

    OnDownloadComplete = {
        param($Info)
        if ($Info.Success) { Start-Process explorer.exe -ArgumentList "`"$($Info.Folder)`"" }
    }
}
```

### Example: add yt-dlp options for one site

```powershell
# TikTokExtras.ps1
@{
    Name        = 'TikTok Extras'
    Version     = '1.0'
    Description = 'Saves the description and info JSON next to TikTok downloads.'

    OnDownloadStarting = {
        param($Info)
        if ($Info.Source -eq 'TikTok') { '--write-description --write-info-json' }
    }
}
```

See [`Addons/NotifyWhenDone.ps1`](Addons/NotifyWhenDone.ps1) for an addon that uses both `OnDownloadComplete` and `MenuAction`.

### Testing your addon

1. Run the app from a terminal so you can see any errors:
   `powershell -NoProfile -ExecutionPolicy Bypass -File .\CybtekDler-v1.6.0.ps1`
2. Use **Addons > Install Addon...** to install your file. If it doesn't return a valid hashtable, the app tells you why and doesn't install it.
3. Run a download and watch **File > Activity**.
4. To update your addon, install it again. The app asks to replace the old copy.

---

## Troubleshooting

| Problem | Try this |
|---|---|
| A download that used to work now fails | Help > Update Dependencies. Sites change often and yt-dlp keeps up |
| YouTube says "Sign in to confirm you're not a bot" | Settings > Sources > *Use login cookies from* your browser (Firefox works best) |
| YouTube formats are missing or there's a JavaScript runtime warning | Check the status line says the dependencies are installed. Deno is one of them; use Help > Install Dependencies if it is missing |
| MP3 conversion or merging fails | Check that the status line says the dependencies are installed |
| Anything else | File > Activity > Copy all, and look for lines starting with `ERROR` |

## Credits

- **[yt-dlp](https://github.com/yt-dlp/yt-dlp)** does all the downloading.
- **[FFmpeg](https://ffmpeg.org/)** (Windows builds from [yt-dlp/FFmpeg-Builds](https://github.com/yt-dlp/FFmpeg-Builds)) does the converting, merging and splitting.
- **[SponsorBlock](https://sponsor.ajay.app/)** provides the community segment data.

Cybtek Downloader does not include either program. It downloads them from their official GitHub releases when you ask it to,
and they stay under their own licences.

## Please download responsibly

Only download content you have the right to download, and respect each site's terms of service and the creators whose work you save.
