# tools/pipeline/build-manifest.ps1
#
# Step 1 of the curation pipeline (doc/ARCHITECTURE.md 8): read doc/SEED-LIST.md,
# resolve each title on AnimeThemes, apply the fixed variant-selection precedence,
# and emit pipeline/manifest.json for the transcode job to consume.
#
# Nothing here downloads media or touches the database. Safe to re-run: the manifest
# is a pure function of SEED-LIST + current AnimeThemes state.
#
# Selection precedence (doc/RESEARCH.md 4.8, non-negotiable):
#   1. nc = true          MANDATORY. A credited video burns the title logo into frame.
#   2. subbed = false     subtitles can carry a translated title.
#   3. overlap = NONE     preferred over TRANS / OVER.
#   4. smallest size      final tie-break only.
# A theme with no nc:true variant is EXCLUDED and reported, never used with a warning.
# Verified live: kuroko_no_basket has nc=false on every non-spoiler variant and is
# correctly dropped. Credit-free availability -- not popularity -- is the real limit
# on launch content.
#
# Entry filter: nsfw = false and spoiler = false.
#
# Slug resolution is three-tier, because AnimeThemes slugs are romaji-derived while
# SEED-LIST sometimes carries an English title in its Romaji column:
#   1. explicit override in tools/pipeline/slug-overrides.json
#   2. derived slug   (lowercase romaji, non-alphanumerics -> '_', trailing "(2011)" dropped)
#   3. search(search:) fallback, disambiguated by SEED-LIST year
# Tier 3 matters: search("Steins;Gate") returns steinsgate_0 (2018) ahead of steinsgate
# (2011), and search("Blue Exorcist") returns three sequels ahead of the 2011 parent.
# Year match, then exact-title match, then shortest slug (parent over sequel) picks
# correctly. Every item records which tier resolved it.
#
# Rate limit: AnimeThemes allows 90 req/min (doc/RESEARCH.md 4.3); throttled below that.

[CmdletBinding()]
param(
  [string]$SeedList,
  [string]$OutFile,
  [string]$Overrides,
  [int]   $MaxThemesPerAnime = 4,
  [int]   $ThrottleMs = 750
)

$ErrorActionPreference = 'Stop'

# $PSScriptRoot is not populated inside param() defaults under -File on PS 5.1,
# so paths are resolved here instead.
$root = Split-Path -Parent $PSScriptRoot            # tools/
$repo = Split-Path -Parent $root                    # repo root
if (-not $SeedList)  { $SeedList  = Join-Path $repo 'doc\SEED-LIST.md' }
if (-not $OutFile)   { $OutFile   = Join-Path $repo 'pipeline\manifest.json' }
if (-not $Overrides) { $Overrides = Join-Path $PSScriptRoot 'slug-overrides.json' }

$endpoint = 'https://graphql.animethemes.moe/'
$tmpDir   = Join-Path $repo '.tmp'
if (-not (Test-Path -LiteralPath $tmpDir)) { New-Item -ItemType Directory -Path $tmpDir -Force | Out-Null }
$tmpBody  = Join-Path $tmpDir 'at-gql-body.json'
$tmpResp  = Join-Path $tmpDir 'at-gql-resp.json'

$utf8NoBom = New-Object System.Text.UTF8Encoding($false)

# U+00D7 MULTIPLICATION SIGN as an escape so this file stays pure ASCII. A literal
# breaks silently: this script is saved UTF-8 without BOM, PS 5.1 parses .ps1 as ANSI
# absent a BOM, and the mismatched byte stops matching -- which is exactly how
# "Hunter (times) Hunter" first derived as hunter_hunter instead of hunter_x_hunter.
$times = [char]0x00D7

# ---------------------------------------------------------------- seed parsing --
# Table columns: | # | Romaji | English | Native | Year | Format |
$rows = @()
foreach ($line in Get-Content -LiteralPath $SeedList -Encoding UTF8) {
  if ($line -notmatch '^\|\s*\d+\s*\|') { continue }
  $c = $line.Trim('|').Split('|') | ForEach-Object { $_.Trim() }
  if ($c.Count -lt 6) { continue }
  $rows += [pscustomobject]@{
    Rank    = [int]$c[0]
    Romaji  = $c[1]
    English = $c[2]
    Native  = $c[3]
    Year    = [int]($c[4] -replace '\D', '')
    Format  = $c[5]
  }
}
Write-Host "seed rows parsed: $($rows.Count)"
if ($rows.Count -eq 0) { throw 'no seed rows parsed -- has the SEED-LIST table shape changed?' }

$overrideMap = @{}
if (Test-Path -LiteralPath $Overrides) {
  (Get-Content -LiteralPath $Overrides -Raw -Encoding UTF8 | ConvertFrom-Json).PSObject.Properties |
    ForEach-Object { $overrideMap[$_.Name] = $_.Value }
}

function Get-Slug([string]$title) {
  $s = $title -replace '\s*\(\d{4}\)\s*$', ''       # drop "(2011)" disambiguation suffix
  $s = $s.Replace($times, 'x')                      # Hunter x Hunter, Spy x Family
  $s = $s.ToLowerInvariant()
  $s = $s -replace '[^a-z0-9]+', '_'
  $s.Trim('_')
}

function Normalize-Title([string]$t) {
  if (-not $t) { return '' }
  ($t.Replace($times, 'x').ToLowerInvariant() -replace '[^a-z0-9]', '')
}

# ------------------------------------------------------------------- transport --
# Responses are written to a file and read back as explicit UTF-8. Capturing curl's
# stdout would decode through [Console]::OutputEncoding (IBM437 on a default Windows
# console) and risks mangling native Japanese titles bound for question_titles.
function Invoke-Gql([string]$queryText, [hashtable]$vars) {
  $payload = @{ query = $queryText; variables = $vars } | ConvertTo-Json -Compress -Depth 6
  [System.IO.File]::WriteAllText($tmpBody, $payload, $utf8NoBom)
  for ($attempt = 1; $attempt -le 3; $attempt++) {
    & curl.exe -sS --max-time 30 -X POST $endpoint `
        -H 'Content-Type: application/json' --data-binary "@$tmpBody" -o $tmpResp 2>$null
    $text = if (Test-Path -LiteralPath $tmpResp) {
      [System.IO.File]::ReadAllText($tmpResp, [System.Text.Encoding]::UTF8)
    } else { '' }
    if ($text -match 'Too Many Attempts') { Start-Sleep -Seconds 60; continue }
    if (-not $text) { Start-Sleep -Seconds 3; continue }
    try { $j = $text | ConvertFrom-Json } catch { Start-Sleep -Seconds 3; continue }
    if ($j.errors) { throw "GraphQL error: $($j.errors[0].message)" }
    return $j.data
  }
  throw 'AnimeThemes unreachable after 3 attempts'
}

$animeQuery = 'query($slug:String!){ anime(slug:$slug){ slug year season format ' +
  'title{romaji english native} synonyms{text} animethemes{ slug type sequence ' +
  'animethemeentries{ nsfw spoiler version videos{ nodes{ basename resolution size ' +
  'nc subbed overlap source link } } } } } }'

$searchQuery = 'query($s:String!){ search(search:$s, first:10){ anime{ slug year format ' +
  'title{romaji english} } } }'

function Get-Anime([string]$slug) { (Invoke-Gql $animeQuery @{ slug = $slug }).anime }

# Ranks search hits against the seed row: year match first (separates steinsgate from
# steinsgate_0), then exact title match, then format, then shortest slug (parent
# franchise over sequels, matching the SEED-LIST parent-franchise rule).
function Resolve-BySearch($row) {
  $fallback = $null
  foreach ($term in @($row.Romaji, $row.English) | Select-Object -Unique) {
    if (-not $term) { continue }
    $hits = (Invoke-Gql $searchQuery @{ s = $term }).search.anime
    Start-Sleep -Milliseconds $ThrottleMs
    if (-not $hits) { continue }
    $wantR = Normalize-Title $row.Romaji
    $wantE = Normalize-Title $row.English
    $best = $hits | Sort-Object `
      @{ Expression = { if ([int]$_.year -eq $row.Year) { 0 } else { 1 } } },
      @{ Expression = { $n = Normalize-Title $_.title.romaji
                        $m = Normalize-Title $_.title.english
                        if ($n -eq $wantR -or $m -eq $wantE -or $n -eq $wantE -or $m -eq $wantR) { 0 } else { 1 } } },
      @{ Expression = { if ($_.format -eq $row.Format) { 0 } else { 1 } } },
      @{ Expression = { $_.slug.Length } } | Select-Object -First 1
    if ($best -and [int]$best.year -eq $row.Year) { return $best.slug }
    if ($best -and -not $fallback) { $fallback = $best.slug }
  }
  return $fallback
}

function Select-Variant($videos) {
  $safe = $videos | Where-Object { $_.nc -eq $true -and $_.subbed -eq $false }
  if (-not $safe) { return $null }
  $safe | Sort-Object `
    @{ Expression = { if ("$($_.overlap)".ToUpperInvariant() -eq 'NONE') { 0 } else { 1 } } },
    @{ Expression = { [int64]$_.size } } | Select-Object -First 1
}

# ------------------------------------------------------------------ difficulty --
# question_bank.difficulty is a smallint 1-5 we compute at ingest (doc/DATA-MODEL.md 5).
# ARCHITECTURE 8.3 records that AnimeThemes exposes no popularity field and that the
# documented proxies (year / OP-ED / sequence / format) do not measure *recognisability*,
# which is what difficulty means to a player.
#
# SEED-LIST supplies the missing signal: its rank IS a recognisability ordering. Rank is
# therefore the base band and the documented proxies act as modifiers. The formula stays
# deliberately simple and is recomputable by backfill if playtesting moves it
# (doc/GAME-DESIGN.md 8 keeps weighting open).
function Get-Difficulty($row, $theme) {
  $d = [Math]::Ceiling($row.Rank / 10.0)          # rank 1-10 -> 1 ... 41-50 -> 5
  if ($theme.theme_type -eq 'ED')       { $d += 1 }   # endings are markedly harder
  if ([int]$theme.theme_sequence -ge 3) { $d += 1 }   # deep-cut later openings
  if ($row.Format -ne 'TV')             { $d += 1 }   # OVA/ONA/MOVIE less seen
  if ([int]$row.Year -lt 2000)          { $d += 1 }   # pre-2000 classics
  [int][Math]::Max(1, [Math]::Min(5, $d))
}

# -------------------------------------------------------------------- build ----
$items    = @()
$excluded = @()
$i = 0
foreach ($row in $rows) {
  $i++
  Write-Host ("[{0,2}/{1}] {2,-42}" -f $i, $rows.Count, $row.Romaji) -NoNewline

  $resolvedBy = 'derived'
  if ($overrideMap.ContainsKey($row.Romaji)) { $slug = $overrideMap[$row.Romaji]; $resolvedBy = 'override' }
  else { $slug = Get-Slug $row.Romaji }

  $anime = $null
  try { $anime = Get-Anime $slug }
  catch {
    Write-Host " query failed: $_"
    $excluded += [pscustomobject]@{ romaji = $row.Romaji; slug = $slug; reason = "query failed: $_" }
    continue
  }

  if (-not $anime) {
    Start-Sleep -Milliseconds $ThrottleMs
    $found = $null
    try { $found = Resolve-BySearch $row } catch { }
    if ($found) {
      $slug = $found
      $resolvedBy = 'search'
      try { $anime = Get-Anime $slug } catch { $anime = $null }
    }
  }

  if (-not $anime) {
    Write-Host ' NOT FOUND (derived slug and search both failed)'
    $excluded += [pscustomobject]@{ romaji = $row.Romaji; slug = $slug; reason = 'not found on AnimeThemes by derived slug or search' }
    Start-Sleep -Milliseconds $ThrottleMs
    continue
  }

  $themes = @()
  foreach ($t in $anime.animethemes) {
    if ($t.type -notin @('OP', 'ED')) { continue }
    foreach ($e in $t.animethemeentries) {
      if ($e.nsfw -eq $true -or $e.spoiler -eq $true) { continue }
      $chosen = Select-Variant $e.videos.nodes
      if (-not $chosen) { continue }
      $themes += [pscustomobject]@{
        theme_type     = $t.type
        theme_sequence = $t.sequence
        entry_version  = $e.version
        basename       = $chosen.basename
        link           = $chosen.link
        resolution     = $chosen.resolution
        size_bytes     = [int64]$chosen.size
        overlap        = $chosen.overlap
        source         = $chosen.source
        variants_seen  = @($e.videos.nodes).Count
        # Carried through as the API reported them, NOT asserted downstream. The
        # question_bank CHECK constraints (credit_free_only, not_subbed, sfw_only) exist
        # so an unsafe clip cannot be inserted "even by a buggy ingest run" (migration
        # 0003). If the workflow hardcoded nc=true instead of forwarding these, those
        # constraints would be checking a literal and could never fire -- the tripwire
        # would be wired to nothing. Select-Variant already guarantees the values, so
        # recording them costs nothing and keeps the guarantee auditable end to end.
        nc             = [bool]$chosen.nc
        subbed         = [bool]$chosen.subbed
        spoiler        = [bool]$e.spoiler
        nsfw           = [bool]$e.nsfw
      }
      break   # one entry per theme is enough
    }
  }

  # Cap themes per anime. Without this the bank is franchise-skewed: naruto_shippuuden
  # alone yields 59 themes, bleach 36, gintama 28, so a random draw would keep landing
  # on the same handful of answers. Capping trades bank size (which is already far past
  # what a 20-round game needs) for answer variety, and cuts CI source downloads from
  # ~10.7 GB to ~5.5 GB. OPs first, then lowest sequence: the most recognisable themes.
  #
  # The @() is load-bearing. Select-Object -First returns a BARE OBJECT when exactly one
  # item survives, not a one-element array, and PS 5.1 gives $null for .Count on a bare
  # PSCustomObject. That silently undercounted the six single-theme anime: the manifest
  # reported 130 themes while actually holding 136, and the per-anime progress line
  # printed "-- theme(s)" with a blank number. Never let a pipeline result reach a
  # .Count without @() around it.
  $themes = @($themes | Sort-Object `
    @{ Expression = { if ($_.theme_type -eq 'OP') { 0 } else { 1 } } },
    @{ Expression = { [int]$_.theme_sequence } } |
    Select-Object -First $MaxThemesPerAnime)

  foreach ($t in $themes) {
    $t | Add-Member -NotePropertyName difficulty -NotePropertyValue (Get-Difficulty $row $t) -Force
  }

  if ($themes.Count -eq 0) {
    Write-Host (" slug={0} NO CREDIT-FREE VARIANT" -f $anime.slug)
    $excluded += [pscustomobject]@{ romaji = $row.Romaji; slug = $anime.slug; reason = 'no nc:true/subbed:false variant on any non-spoiler OP/ED entry' }
    Start-Sleep -Milliseconds $ThrottleMs
    continue
  }

  Write-Host (" slug={0} via {1} -- {2} theme(s)" -f $anime.slug, $resolvedBy, $themes.Count)
  $items += [pscustomobject]@{
    rank          = $row.Rank
    slug          = $anime.slug
    resolved_by   = $resolvedBy
    title_romaji  = if ($anime.title.romaji)  { $anime.title.romaji }  else { $row.Romaji }
    title_english = if ($anime.title.english) { $anime.title.english } else { $row.English }
    title_native  = if ($anime.title.native)  { $anime.title.native }  else { $row.Native }
    synonyms      = @($anime.synonyms.text)
    year          = if ($anime.year)   { $anime.year }   else { $row.Year }
    season        = $anime.season
    format        = if ($anime.format) { $anime.format } else { $row.Format }
    themes        = $themes
  }
  Start-Sleep -Milliseconds $ThrottleMs
}

$manifest = [pscustomobject]@{
  generated_at    = (Get-Date).ToUniversalTime().ToString('o')
  source          = 'AnimeThemes GraphQL (https://graphql.animethemes.moe/)'
  selection_rule  = 'nc=true mandatory; subbed=false; overlap NONE preferred; then smallest size'
  cap_per_anime   = $MaxThemesPerAnime
  difficulty_rule = 'base = ceil(seed rank / 10); +1 each for ED, sequence>=3, non-TV format, year<2000; clamped 1-5'
  seed_rows       = $rows.Count
  item_count      = $items.Count
  theme_count     = ($items | ForEach-Object { @($_.themes).Count } | Measure-Object -Sum).Sum
  items           = $items
  excluded        = $excluded
}

$outDir = Split-Path -Parent $OutFile
if (-not (Test-Path -LiteralPath $outDir)) { New-Item -ItemType Directory -Path $outDir -Force | Out-Null }
[System.IO.File]::WriteAllText($OutFile, ($manifest | ConvertTo-Json -Depth 8), $utf8NoBom)

$totalMB = [Math]::Round((($items | ForEach-Object { $_.themes } | ForEach-Object { $_.size_bytes } | Measure-Object -Sum).Sum / 1MB), 1)
Write-Host ''
Write-Host "manifest: $OutFile"
Write-Host ("items {0}/{1} | themes {2} | excluded {3} | source bytes {4} MB" -f `
  $manifest.item_count, $rows.Count, $manifest.theme_count, $excluded.Count, $totalMB)
Write-Host 'difficulty spread:'
$items | ForEach-Object { $_.themes } | Group-Object difficulty | Sort-Object Name |
  ForEach-Object { "  d{0}: {1}" -f $_.Name, $_.Count }
