# Get-Metadata - an addon for Cybtek Downloader.
#
# After each download it looks the title up online and shows what it finds in a popup:
#   - Video downloads: movies (Wikipedia) and TV shows (TVmaze)
#   - Audio downloads: songs (iTunes Search) and books (Open Library)
# Click Get-Metadata on the Addons menu to look up any title by hand.
#
# Only the title is sent to these services. They are free and need no account or API key.
# Install: Addons > Install Addon... in Cybtek Downloader, then choose this file.

@{
    Name        = 'Get-Metadata'
    Version     = '1.0'
    Author      = 'Cybtek Downloader'
    Description = 'After a download, finds matching movies and TV shows (video) or songs and books (audio) and shows their details. Sends the title to Wikipedia, TVmaze, iTunes and Open Library. Click to look up a title by hand.'

    OnLoad = {
        param($App)
        $script:GetMetadata_App = $App
        $script:GetMetadata_Started = $null

        # The lookup runs in a background runspace so the window never freezes. That runspace
        # starts empty, so everything the lookup needs is inside this script block.
        # $Queries is the cleaned title first, then simpler versions to try if it finds nothing.
        $script:GetMetadata_Lookup = {
            param([string[]]$Queries, [string]$Mode)
            $ErrorActionPreference = 'Stop'
            $ProgressPreference = 'SilentlyContinue'
            [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
            $headers = @{ 'User-Agent' = 'CybtekDownloader-GetMetadata/1.0' }
            $found = New-Object System.Collections.Generic.List[object]
            $problems = New-Object System.Collections.Generic.List[string]
            $seen = @{}

            # One entry per kind + title + artist/author (the same song is often on several albums)
            function Add-Match([hashtable]$m) {
                $key = ('{0}|{1}|{2}' -f $m.Kind, $m.Title, $m.Creator).ToLowerInvariant()
                if ($seen.ContainsKey($key)) { return }
                $seen[$key] = $true
                $item = [pscustomobject]@{
                    Kind = ''; Title = ''; Year = ''; Creator = ''; Genre = ''; Length = ''; Rating = ''; Extra = ''
                    Description = ''; Link = ''; Image = ''; Source = ''; ImageBytes = $null; Score = 0; Order = $found.Count
                }
                foreach ($k in $m.Keys) { if ($null -ne $m[$k]) { $item.$k = [string]$m[$k] } }
                $found.Add($item)
            }
            function Get-Year($date) { if ($date) { try { return [string]([datetime]$date).Year } catch { } } '' }
            function Format-Duration($ms, [switch]$Minutes) {
                if (-not $ms) { return '' }
                $t = [TimeSpan]::FromMilliseconds([double]$ms)
                if ($Minutes) { '{0} min' -f [int]$t.TotalMinutes } else { '{0}:{1:00}' -f [int][Math]::Floor($t.TotalMinutes), $t.Seconds }
            }
            # Read replies as UTF-8 ourselves: Windows PowerShell 5.1 guesses wrong when a service
            # doesn't name its encoding, which garbles accented and non-Latin text
            function Get-Json($url) {
                $resp = Invoke-WebRequest -Uri $url -Headers $headers -TimeoutSec 15 -UseBasicParsing
                [System.Text.Encoding]::UTF8.GetString($resp.RawContentStream.ToArray()) | ConvertFrom-Json
            }
            function Get-Words($s) { (("$s".ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() -split ' ') | Where-Object { $_ } }

            $Query = ''
            foreach ($candidate in $Queries) {
                if (-not $candidate) { continue }
                $Query = $candidate
                $q = [uri]::EscapeDataString($Query)
                if ($Mode -eq 'Video') {
                    # Movies come from Wikipedia: pages whose short description reads like "2010 film by Christopher Nolan"
                    try {
                        $search = [uri]::EscapeDataString("$Query film")
                        $r = Get-Json ("https://en.wikipedia.org/w/api.php?action=query&format=json&formatversion=2&generator=search&gsrsearch=$search" +
                            '&gsrlimit=8&prop=description|extracts|pageimages&exintro=1&explaintext=1&exsentences=4&piprop=thumbnail&pithumbsize=500&pilicense=any')
                        foreach ($p in @($r.query.pages | Sort-Object index)) {
                            $desc = "$($p.description)"
                            if ($desc -notmatch '^(\d{4})\b(.*?)\bfilm\b(?:\s+by\s+(.+))?') { continue }
                            $year = $Matches[1]
                            $director = "$($Matches[3])".Trim()
                            $genre = "$($Matches[2])".Trim()
                            # The first sentence usually names the genre more fully: "is a 2010 science fiction heist film"
                            $extract = ("$($p.extract)" -replace '[ \t]{2,}', ' ').Trim()
                            if ($extract -match '\bis an? (?:\d{4} )?(?:American |British )?(.+?) film\b') { $genre = $Matches[1].Trim() }
                            Add-Match @{ Kind = 'Movie'; Title = ($p.title -replace '\s*\((?:\d{4} )?(?:[\w ]+ )?film\)$', ''); Year = $year
                                Creator = $director; Genre = $genre; Description = $extract
                                Link = ('https://en.wikipedia.org/wiki/' + [uri]::EscapeDataString(($p.title -replace ' ', '_')))
                                Image = $(if ($p.thumbnail) { $p.thumbnail.source } else { '' }); Source = 'Wikipedia' }
                            if (@($found | Where-Object { $_.Kind -eq 'Movie' }).Count -ge 5) { break }
                        }
                    } catch { $problems.Add("Wikipedia (movies): $($_.Exception.Message)") }
                    try {
                        $r = Get-Json "https://api.tvmaze.com/search/shows?q=$q"
                        foreach ($hit in @($r | Select-Object -First 5)) {
                            $s = $hit.show
                            $network = if ($s.network) { $s.network.name } elseif ($s.webChannel) { $s.webChannel.name } else { '' }
                            $runtime = if ($s.runtime) { $s.runtime } else { $s.averageRuntime }
                            $summary = if ($s.summary) { [System.Net.WebUtility]::HtmlDecode(($s.summary -replace '<[^>]+>', '')).Trim() } else { '' }
                            Add-Match @{ Kind = 'TV show'; Title = $s.name; Year = (Get-Year $s.premiered); Creator = $network
                                Genre = (@($s.genres) -join ', '); Length = $(if ($runtime) { "$runtime min per episode" } else { '' })
                                Rating = $(if ($s.rating.average) { "$($s.rating.average) / 10" } else { '' }); Extra = "Status: $($s.status)"
                                Description = $summary; Link = $s.url; Image = $(if ($s.image) { $s.image.medium } else { '' }); Source = 'TVmaze' }
                        }
                    } catch { $problems.Add("TVmaze (TV shows): $($_.Exception.Message)") }
                } else {
                    try {
                        $r = Get-Json "https://itunes.apple.com/search?media=music&entity=song&limit=6&term=$q"
                        foreach ($m in @($r.results)) {
                            $track = if ($m.trackNumber) { "Track $($m.trackNumber) of $($m.trackCount) on '$($m.collectionName)'" } else { '' }
                            Add-Match @{ Kind = 'Song'; Title = $m.trackName; Year = (Get-Year $m.releaseDate); Creator = $m.artistName
                                Genre = $m.primaryGenreName; Length = (Format-Duration $m.trackTimeMillis); Extra = "Album: $($m.collectionName)"
                                Description = $track; Link = $m.trackViewUrl; Image = ("$($m.artworkUrl100)" -replace '100x100', '600x600'); Source = 'iTunes' }
                        }
                    } catch { $problems.Add("iTunes (songs): $($_.Exception.Message)") }
                    try {
                        $fields = 'key,title,author_name,first_publish_year,subject,cover_i,number_of_pages_median,publisher,first_sentence'
                        $r = Get-Json "https://openlibrary.org/search.json?limit=5&fields=$fields&q=$q"
                        foreach ($b in @($r.docs)) {
                            $publisher = (@($b.publisher) | Select-Object -First 2) -join ', '
                            $first = @($b.first_sentence) | Select-Object -First 1
                            Add-Match @{ Kind = 'Book'; Title = $b.title; Year = $b.first_publish_year; Creator = (@($b.author_name) -join ', ')
                                Genre = ((@($b.subject) | Select-Object -First 4) -join ', ')
                                Length = $(if ($b.number_of_pages_median) { "$($b.number_of_pages_median) pages" } else { '' })
                                Extra = $(if ($publisher) { "Publisher: $publisher" } else { '' })
                                Description = $(if ($first) { "First sentence: $first" } else { '' })
                                Link = "https://openlibrary.org$($b.key)"
                                Image = $(if ($b.cover_i) { "https://covers.openlibrary.org/b/id/$($b.cover_i)-M.jpg" } else { '' }); Source = 'Open Library' }
                        }
                    } catch { $problems.Add("Open Library (books): $($_.Exception.Message)") }
                }
                if ($found.Count) { break }
            }

            # Best matches first: exact title, then titles found in the search text, then shared words
            $queryWords = @(Get-Words $Query)
            $queryText = ' ' + ($queryWords -join ' ') + ' '
            foreach ($m in $found) {
                $titleWords = @(Get-Words $m.Title)
                $titleText = ' ' + ($titleWords -join ' ') + ' '
                $score = 0
                if ($titleText -eq $queryText) { $score += 100 }
                elseif ($titleWords.Count -and $queryText.Contains($titleText)) { $score += 60 }
                elseif ($queryWords.Count -and $titleText.Contains($queryText)) { $score += 40 }
                $score += 5 * @($titleWords | Where-Object { $queryWords -contains $_ }).Count
                $creatorText = ' ' + (@(Get-Words $m.Creator) -join ' ') + ' '
                if ($creatorText.Trim() -and $queryText.Contains($creatorText)) { $score += 25 }
                $m.Score = $score
            }
            # Ties keep each service's own ranking
            $sorted = @($found | Sort-Object -Property @{ Expression = 'Score'; Descending = $true }, @{ Expression = 'Order'; Descending = $false })

            # Cover art for the first few matches
            foreach ($m in @($sorted | Select-Object -First 8)) {
                if (-not $m.Image) { continue }
                try {
                    $resp = Invoke-WebRequest -Uri $m.Image -UseBasicParsing -TimeoutSec 10 -Headers $headers
                    $m.ImageBytes = $resp.RawContentStream.ToArray()
                } catch { }
            }

            [pscustomobject]@{ Results = $sorted; Problems = @($problems); Query = $Query }
        }

        # Turns a downloaded file name into something a search engine will understand
        function script:GetMetadata_CleanTitle([string]$Name) {
            $t = $Name
            # yt-dlp swaps characters Windows doesn't allow in file names for look-alikes; undo that
            $t = $t.Replace([string][char]0xFF5C, '|').Replace([string][char]0xFF1A, ':').Replace([string][char]0xFF1F, ' ')
            $t = $t.Replace([string][char]0xFF02, ' ').Replace([string][char]0x29F8, ' ').Replace([string][char]0xFF0A, ' ')
            $t = ($t -split '\|')[0]
            $t = $t -replace '\[[^\]]*\]|\([^\)]*\)|\{[^\}]*\}', ' '
            $t = $t -replace '(?i)\b(official\s+(music\s+)?video|official\s+audio|official\s+trailer|official|lyric\s+video|lyrics?|music\s+video|full\s+movie|full\s+album|full\s+episode|audio|visuali[sz]er|trailer|teaser|hd|hq|4k|8k|2160p|1080p|720p|remaster(ed)?|audiobook|unabridged)\b', ' '
            $t = $t -replace '(?i)\bS\d{1,2}\s*E\d{1,3}\b|\bseason\s+\d+\b|\bepisode\s+\d+\b|\bep\.?\s*\d+\b', ' '
            $t = $t -replace '\s+-\s+', ' ' -replace '_+', ' ' -replace '\s{2,}', ' '
            $t = $t.Trim(" -:,.'`"".ToCharArray())
            if ($t) { $t } else { $Name }
        }

        # Searches to try for a file name, best first. "Artist - Title" names also try each side,
        # because a movie database won't know the artist and a music database may not need it.
        function script:GetMetadata_Queries([string]$Name) {
            $list = @(GetMetadata_CleanTitle $Name)
            $plain = ($Name.Replace([string][char]0xFF5C, '|') -split '\|')[0]
            $parts = @($plain -split '\s+-\s+' | Where-Object { $_.Trim() })
            if ($parts.Count -ge 2) {
                $list += GetMetadata_CleanTitle ($parts[1..($parts.Count - 1)] -join ' - ')
                $list += GetMetadata_CleanTitle $parts[0]
            }
            @($list | Where-Object { $_ } | Select-Object -Unique)
        }

        # Starts a background lookup and shows the popup when it finishes
        function script:GetMetadata_Start([string[]]$Queries, [string]$Mode) {
            $Queries = @($Queries | Where-Object { $_ })
            if (-not $Queries) { return }
            & $script:GetMetadata_App.Log "Get-Metadata: looking up '$($Queries[0])' ($(if ($Mode -eq 'Audio') { 'songs and books' } else { 'movies and TV shows' }))."
            $ps = [powershell]::Create()
            [void]$ps.AddScript($script:GetMetadata_Lookup.ToString()).AddArgument([string[]]$Queries).AddArgument($Mode)
            $timer = New-Object System.Windows.Forms.Timer -Property @{ Interval = 250 }
            $timer.Tag = @{ PS = $ps; Handle = $ps.BeginInvoke(); Query = $Queries[0]; Mode = $Mode }
            $timer.add_Tick({
                $job = $this.Tag
                if (-not $job.Handle.IsCompleted) { return }
                $this.Stop()
                $out = $null
                $problems = @()
                try { $out = @($job.PS.EndInvoke($job.Handle)) | Select-Object -Last 1 }
                catch { $problems = @("Lookup failed: $($_.Exception.Message)") }
                $job.PS.Dispose()
                $this.Dispose()
                $results = @()
                $query = $job.Query
                if ($out) {
                    $results = @($out.Results); $problems = @($out.Problems)
                    if ($results.Count -and $out.Query) { $query = $out.Query }
                }
                & $script:GetMetadata_App.Log "Get-Metadata: found $($results.Count) match(es) for '$query'."
                foreach ($p in $problems) { & $script:GetMetadata_App.Log "Get-Metadata: $p" }
                GetMetadata_ShowResults $query $job.Mode $results $problems
            })
            $timer.Start()
        }

        # Fills the details side of the popup for the selected match
        function script:GetMetadata_Render($State) {
            $i = $State.List.SelectedIndex
            if ($i -lt 0) { return }
            $m = $State.Results[$i]
            $who = switch ($m.Kind) { 'Movie' { 'Director' } 'TV show' { 'Network' } 'Song' { 'Artist' } 'Book' { 'Author' } default { 'By' } }
            $State.Title.Text = $m.Title
            $State.Sub.Text = (@($m.Kind, $m.Year, $m.Creator) | Where-Object { $_ }) -join '   |   '
            $lines = @()
            if ($m.Creator) { $lines += "${who}:  $($m.Creator)" }
            if ($m.Year)    { $lines += "Year:  $($m.Year)" }
            if ($m.Genre)   { $lines += "$(if ($m.Kind -eq 'Book') { 'Subjects' } else { 'Genre' }):  $($m.Genre)" }
            if ($m.Length)  { $lines += "Length:  $($m.Length)" }
            if ($m.Rating)  { $lines += "Rating:  $($m.Rating)" }
            if ($m.Extra)   { $lines += $m.Extra }
            $lines += "Source:  $($m.Source)"
            $State.Details.Text = $lines -join "`r`n"
            $State.Description.Text = if ($m.Description) { $m.Description } else { '(No description available.)' }
            $old = $State.Picture.Image
            $State.Picture.Image = $null
            if ($old) { $old.Dispose() }
            if ($m.ImageBytes) {
                try { $State.Picture.Image = [System.Drawing.Image]::FromStream((New-Object System.IO.MemoryStream(, [byte[]]$m.ImageBytes))) } catch { }
            }
            $State.Open.Enabled = $m.Link -match '^https://'
        }

        # The popup. It uses the app's colours when they are available.
        function script:GetMetadata_ShowResults([string]$Query, [string]$Mode, $Results, $Problems) {
            $themed = [bool]('CyColors' -as [type])
            $back   = if ($themed) { [CyColors]::Back }        else { [System.Drawing.SystemColors]::Window }
            $panel  = if ($themed) { [CyColors]::Panel }       else { [System.Drawing.SystemColors]::Control }
            $input  = if ($themed) { [CyColors]::Input }       else { [System.Drawing.SystemColors]::Window }
            $text   = if ($themed) { [CyColors]::Text }        else { [System.Drawing.SystemColors]::WindowText }
            $muted  = if ($themed) { [CyColors]::Muted }       else { [System.Drawing.SystemColors]::GrayText }
            $accent = if ($themed) { [CyColors]::AccentLight } else { [System.Drawing.SystemColors]::HotTrack }
            $owner = $script:GetMetadata_App.Form
            $what = if ($Mode -eq 'Audio') { 'songs and books' } else { 'movies and TV shows' }

            $f = New-Object System.Windows.Forms.Form -Property @{
                Text = "Get-Metadata - $Query"; ClientSize = (New-Object System.Drawing.Size(780, 480))
                MinimumSize = (New-Object System.Drawing.Size(620, 400)); StartPosition = 'Manual'; ShowInTaskbar = $false
                BackColor = $back; ForeColor = $text; Font = (New-Object System.Drawing.Font('Segoe UI', 9))
            }
            if ($owner -and $owner.Icon) { $f.Icon = $owner.Icon }
            if ('CyNative' -as [type]) { $f.add_HandleCreated({ [CyNative]::UseDarkTitleBar($this.Handle) }) }
            if ($owner) {
                $x = $owner.Left + [int](($owner.Width - $f.Width) / 2)
                $y = $owner.Top + [int](($owner.Height - $f.Height) / 2)
                $f.Location = New-Object System.Drawing.Point([Math]::Max(0, $x), [Math]::Max(0, $y))
            }

            $header = New-Object System.Windows.Forms.Label -Property @{
                Dock = 'Top'; Height = 34; TextAlign = 'MiddleLeft'; BackColor = $panel; ForeColor = $accent
                Padding = (New-Object System.Windows.Forms.Padding(10, 0, 10, 0)); Font = (New-Object System.Drawing.Font('Segoe UI Semibold', 10))
                Text = "$(@($Results).Count) $(if (@($Results).Count -eq 1) { 'match' } else { 'matches' }) for '$Query'  -  $what"
            }

            $bottom = New-Object System.Windows.Forms.FlowLayoutPanel -Property @{
                Dock = 'Bottom'; Height = 44; FlowDirection = 'RightToLeft'; BackColor = $panel
                Padding = (New-Object System.Windows.Forms.Padding(6))
            }
            $newButton = {
                param($label, $width)
                $b = New-Object System.Windows.Forms.Button -Property @{ Text = $label; Width = $width; Height = 28; ForeColor = $text }
                if ($themed) {
                    $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false; $b.BackColor = [CyColors]::Hover
                    $b.FlatAppearance.BorderColor = [CyColors]::Border
                } else { $b.ForeColor = [System.Drawing.SystemColors]::ControlText }
                $b
            }
            $btnClose = & $newButton 'Close' 90
            $btnCopy  = & $newButton 'Copy details' 110
            $btnOpen  = & $newButton 'Open web page' 120
            $btnClose.add_Click({ $this.FindForm().Close() })
            $bottom.Controls.AddRange(@($btnClose, $btnCopy, $btnOpen))

            if (-not @($Results).Count) {
                $msg = "No $what were found for '$Query'."
                if (@($Problems).Count) { $msg += "`r`n`r`nProblems:`r`n" + (@($Problems) -join "`r`n") }
                $msg += "`r`n`r`nTip: click Get-Metadata on the Addons menu to search with a different title."
                $none = New-Object System.Windows.Forms.Label -Property @{
                    Dock = 'Fill'; Text = $msg; ForeColor = $text; Padding = (New-Object System.Windows.Forms.Padding(16))
                }
                $btnCopy.Visible = $false
                $btnOpen.Visible = $false
                $f.Controls.Add($none)
                $f.Controls.Add($header)
                $f.Controls.Add($bottom)
                $f.Show($owner)
                return
            }

            $list = New-Object System.Windows.Forms.ListBox -Property @{
                Dock = 'Left'; Width = 250; BackColor = $input; ForeColor = $text; BorderStyle = 'None'
                IntegralHeight = $false; Font = (New-Object System.Drawing.Font('Segoe UI', 9.5))
            }
            foreach ($m in $Results) {
                $label = "$($m.Kind):  $($m.Title)"
                if ($m.Year) { $label += "  ($($m.Year))" }
                [void]$list.Items.Add($label)
            }

            # The details panel gets its final size before its children are anchored to it
            $right = New-Object System.Windows.Forms.Panel -Property @{ Dock = 'Fill'; Size = (New-Object System.Drawing.Size(530, 402)); BackColor = $back }
            $pic = New-Object System.Windows.Forms.PictureBox -Property @{
                Location = (New-Object System.Drawing.Point(14, 12)); Size = (New-Object System.Drawing.Size(160, 230))
                SizeMode = 'Zoom'; BackColor = $panel
            }
            $lblTitle = New-Object System.Windows.Forms.Label -Property @{
                Location = (New-Object System.Drawing.Point(188, 10)); Size = (New-Object System.Drawing.Size(328, 54)); Anchor = 'Top, Left, Right'
                Font = (New-Object System.Drawing.Font('Segoe UI Semibold', 14)); ForeColor = $accent; AutoEllipsis = $true
            }
            $lblSub = New-Object System.Windows.Forms.Label -Property @{
                Location = (New-Object System.Drawing.Point(190, 66)); Size = (New-Object System.Drawing.Size(326, 20)); Anchor = 'Top, Left, Right'
                ForeColor = $muted; AutoEllipsis = $true
            }
            $txtDetails = New-Object System.Windows.Forms.TextBox -Property @{
                Location = (New-Object System.Drawing.Point(190, 94)); Size = (New-Object System.Drawing.Size(326, 148)); Anchor = 'Top, Left, Right'
                Multiline = $true; ReadOnly = $true; BorderStyle = 'None'; BackColor = $back; ForeColor = $text; ScrollBars = 'Vertical'
            }
            $txtDesc = New-Object System.Windows.Forms.TextBox -Property @{
                Location = (New-Object System.Drawing.Point(14, 254)); Size = (New-Object System.Drawing.Size(502, 136)); Anchor = 'Top, Bottom, Left, Right'
                Multiline = $true; ReadOnly = $true; BorderStyle = 'FixedSingle'; BackColor = $input; ForeColor = $text; ScrollBars = 'Vertical'
            }
            $right.Controls.AddRange(@($pic, $lblTitle, $lblSub, $txtDetails, $txtDesc))

            # Docking runs from the last-added control: fill area first, header and buttons last
            $f.Controls.Add($right)
            $f.Controls.Add($list)
            $f.Controls.Add($header)
            $f.Controls.Add($bottom)

            # Event handlers run after this function returns, so they find everything through the form's Tag
            $f.Tag = @{
                Results = @($Results); List = $list; Picture = $pic; Title = $lblTitle; Sub = $lblSub
                Details = $txtDetails; Description = $txtDesc; Open = $btnOpen
            }
            $list.add_SelectedIndexChanged({ GetMetadata_Render $this.FindForm().Tag })
            $btnOpen.add_Click({
                $state = $this.FindForm().Tag
                $m = $state.Results[$state.List.SelectedIndex]
                if ($m.Link -match '^https://') { Start-Process $m.Link }
            })
            $btnCopy.add_Click({
                $state = $this.FindForm().Tag
                $all = "$($state.Title.Text)`r`n$($state.Sub.Text)`r`n`r`n$($state.Details.Text)`r`n`r`n$($state.Description.Text)"
                [System.Windows.Forms.Clipboard]::SetText($all)
            })
            $f.add_FormClosed({ $p = $this.Tag.Picture; if ($p.Image) { $p.Image.Dispose() } })

            $list.SelectedIndex = 0
            $f.Show($owner)
            $f.Activate()
        }

        # Addons menu: look up any title by hand
        function script:GetMetadata_ShowSearch {
            $themed = [bool]('CyColors' -as [type])
            $dlg = New-Object System.Windows.Forms.Form -Property @{
                Text = 'Get-Metadata'; ClientSize = (New-Object System.Drawing.Size(420, 170)); StartPosition = 'CenterParent'
                FormBorderStyle = 'FixedDialog'; MaximizeBox = $false; MinimizeBox = $false; ShowInTaskbar = $false
                Font = (New-Object System.Drawing.Font('Segoe UI', 9))
            }
            $lbl = New-Object System.Windows.Forms.Label -Property @{ Text = 'Title to look up:'; Location = (New-Object System.Drawing.Point(12, 14)); AutoSize = $true }
            $txt = New-Object System.Windows.Forms.TextBox -Property @{ Location = (New-Object System.Drawing.Point(12, 36)); Width = 396 }
            $rbVideo = New-Object System.Windows.Forms.RadioButton -Property @{ Text = 'Movies and TV shows'; Location = (New-Object System.Drawing.Point(12, 70)); AutoSize = $true; Checked = $true }
            $rbAudio = New-Object System.Windows.Forms.RadioButton -Property @{ Text = 'Songs and books'; Location = (New-Object System.Drawing.Point(200, 70)); AutoSize = $true }
            $ok = New-Object System.Windows.Forms.Button -Property @{ Text = 'Search'; Location = (New-Object System.Drawing.Point(238, 126)); Width = 80; DialogResult = 'OK' }
            $cancel = New-Object System.Windows.Forms.Button -Property @{ Text = 'Cancel'; Location = (New-Object System.Drawing.Point(328, 126)); Width = 80; DialogResult = 'Cancel' }
            $dlg.Controls.AddRange(@($lbl, $txt, $rbVideo, $rbAudio, $ok, $cancel))
            $dlg.AcceptButton = $ok
            $dlg.CancelButton = $cancel
            if ($themed) {
                $dlg.BackColor = [CyColors]::Back
                foreach ($c in $dlg.Controls) { $c.ForeColor = [CyColors]::Text }
                $txt.BackColor = [CyColors]::Input
                $txt.BorderStyle = 'FixedSingle'
                foreach ($b in @($ok, $cancel)) {
                    $b.FlatStyle = 'Flat'; $b.UseVisualStyleBackColor = $false; $b.BackColor = [CyColors]::Hover
                    $b.FlatAppearance.BorderColor = [CyColors]::Border
                }
                if ('CyNative' -as [type]) { $dlg.add_HandleCreated({ [CyNative]::UseDarkTitleBar($this.Handle) }) }
            }
            if ($script:GetMetadata_App.Form.Icon) { $dlg.Icon = $script:GetMetadata_App.Form.Icon }
            $result = $dlg.ShowDialog($script:GetMetadata_App.Form)
            $query = $txt.Text.Trim()
            $mode = if ($rbAudio.Checked) { 'Audio' } else { 'Video' }
            $dlg.Dispose()
            if ($result -eq 'OK' -and $query) { GetMetadata_Start $query $mode }
        }
    }

    OnDownloadStarting = {
        param($Info)
        $script:GetMetadata_Started = Get-Date
    }

    OnDownloadComplete = {
        param($Info)
        if (-not $Info.Success -or -not $Info.Folder -or -not (Test-Path -LiteralPath $Info.Folder)) { return }

        # Find the file that was just downloaded: the newest video or audio file in the download
        # folder (or one folder down, for chapter files and subfolder templates)
        $since = if ($script:GetMetadata_Started) { $script:GetMetadata_Started.AddSeconds(-5) } else { (Get-Date).AddMinutes(-30) }
        $extensions = if ($Info.Mode -eq 'Audio') { @('.mp3', '.m4a', '.opus', '.ogg', '.flac', '.wav') } else { @('.mp4', '.mkv', '.webm', '.mov') }
        $file = Get-ChildItem -LiteralPath $Info.Folder -File -Recurse -Depth 1 -ErrorAction SilentlyContinue |
            Where-Object { $extensions -contains $_.Extension.ToLowerInvariant() -and $_.LastWriteTime -ge $since } |
            Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if (-not $file) {
            & $script:GetMetadata_App.Log 'Get-Metadata: no new file was found, so nothing was looked up.'
            return
        }

        # Chapter files are named "01 - Chapter title" inside a folder named after the video
        $name = if ($file.BaseName -match '^\d{2,3} - ') { $file.Directory.Name } else { $file.BaseName }
        GetMetadata_Start (GetMetadata_Queries $name) $Info.Mode
    }

    MenuAction = {
        param($App)
        GetMetadata_ShowSearch
    }
}