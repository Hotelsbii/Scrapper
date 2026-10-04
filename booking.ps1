# Fonctions de lecture Booking.com (utilisées par serveur.ps1, dans une tâche de fond)
# Nécessite : $sync (table partagée avec le serveur) et $Dossier.

$Inv    = [Globalization.CultureInfo]::InvariantCulture
$Devise = 'EUR'
$UA = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36 Edg/129.0.0.0'
$script:Jeton = ''; $script:Sess = $null

function Log($t) {
  try { Add-Content -Path (Join-Path $Dossier 'journal.txt') -Value ("{0}  {1}" -f (Get-Date).ToString('yyyy-MM-dd HH:mm:ss'), $t) -Encoding UTF8 } catch {}
}
function Arret { return [bool]$sync.arret }
function Attendre($sec) {
  $fin = (Get-Date).AddSeconds($sec)
  while ((Get-Date) -lt $fin -and -not (Arret)) { Start-Sleep -Milliseconds 100 }
}

# ---------------- Navigateur invisible ----------------
function Trouver-Navigateur {
  if ($env:RELEVE_NAVIGATEUR -and (Test-Path $env:RELEVE_NAVIGATEUR)) { return $env:RELEVE_NAVIGATEUR }
  $pf86 = [Environment]::GetEnvironmentVariable('ProgramFiles(x86)')
  $liste = @(
    "$pf86\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe",
    "$env:LOCALAPPDATA\Microsoft\Edge\Application\msedge.exe",
    "$env:ProgramFiles\Google\Chrome\Application\chrome.exe",
    "$pf86\Google\Chrome\Application\chrome.exe",
    "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe"
  )
  foreach ($p in $liste) { if ($p -and (Test-Path $p)) { return $p } }
  return $null
}

function Demarrer-Edge($url, $poste, $budget) {
  if (-not $budget) { $budget = 15000 }
  $nav = Trouver-Navigateur
  if (-not $nav) { throw 'Microsoft Edge est introuvable sur ce PC.' }
  $tmp = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
  $profil = Join-Path $tmp ('releve-booking-profil' + $(if ($poste) { "-$poste" } else { '' }))
  $arg = @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check',
           '--disk-cache-size=1048576', '--media-cache-size=1048576', '--blink-settings=imagesEnabled=false',
           '--disable-extensions', '--disable-component-update', '--disable-background-networking',
           '--lang=fr-FR', "--user-data-dir=`"$profil`"", "--user-agent=`"$UA`"",
           '--window-size=1366,3000', "--virtual-time-budget=$budget", '--dump-dom', "`"$url`"") -join ' '
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nav; $psi.Arguments = $arg
  $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $psi.StandardOutputEncoding = [Text.Encoding]::UTF8
  $p = [Diagnostics.Process]::Start($psi)
  $out = $p.StandardOutput.ReadToEndAsync()
  $null = $p.StandardError.ReadToEndAsync()
  return [pscustomobject]@{ p = $p; out = $out; debut = (Get-Date) }
}

function Lire-Page($url) {
  $t = Demarrer-Edge $url 0
  while (-not $t.p.HasExited) {
    Start-Sleep -Milliseconds 100
    if ((Arret) -or ((Get-Date) - $t.debut).TotalSeconds -gt 120) {
      try { $t.p.Kill() } catch {}
      if (Arret) { throw 'Recherche arrêtée.' } else { throw 'Booking ne répond pas (délai dépassé).' }
    }
  }
  while (-not $t.out.IsCompleted) { Start-Sleep -Milliseconds 50 }
  return $t.out.Result
}

# Lit plusieurs pages en même temps ($n navigateurs invisibles). $surPage reçoit (index, html).
function Lire-Pages($urls, $n, $surPage, $budget) {
  $file = New-Object System.Collections.Queue
  for ($i = 0; $i -lt $urls.Count; $i++) { $file.Enqueue($i) }
  $actifs = @{}
  while ($file.Count -gt 0 -or $actifs.Count -gt 0) {
    if (Arret) { foreach ($t in $actifs.Values) { try { $t.p.Kill() } catch {} }; throw 'Comparaison arrêtée.' }
    for ($poste = 1; $poste -le $n; $poste++) {
      if (-not $actifs.ContainsKey($poste) -and $file.Count -gt 0) {
        $i = $file.Dequeue(); $t = Demarrer-Edge $urls[$i] $poste $budget
        $t | Add-Member -NotePropertyName i -NotePropertyValue $i
        $actifs[$poste] = $t
      }
    }
    foreach ($poste in @($actifs.Keys)) {
      $t = $actifs[$poste]
      if ($t.p.HasExited -and $t.out.IsCompleted) { $actifs.Remove($poste); & $surPage $t.i $t.out.Result }
      elseif (((Get-Date) - $t.debut).TotalSeconds -gt 120) { try { $t.p.Kill() } catch {}; $actifs.Remove($poste); & $surPage $t.i '' }
    }
    Start-Sleep -Milliseconds 150
  }
}

# ---------------- Lecture des pages ----------------
function Nettoyer($s) {
  if ($null -eq $s) { return '' }
  $s = $s -replace '<[^>]+>', ' '
  $s = [System.Net.WebUtility]::HtmlDecode($s)
  return ($s -replace '[\s  ]+', ' ').Trim()
}
function Extraire($texte, $motif) {
  $m = [regex]::Match($texte, $motif, 'Singleline')
  if ($m.Success) { return Nettoyer $m.Groups[1].Value } else { return '' }
}
function En-Nombre($s) {
  $ms = [regex]::Matches("$s", '\d[\d .,  ]*')
  if ($ms.Count -eq 0) { return $null }
  $v = ($ms[$ms.Count - 1].Value -replace '[   ]', '').TrimEnd('.', ',')
  $dec = ''
  $m = [regex]::Match($v, '[.,](\d{1,2})$')
  if ($m.Success) { $dec = $m.Groups[1].Value; $v = $v.Substring(0, $v.Length - $m.Length) }
  $v = $v -replace '[.,]', ''
  if ($dec) { $v = "$v.$dec" }
  if ($v -eq '') { return $null }
  return [double]::Parse($v, $Inv)
}
# Prix du calendrier : Booking abrège au-delà de 1 000 € (« 1,2 k € », « €1.2K ») : on remet les milliers
function Prix-Calendrier($t) {
  $m = [regex]::Match("$t", '(\d+(?:[.,]\d+)?)\s*[kK]')
  if ($m.Success) { $v = [double]::Parse(($m.Groups[1].Value -replace ',', '.'), $Inv) * 1000; return @($v, $true) }
  return @((En-Nombre $t), $false)
}

function Lire-Offres($html) {
  $offres = @()
  $morceaux = [regex]::Split($html, 'data-testid="property-card"')
  for ($i = 1; $i -lt $morceaux.Count; $i++) {
    $k = $morceaux[$i]
    $prix = En-Nombre (Extraire $k 'data-testid="price-and-discounted-price"[^>]*>(.*?)</span>')
    $lien = ''
    $a = [regex]::Match($k, '<a\b[^>]*data-testid="title-link"[^>]*>')
    if ($a.Success) {
      $h = [regex]::Match($a.Value, 'href="([^"]+)"')
      if ($h.Success) { $lien = ([System.Net.WebUtility]::HtmlDecode($h.Groups[1].Value) -split '\?')[0] }
    }
    $note = $null
    $zone = [regex]::Match($k, 'data-testid="review-score"(.{0,800})', 'Singleline')
    if ($zone.Success) {
      $n = [regex]::Match((Nettoyer $zone.Groups[1].Value), '\b(\d{1,2}[,.]\d)\b')
      if ($n.Success) { $note = [double]::Parse(($n.Groups[1].Value -replace ',', '.'), $Inv) }
    }
    $chambre = ''
    $zu = [regex]::Match($k, 'data-testid="recommended-units"(.{0,2000})', 'Singleline')
    if ($zu.Success) { $chambre = Extraire $zu.Groups[1].Value '<h4[^>]*>(.*?)</h4>' }
    $titre = Extraire $k 'data-testid="title"[^>]*>(.*?)</div>'
    if (-not $titre) { continue }
    $offres += [pscustomobject]@{
      hotel = $titre; chambre = $chambre
      adresse = Extraire $k 'data-testid="address"[^>]*>(.*?)</span>'
      note = $note; prix = $prix; lien = $lien
    }
  }
  return $offres
}

function Simplifier($s) { (("$s".Normalize([Text.NormalizationForm]::FormD) -replace '\p{Mn}', '').ToLowerInvariant() -replace '[^a-z0-9]+', ' ').Trim() }
function Correspond($tape, $trouve) {
  $vides = @('hotel', 'the', 'les', 'des', 'and', 'paris', 'residence', 'appart')
  $mots = @((Simplifier $tape) -split ' ' | Where-Object { $_.Length -gt 2 -and $vides -notcontains $_ })
  if ($mots.Count -eq 0) { $mots = @((Simplifier $tape) -split ' ' | Where-Object { $_ }) }
  if ($mots.Count -eq 0) { return $false }
  $t = ' ' + (Simplifier $trouve) + ' '
  $ok = @($mots | Where-Object { $t.Contains(" $_ ") -or $t.Contains(" $_") }).Count
  return ($ok / $mots.Count) -ge 0.6
}

function Tls12 { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12 }

# Booking reconnaît le nom tapé (même mal orthographié), comme sa liste de suggestions
# Suggestions Booking (comme la liste qui s'affiche en tapant sur le site)
function Suggestions-Booking($nom, $taille) {
  Tls12
  $corps = @{ query = $nom; language = 'fr'; size = $taille } | ConvertTo-Json -Compress
  $rep = Invoke-WebRequest -Uri 'https://accommodations.booking.com/autocomplete.json' -Method Post -UseBasicParsing `
    -Body ([Text.Encoding]::UTF8.GetBytes($corps)) -ContentType 'application/json; charset=utf-8' `
    -Headers @{ 'Origin' = 'https://www.booking.com' } -UserAgent $UA -TimeoutSec 15
  $rep = [Text.Encoding]::UTF8.GetString($rep.RawContentStream.ToArray()) | ConvertFrom-Json
  return @($rep.results | Where-Object { $_ } | ForEach-Object {
    $libelle = if ($_.label) { "$($_.label)" } else { "$($_.value)" }
    $parts = $libelle -split ','
    [pscustomobject]@{ id = "$($_.dest_id)"; type = "$($_.dest_type)"; libelle = $libelle; nom = $parts[0].Trim(); sous = (($parts | Select-Object -Skip 1) -join ',').Trim() }
  })
}

# Booking reconnaît le nom tapé (même mal orthographié) : on garde sa première suggestion
function Resoudre-Nom($nom) {
  try {
    $res = @(Suggestions-Booking $nom 5)
    Log ('Booking propose : ' + (($res | ForEach-Object { "[$($_.type)] $($_.libelle)" }) -join ' | '))
    if ($res.Count -eq 0) { return $null }
    return $res[0]
  } catch {
    Log "Reconnaissance du nom impossible : $($_.Exception.Message)"
    return $null
  }
}

function Url-Recherche($nom, $dest, $a, $d, $adultes) {
  $u = 'https://www.booking.com/searchresults.fr.html?'
  if ($dest) { $u += 'ss=' + [uri]::EscapeDataString($dest.libelle) + '&dest_id=' + [uri]::EscapeDataString($dest.id) + '&dest_type=' + [uri]::EscapeDataString($dest.type) }
  else { $u += 'ss=' + [uri]::EscapeDataString($nom) }
  return $u + "&checkin=$($a.ToString('yyyy-MM-dd'))&checkout=$($d.ToString('yyyy-MM-dd'))&group_adults=$adultes&group_children=0&no_rooms=1&selected_currency=$Devise&lang=fr"
}

function Trouver-Jeton($html) {
  foreach ($motif in @("b_csrf_token\s*[:=]\s*'([^']+)'", 'b_csrf_token\s*[:=]\s*"([^"]+)"', '"csrfToken"\s*:\s*"([^"]+)"')) {
    $t = [regex]::Match("$html", $motif); if ($t.Success) { return $t.Groups[1].Value }
  }
  return ''
}

# Calendrier des prix Booking (dates flexibles) : prix « à partir de » pour 1 nuit, 61 jours par demande
function Calendrier-Rapide($lien, $debut, $jours, $adultes) {
  $m = [regex]::Match($lien, '/hotel/([a-z]{2})/([^/.?]+)')
  if (-not $m.Success) { throw "adresse de l'hôtel non reconnue : $lien" }
  $cc = $m.Groups[1].Value; $pagename = $m.Groups[2].Value
  Tls12
  if (-not $script:Jeton) {
    $sess = $null; $jeton = ''
    try {
      $page = Invoke-WebRequest -Uri $lien -UseBasicParsing -UserAgent $UA -SessionVariable sess -TimeoutSec 30
      $jeton = Trouver-Jeton ([Text.Encoding]::UTF8.GetString($page.RawContentStream.ToArray()))
    } catch { Log "Page de l'hôtel (accès direct) : $($_.Exception.Message)" }
    if (-not $jeton) { $jeton = Trouver-Jeton (Lire-Page $lien) }
    $script:Jeton = $jeton; $script:Sess = $sess
  }
  $jeton = $script:Jeton; $sess = $script:Sess
  Log ("Calendrier : $cc/$pagename, jeton " + $(if ($jeton) { 'trouvé' } else { 'absent' }))
  $requete = 'query AvailabilityCalendar($input: AvailabilityCalendarQueryInput!) { availabilityCalendar(input: $input) { ... on AvailabilityCalendarQueryResult { hotelId days { available avgPriceFormatted checkin minLengthOfStay __typename } __typename } ... on AvailabilityCalendarQueryError { message __typename } __typename } }'
  $resultat = @{}
  $pos = 0
  while ($pos -lt $jours) {
    if (Arret) { throw 'Comparaison arrêtée.' }
    $n = [math]::Min(61, $jours - $pos)
    $corps = @{
      operationName = 'AvailabilityCalendar'; query = $requete; extensions = @{}
      variables = @{ input = @{ travelPurpose = 2; pagenameDetails = @{ countryCode = $cc; pagename = $pagename }
        searchConfig = @{ searchConfigDate = @{ startDate = $debut.AddDays($pos).ToString('yyyy-MM-dd'); amountOfDays = $n }
          nbAdults = $adultes; nbRooms = 1; nbChildren = 0; childrenAges = @() } } }
    } | ConvertTo-Json -Depth 10 -Compress
    $entetes = @{ 'Origin' = 'https://www.booking.com' }
    if ($jeton) { $entetes['x-booking-csrf-token'] = $jeton }
    $params = @{ Uri = "https://www.booking.com/dml/graphql?lang=fr&selected_currency=$Devise"; Method = 'Post'; UseBasicParsing = $true
      UserAgent = $UA; ContentType = 'application/json'; Body = [Text.Encoding]::UTF8.GetBytes($corps); Headers = $entetes; TimeoutSec = 30 }
    if ($sess) { $params['WebSession'] = $sess }
    $r = Invoke-WebRequest @params
    $brut = [Text.Encoding]::UTF8.GetString($r.RawContentStream.ToArray())
    $j = $brut | ConvertFrom-Json
    $c = $j.data.availabilityCalendar
    if (-not $c -or -not $c.days) { throw ('réponse inattendue : ' + $brut.Substring(0, [math]::Min(300, $brut.Length))) }
    foreach ($dj in $c.days) { $resultat["$($dj.checkin)"] = $dj }
    $pos += $n
    Attendre 1
  }
  return $resultat
}

# ---------------- Accès direct (sans navigateur) : beaucoup plus rapide ----------------
function Client-Http {
  if (-not $script:Http) {
    Add-Type -AssemblyName System.Net.Http
    Tls12
    $h = New-Object System.Net.Http.HttpClientHandler
    $h.CookieContainer = New-Object System.Net.CookieContainer
    $h.AutomaticDecompression = [System.Net.DecompressionMethods]::GZip -bor [System.Net.DecompressionMethods]::Deflate
    try { $h.DefaultProxyCredentials = [System.Net.CredentialCache]::DefaultCredentials } catch {}
    $c = New-Object System.Net.Http.HttpClient($h)
    $c.Timeout = [TimeSpan]::FromSeconds(40)
    [void]$c.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent', $UA)
    [void]$c.DefaultRequestHeaders.TryAddWithoutValidation('Accept-Language', 'fr-FR,fr;q=0.9,en;q=0.6')
    [void]$c.DefaultRequestHeaders.TryAddWithoutValidation('Accept', 'text/html,application/xhtml+xml,application/xml;q=0.9,application/json;q=0.8,*/*;q=0.7')
    $script:Http = $c
  }
  return $script:Http
}

# Envoie plusieurs requêtes en parallèle ($n à la fois). $surReponse reçoit (index, texte, code HTTP).
function Http-Plusieurs($reqs, $n, $surReponse) {
  $c = Client-Http
  $file = New-Object System.Collections.Queue
  for ($i = 0; $i -lt $reqs.Count; $i++) { $file.Enqueue($i) }
  $actifs = New-Object System.Collections.ArrayList
  while ($file.Count -gt 0 -or $actifs.Count -gt 0) {
    if (Arret) { throw 'Recherche arrêtée.' }
    while ($actifs.Count -lt $n -and $file.Count -gt 0) {
      $i = $file.Dequeue(); $r = $reqs[$i]
      $methode = if ($r.corps) { [System.Net.Http.HttpMethod]::Post } else { [System.Net.Http.HttpMethod]::Get }
      $msg = New-Object System.Net.Http.HttpRequestMessage($methode, [string]$r.url)
      if ($r.corps) { $msg.Content = New-Object System.Net.Http.StringContent([string]$r.corps, [Text.Encoding]::UTF8, 'application/json') }
      if ($r.entetes) { foreach ($k in @($r.entetes.Keys)) { [void]$msg.Headers.TryAddWithoutValidation($k, [string]$r.entetes[$k]) } }
      [void]$actifs.Add(@{ i = $i; t = $c.SendAsync($msg) })
    }
    foreach ($a in @($actifs)) {
      if ($a.t.IsCompleted) {
        [void]$actifs.Remove($a)
        $texte = $null; $code = 0
        if (-not $a.t.IsFaulted -and -not $a.t.IsCanceled) {
          try { $rep = $a.t.Result; $code = [int]$rep.StatusCode; $texte = $rep.Content.ReadAsStringAsync().Result } catch {}
        }
        & $surReponse $a.i $texte $code
      }
    }
    Start-Sleep -Milliseconds 30
  }
}

function Http-Get($url) {
  $script:_rep = $null
  try { Http-Plusieurs @(@{ url = $url }) 1 { param($i, $t, $c) if ($c -ge 200 -and $c -lt 400) { $script:_rep = $t } } }
  catch { if (Arret) { throw } }
  return $script:_rep
}

# Page Booking : d'abord en accès direct, et avec le navigateur invisible seulement si besoin
function Lire-Rapide($url, $motif) {
  $h = Http-Get $url
  if ($h -and $h -match $motif) { return $h }
  Log "Accès direct insuffisant, passage par le navigateur : $url"
  return Lire-Page $url
}

function Jeton-Booking($lien) {
  if ($script:Jeton) { return $script:Jeton }
  $j = Trouver-Jeton (Http-Get $lien)
  if (-not $j) { $j = Trouver-Jeton (Lire-Page $lien) }
  $script:Jeton = $j
  return $j
}

# Calendriers de tous les hôtels en parallèle (61 jours par requête)
function Calendriers-Paralleles($hotels, $debut, $jours, $adultes, $job) {
  $requete = 'query AvailabilityCalendar($input: AvailabilityCalendarQueryInput!) { availabilityCalendar(input: $input) { ... on AvailabilityCalendarQueryResult { hotelId days { available avgPriceFormatted checkin minLengthOfStay __typename } __typename } ... on AvailabilityCalendarQueryError { message __typename } __typename } }'
  $job.message = 'Connexion à Booking…'
  $jeton = Jeton-Booking $hotels[0].lien
  $script:resCal = @{}
  $construire = {
    $reqs = @(); $meta = @()
    for ($k = 0; $k -lt $hotels.Count; $k++) {
      $m = [regex]::Match("$($hotels[$k].lien)", '/hotel/([a-z]{2})/([^/.?]+)')
      if (-not $m.Success) { continue }
      for ($pos = 0; $pos -lt $jours; $pos += 61) {
        if ($script:resCal.ContainsKey("$k-$pos")) { continue }
        $corps = @{ operationName = 'AvailabilityCalendar'; query = $requete; extensions = @{}
          variables = @{ input = @{ travelPurpose = 2; pagenameDetails = @{ countryCode = $m.Groups[1].Value; pagename = $m.Groups[2].Value }
            searchConfig = @{ searchConfigDate = @{ startDate = $debut.AddDays($pos).ToString('yyyy-MM-dd'); amountOfDays = [math]::Min(61, $jours - $pos) }
              nbAdults = $adultes; nbRooms = 1; nbChildren = 0; childrenAges = @() } } } } | ConvertTo-Json -Depth 10 -Compress
        $e = @{ 'Origin' = 'https://www.booking.com'; 'Referer' = "$($hotels[$k].lien)" }
        if ($script:Jeton) { $e['x-booking-csrf-token'] = $script:Jeton }
        $reqs += @{ url = "https://www.booking.com/dml/graphql?lang=fr&selected_currency=$Devise"; corps = $corps; entetes = $e }
        $meta += , @($k, $pos)
      }
    }
    return @{ reqs = $reqs; meta = $meta }
  }
  for ($essai = 1; $essai -le 2; $essai++) {
    $lot = & $construire
    if ($lot.reqs.Count -eq 0) { break }
    if ($essai -eq 2) { Log "Calendriers : $($lot.reqs.Count) demande(s) à refaire"; $script:Jeton = ''; [void](Jeton-Booking $hotels[0].lien) ; $lot = & $construire }
    $total = $lot.reqs.Count; $script:nbCal = 0
    Http-Plusieurs $lot.reqs 6 {
      param($i, $texte, $code)
      $script:nbCal++
      $job.progression = [math]::Round(100 * $script:nbCal / $total)
      $job.message = "Lecture des calendriers Booking : $($script:nbCal) sur $total…"
      if (-not $texte) { return }
      try {
        $c = ($texte | ConvertFrom-Json).data.availabilityCalendar
        if ($c -and $c.days) {
          $k = $lot.meta[$i][0]; $pos = $lot.meta[$i][1]
          $script:resCal["$k-$pos"] = $true
          if (-not $script:resCal.ContainsKey("h$k")) { $script:resCal["h$k"] = @{} }
          foreach ($dj in $c.days) { $script:resCal["h$k"]["$($dj.checkin)"] = $dj }
        }
      } catch {}
    }
  }
  return $script:resCal
}


# ---------------- Navigateur piloté (un seul Edge, pages lues en parallèle depuis Booking) ----------------
# Beaucoup plus rapide que d'ouvrir un navigateur par page : Edge passe les contrôles de Booking une fois,
# puis télécharge les fiches hôtel en parallèle et n'en renvoie que le tableau des chambres.
$script:JsLecture = @'
window.__releve = async function (urls, conc) {
  const out = new Array(urls.length); let k = 0;
  const net = s => (s || '').replace(/\s+/g, ' ').trim();
  const pause = ms => new Promise(r => setTimeout(r, ms));
  // Ne télécharge la page que jusqu'à la fin du tableau des chambres
  async function extrait(url) {
    for (let essai = 0; essai < 4; essai++) {
      let r;
      try { r = await fetch(url, { credentials: 'include' }); } catch (e) { await pause(1500 * (essai + 1)); continue; }
      if (r.status === 503 || r.status === 429 || r.status === 202) { try { r.body.cancel(); } catch (e) {} await pause(2000 * (essai + 1)); continue; }
      const rd = r.body.getReader(), dec = new TextDecoder(); let t = '', debut = -1;
      while (true) {
        const { done, value } = await rd.read();
        if (done) break;
        t += dec.decode(value, { stream: true });
        if (debut < 0) { const p = t.indexOf('id="hprt-table"'); if (p >= 0) debut = t.lastIndexOf('<table', p); }
        if (debut >= 0) {
          let prof = 0, i = debut, fin = -1;
          const re = /<table\b|<\/table>/g; re.lastIndex = debut;
          let m; while ((m = re.exec(t))) { prof += m[0][1] === '/' ? -1 : 1; if (prof === 0) { fin = m.index + 8; break; } }
          if (fin > 0) { try { rd.cancel(); } catch (e) {} const md = t.match(/b_checkin_date"?\s*[:=]\s*'(\d{4}-\d{2}-\d{2})'/); return { s: r.status, tab: t.slice(debut, fin), d: md ? md[1] : '' }; }
        }
      }
      return { s: r.status, tab: null, complet: /aucune disponibilit|no availability/i.test(t), n: t.length };
    }
    return { s: 503, tab: null, n: 0 };
  }
  async function une(i) {
    try {
      const x = await extrait(urls[i]);
      if (!x.tab) { out[i] = x.complet ? { c: 1 } : { e: x.s, n: x.n }; return; }
      const d = new DOMParser().parseFromString('<html><body>' + x.tab + '</body></html>', 'text/html');
      const tab = d.querySelector('#hprt-table');
      let ch = ''; const rows = [];
      tab.querySelectorAll('tbody tr').forEach(tr => {
        const n = tr.querySelector('.hprt-roomtype-icon-link'); if (n) ch = net(n.textContent);
        const p = tr.querySelector('.prco-valign-middle-helper') || tr.querySelector('.bui-price-display__value');
        if (!p || !ch) return;
        const co = tr.querySelector('.hprt-table-cell-conditions'), oc = tr.querySelector('.hprt-table-cell-occupancy');
        rows.push([ch, net(p.textContent), co ? net(co.textContent) : '', oc ? net(oc.textContent) : '']);
      });
      out[i] = { r: rows, d: x.d };
    } catch (e) { out[i] = { x: String(e) }; }
  }
  async function ouvrier() { while (k < urls.length) { const i = k++; await une(i); } }
  await Promise.all(Array.from({ length: conc }, ouvrier));
  return out;
};
'@

function Cdp-Demarrer($origine) {
  $nav = Trouver-Navigateur
  if (-not $nav) { throw 'Microsoft Edge est introuvable sur ce PC.' }
  $tmp = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
  $profil = Join-Path $tmp 'releve-booking-profil-pilote'
  $port = 0
  foreach ($pp in 9333..9350) { $l = $null; try { $l = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $pp); $l.Start(); $l.Stop(); $port = $pp; break } catch {} }
  if (-not $port) { throw 'aucun port libre pour piloter Edge' }
  $arg = @('--headless=new', '--disable-gpu', '--no-first-run', '--no-default-browser-check', "--remote-debugging-port=$port", '--remote-allow-origins=*',
           '--disk-cache-size=1048576', '--blink-settings=imagesEnabled=false', '--disable-extensions', '--lang=fr-FR',
           "--user-data-dir=`"$profil`"", "--user-agent=`"$UA`"", 'about:blank') -join ' '
  $psi = New-Object System.Diagnostics.ProcessStartInfo
  $psi.FileName = $nav; $psi.Arguments = $arg; $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
  $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
  $proc = [Diagnostics.Process]::Start($psi)
  $null = $proc.StandardOutput.ReadToEndAsync(); $null = $proc.StandardError.ReadToEndAsync()
  $ws = $null
  for ($t = 0; $t -lt 60 -and -not $ws; $t++) {
    Start-Sleep -Milliseconds 250
    try {
      $cibles = Invoke-RestMethod -Uri "http://127.0.0.1:$port/json/list" -UseBasicParsing -TimeoutSec 2
      $page = @($cibles | Where-Object { $_.type -eq 'page' })[0]
      if ($page) { $ws = $page.webSocketDebuggerUrl }
    } catch {}
  }
  if (-not $ws) { try { $proc.Kill() } catch {}; throw 'Edge piloté ne répond pas' }
  $cli = New-Object System.Net.WebSockets.ClientWebSocket
  $cli.Options.KeepAliveInterval = [TimeSpan]::FromSeconds(20)
  $cli.ConnectAsync([uri]$ws, [Threading.CancellationToken]::None).Wait()
  $script:Cdp = @{ proc = $proc; ws = $cli; id = 0 }
  [void](Cdp-Appel 'Page.navigate' @{ url = "$origine/" } 60)
  for ($t = 0; $t -lt 80; $t++) {
    Start-Sleep -Milliseconds 400
    try { if ((Cdp-Eval 'document.readyState' 5) -eq 'complete') { break } } catch {}
  }
  Attendre 2
  [void](Cdp-Eval $script:JsLecture 20)
}

function Cdp-Appel($methode, $params, $delai) {
  $c = $script:Cdp
  $c.id++; $id = $c.id
  $json = @{ id = $id; method = $methode; params = $params } | ConvertTo-Json -Depth 8 -Compress
  $b = [Text.Encoding]::UTF8.GetBytes($json)
  $c.ws.SendAsync([ArraySegment[byte]]::new($b), [System.Net.WebSockets.WebSocketMessageType]::Text, $true, [Threading.CancellationToken]::None).Wait()
  $tampon = New-Object byte[] 1048576
  $fin = (Get-Date).AddSeconds($delai)
  while ($true) {
    $ms = New-Object System.IO.MemoryStream
    do {
      $tk = $c.ws.ReceiveAsync([ArraySegment[byte]]::new($tampon), [Threading.CancellationToken]::None)
      while (-not $tk.IsCompleted) {
        Start-Sleep -Milliseconds 30
        if (Arret) { throw 'Recherche arrêtée.' }
        if ((Get-Date) -gt $fin) { throw "Edge piloté : pas de réponse à $methode" }
      }
      if ($tk.IsFaulted) { throw "Edge piloté : connexion perdue" }
      $ms.Write($tampon, 0, $tk.Result.Count)
    } while (-not $tk.Result.EndOfMessage)
    $rep = [Text.Encoding]::UTF8.GetString($ms.ToArray()) | ConvertFrom-Json
    if ($rep.id -eq $id) {
      if ($rep.error) { throw "Edge piloté : $($rep.error.message)" }
      return $rep.result
    }
  }
}
function Cdp-Eval($expr, $delai) {
  $r = Cdp-Appel 'Runtime.evaluate' @{ expression = $expr; awaitPromise = $true; returnByValue = $true } $delai
  if ($r.exceptionDetails) { throw "Edge piloté : $($r.exceptionDetails.text) $($r.exceptionDetails.exception.description)" }
  return $r.result.value
}
function Cdp-Arreter {
  if ($script:Cdp) {
    try { $script:Cdp.ws.Dispose() } catch {}
    try { $script:Cdp.proc.Kill() } catch {}
    $script:Cdp = $null
  }
}

# Convertit une ligne renvoyée par Edge en tarif (même forme que Lire-Tarifs)
function Tarifs-Depuis-Lignes($rows, $adultes, $nuits) {
  $res = @()
  foreach ($r in @($rows)) {
    $prix = En-Nombre $r[1]; if ($null -eq $prix) { continue }
    $occ = $null; $mo = [regex]::Match("$($r[3])", '(\d+)'); if ($mo.Success) { $occ = [int]$mo.Groups[1].Value }
    $sc = Simplifier $r[2]
    $res += [pscustomobject]@{ chambre = "$($r[0])"; categorie = Categorie $r[0]; occupation = $occ; prix = $prix; prix_nuit = [math]::Round($prix / $nuits, 2)
      flex = Flexibilite $r[2]; pdj = [bool]($sc -match 'petit dejeuner compris|petit dejeuner inclus|breakfast included|demi pension|pension complete'); conditions = '' }
  }
  $ok = @($res | Where-Object { $null -eq $_.occupation -or $_.occupation -ge $adultes })
  if ($ok.Count -gt 0) { $res = $ok }
  return , $res
}

# Lit une liste de fiches par lots ; $surPage reçoit (index, lignes ou $null si illisible)
function Lire-Fiches-Pilote($urls, $adultes, $surPage) {
  $origine = ([uri]$urls[0]).GetLeftPart([UriPartial]::Authority)
  Cdp-Demarrer $origine
  $script:ecartsDate = 0
  try {
    $aFaire = @(0..($urls.Count - 1))
    foreach ($tour in 1, 2, 3) {
      if ($aFaire.Count -eq 0) { break }
      $conc = @(12, 2, 1)[$tour - 1]; $pTaille = @(60, 10, 5)[$tour - 1]
      $refaire = New-Object System.Collections.ArrayList
      for ($d = 0; $d -lt $aFaire.Count; $d += $pTaille) {
        if (Arret) { throw 'Recherche arrêtée.' }
        $pIdx = @($aFaire[$d..([math]::Min($aFaire.Count, $d + $pTaille) - 1)])
        $pPart = @($pIdx | ForEach-Object { $urls[$_] })
        $js = "window.__releve(" + (ConvertTo-Json -InputObject $pPart -Compress) + ", $conc)"
        $pRes = $null
        try { $pRes = Cdp-Eval $js 300 } catch { Log "Lot $d : $($_.Exception.Message)"; if (Arret) { throw } }
        for ($j = 0; $j -lt $pPart.Count; $j++) {
          $o = if ($pRes) { $pRes[$j] } else { $null }
          $l = $null
          if ($o -and $o.c) { $l = @() }
          elseif ($o -and $o.PSObject.Properties['r']) {
            $voulu = ([regex]::Match($pPart[$j], 'checkin=(\d{4}-\d{2}-\d{2})')).Groups[1].Value
            if ($o.d -and $voulu -and $o.d -ne $voulu) {
              # Booking a renvoyé la fiche d'une autre date (session partagée) : on refait cette page seule
              $script:ecartsDate++
              if ($tour -lt 3) { [void]$refaire.Add($pIdx[$j]); continue }
            } else { $l = Tarifs-Depuis-Lignes @($o.r) $adultes 1 }
          }
          if ($null -eq $l -and -not $script:ErrLog) { $script:ErrLog = $true; Log ("Fiche non lue par le navigateur piloté : " + $(if ($o) { ($o | ConvertTo-Json -Compress -Depth 3).Substring(0, [math]::Min(300, ($o | ConvertTo-Json -Compress -Depth 3).Length)) } else { 'pas de réponse' })) }
          & $surPage $pIdx[$j] $l
        }
      }
      $aFaire = @($refaire)
    }
    if ($script:ecartsDate) { Log "Navigateur piloté : $($script:ecartsDate) fiche(s) renvoyée(s) avec une mauvaise date, relues une par une" }
  } finally { Cdp-Arreter }
}

# ---------------- Tâches lancées depuis l'application ----------------
function Tache-Recherche($p, $job) {
  $nom = "$($p.nom)".Trim()
  $a = [datetime]::ParseExact($p.arrivee, 'yyyy-MM-dd', $Inv); $d = [datetime]::ParseExact($p.depart, 'yyyy-MM-dd', $Inv)
  $adultes = [int]$p.adultes; $nuits = [math]::Max(1, ($d - $a).Days)
  $job.message = "Booking cherche « $nom »…"; $job.progression = 10
  Log "Recherche : $nom $($p.arrivee) -> $($p.depart)"
  if ($p.dest -and $p.dest.id) {
    $dest = [pscustomobject]@{ id = "$($p.dest.id)"; type = "$($p.dest.type)"; libelle = "$($p.dest.libelle)"; nom = "$($p.dest.nom)" }
  } else { $dest = Resoudre-Nom $nom }
  $url = Url-Recherche $nom $dest $a $d $adultes
  $cible = if ($dest) { $dest.nom } else { $nom }
  $job.message = "Lecture des prix sur Booking" + $(if ($dest) { " pour « $($dest.libelle) »" } else { '' }) + '…'; $job.progression = 30
  $html = Lire-Rapide $url 'data-testid="property-card"'
  $offres = @(Lire-Offres $html)
  if ($offres.Count -eq 0) {
    [IO.File]::WriteAllText((Join-Path $Dossier 'derniere_page_booking.html'), "$html", (New-Object System.Text.UTF8Encoding $true))
    Log 'Aucune offre lue. Page enregistrée : derniere_page_booking.html'
  }
  $liste = @(); $rang = 0
  foreach ($o in $offres) {
    $liste += [pscustomobject]@{
      rang = $rang; hotel = $o.hotel; chambre = $o.chambre; adresse = $o.adresse; note = $o.note; lien = $o.lien
      prix = $o.prix; prix_nuit = $(if ($null -ne $o.prix) { [math]::Round($o.prix / $nuits, 2) } else { $null })
      correspond = [bool]((Correspond $cible $o.hotel) -or (Correspond $nom $o.hotel))
    }
    $rang++
  }
  # historique
  try {
    $maintenant = (Get-Date).ToString('yyyy-MM-dd HH:mm')
    $lignes = foreach ($o in ($liste | Where-Object { $null -ne $_.prix })) {
      [pscustomobject][ordered]@{ releve_le = $maintenant; nom_recherche = $nom; recherche = $nom; arrivee = $p.arrivee; depart = $p.depart
        nuits = $nuits; adultes = $adultes; hotel = $o.hotel; chambre = $o.chambre; adresse = $o.adresse
        note = $(if ($null -ne $o.note) { $o.note.ToString('0.0') } else { '' }); prix = $o.prix.ToString($Inv)
        prix_nuit = $o.prix_nuit.ToString($Inv); devise = $Devise; lien = $o.lien }
    }
    if ($lignes) { $lignes | Export-Csv -Path (Join-Path $Dossier 'historique.csv') -Delimiter ';' -NoTypeInformation -Encoding UTF8 -Append }
  } catch { Log "Historique non enregistré : $($_.Exception.Message)" }
  $job.progression = 100
  return @{
    nom = $nom; reconnu = $(if ($dest) { $dest.libelle } else { '' }); type = $(if ($dest) { $dest.type } else { '' })
    arrivee = $p.arrivee; depart = $p.depart; nuits = $nuits; adultes = $adultes; url = $url; offres = $liste
    page_lue = [bool]($html -match 'data-testid="property-card"')
  }
}

function Tache-Compset($p, $job) {
  $debut = [datetime]::ParseExact($p.debut, 'yyyy-MM-dd', $Inv)
  $jours = [int]$p.jours; $adultes = [int]$p.adultes
  $hotels = @($p.hotels)
  Log "Comparaison : $($hotels.Count) hôtel(s), $jours jours à partir du $($p.debut)"
  $t0 = Get-Date
  $cal = $null
  try { $cal = Calendriers-Paralleles $hotels $debut $jours $adultes $job } catch { if (Arret) { throw 'Comparaison arrêtée.' }; Log "Calendriers en parallèle impossibles : $($_.Exception.Message)" }
  $sortie = @(); $k = 0
  foreach ($h in $hotels) {
    $res = $null; $erreur = ''
    if ($cal -and $cal.ContainsKey("h$k")) { $res = $cal["h$k"] }
    else {
      if (Arret) { throw 'Comparaison arrêtée.' }
      $job.message = "Lecture du calendrier de « $($h.hotel) »…"
      try { $res = Calendrier-Rapide $h.lien $debut $jours $adultes }
      catch { $erreur = $_.Exception.Message; Log "Échec $($h.hotel) : $erreur" }
    }
    $prix = New-Object System.Collections.ArrayList
    $dispo = New-Object System.Collections.ArrayList
    $arrondi = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $jours; $i++) {
      $cle = $debut.AddDays($i).ToString('yyyy-MM-dd'); $v = $null; $etat = 'inconnu'; $ap = $false
      if ($res -and $res.ContainsKey($cle)) {
        $dj = $res[$cle]
        if ($dj.available -and $dj.avgPriceFormatted) { $pc = Prix-Calendrier "$($dj.avgPriceFormatted)"; $v = $pc[0]; $ap = $pc[1]; $etat = $(if ([int]$dj.minLengthOfStay -gt 1) { "min$($dj.minLengthOfStay)" } else { 'ok' }) }
        else { $etat = 'complet' }
      }
      [void]$prix.Add($v); [void]$dispo.Add($etat); [void]$arrondi.Add($ap)
    }
    $sortie += [pscustomobject]@{ hotel = $h.hotel; lien = $h.lien; moi = [bool]$h.moi; ok = [bool]$res; erreur = $erreur; prix = $prix.ToArray(); etat = $dispo.ToArray(); arrondi = $arrondi.ToArray() }
    $k++
  }
  $job.progression = 100
  Log "Comparaison terminée : $(@($sortie | Where-Object { $_.ok }).Count)/$($hotels.Count) hôtels lus en $([math]::Round(((Get-Date) - $t0).TotalSeconds)) s"
  return @{ debut = $p.debut; jours = $jours; adultes = $adultes; hotels = $sortie; fait_le = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
}

# Retrouve la fiche Booking (adresse de la page) d'un hôtel choisi dans les suggestions
function Tache-Fiche($p, $job) {
  $dest = [pscustomobject]@{ id = "$($p.id)"; type = 'hotel'; libelle = "$($p.libelle)"; nom = "$($p.nom)" }
  $job.message = "Recherche de la fiche Booking de « $($dest.nom) »…"; $job.progression = 20
  Log "Ajout au compset : $($dest.libelle)"
  $a = (Get-Date).Date.AddDays(14)
  $html = Lire-Rapide (Url-Recherche $dest.nom $dest $a $a.AddDays(1) 2) 'data-testid="property-card"'
  $offres = @(Lire-Offres $html | Where-Object { $_.lien })
  $o = $offres | Where-Object { Correspond $dest.nom $_.hotel } | Select-Object -First 1
  if (-not $o -and $offres.Count -gt 0 -and (Simplifier $offres[0].hotel) -like "*$((Simplifier $dest.nom) -split ' ' | Select-Object -First 1)*") { $o = $offres[0] }
  if (-not $o) { throw "Impossible de trouver la fiche Booking de « $($dest.nom) ». Essayez de le chercher dans l'onglet Rechercher." }
  $job.progression = 100
  return @{ hotel = $o.hotel; adresse = $(if ($o.adresse) { $o.adresse } else { $dest.sous }); lien = $o.lien }
}

# ---------------- Tarifs détaillés (catégories de chambres, flex / non-flex) ----------------
function Url-Fiche($lien, $a, $d, $adultes) {
  return "$($lien)?checkin=$($a.ToString('yyyy-MM-dd'))&checkout=$($d.ToString('yyyy-MM-dd'))&group_adults=$adultes&group_children=0&no_rooms=1&selected_currency=$Devise&lang=fr"
}
function Categorie($nom) {
  $s = Simplifier $nom
  if ($s -match 'suite') { return 'Suite' }
  if ($s -match 'deluxe|prestige|executive|premium|luxe|signature|club|panoram') { return 'Deluxe' }
  if ($s -match 'superieur|superior|confort|comfort|privilege') { return 'Supérieure' }
  return 'Standard'
}
function Flexibilite($cond) {
  $s = Simplifier $cond
  if ($s -match 'non rembours|non refund|nonrefund') { return 'nonflex' }
  if ($s -match 'annulation gratuite|free cancellation|annulable gratuitement') { return 'flex' }
  return 'autre'
}
# Lit le tableau des chambres de la fiche hôtel ; renvoie $null si le tableau est absent
function Lire-Tarifs($html, $adultes, $nuits) {
  $m = [regex]::Match("$html", '(?s)<table[^>]*id="hprt-table".*?</table>')
  if (-not $m.Success) {
    if ("$html" -match 'aucune disponibilit|no availability|nicht verf') { return , @() }   # complet ou fermé ce jour-là
    return $null
  }
  $t = $m.Value
  $c = [regex]::Match($t, '(?s)<tbody.*</tbody>'); if ($c.Success) { $t = $c.Value }
  $chambre = ''; $res = @()
  foreach ($r in [regex]::Split($t, '(?=<tr\b)')) {
    if ($r -notmatch '^<tr') { continue }
    $n = Extraire $r 'class="[^"]*hprt-roomtype-icon-link[^"]*"[^>]*>(.*?)</(?:a|span)>'
    if ($n) { $chambre = $n }
    $pt = Extraire $r 'class="[^"]*prco-valign-middle-helper[^"]*"[^>]*>(.*?)</span>'
    if (-not $pt) { $pt = Extraire $r 'class="[^"]*bui-price-display__value[^"]*"[^>]*>(.*?)</div>' }
    $prix = En-Nombre $pt
    if ($null -eq $prix -or -not $chambre) { continue }
    $cond = Extraire $r 'class="[^"]*hprt-table-cell-conditions[^"]*"[^>]*>(.*?)</td>'
    $occ = $null
    $zo = Extraire $r 'class="[^"]*hprt-table-cell-occupancy[^"]*"[^>]*>(.*?)</td>'
    $mo = [regex]::Match($zo, '(\d+)'); if ($mo.Success) { $occ = [int]$mo.Groups[1].Value }
    $sc = Simplifier $cond
    $res += [pscustomobject]@{
      chambre = $chambre; categorie = Categorie $chambre; occupation = $occ
      prix = $prix; prix_nuit = [math]::Round($prix / $nuits, 2)
      flex = Flexibilite $cond; pdj = [bool]($sc -match 'petit dejeuner compris|petit dejeuner inclus|breakfast included|demi pension|pension complete')
      conditions = $(if ($cond.Length -gt 160) { $cond.Substring(0, 160) + '…' } else { $cond })
    }
  }
  $ok = @($res | Where-Object { $null -eq $_.occupation -or $_.occupation -ge $adultes })
  if ($ok.Count -gt 0) { $res = $ok }
  return , $res
}

function Tache-Tarifs($p, $job) {
  $a = [datetime]::ParseExact($p.arrivee, 'yyyy-MM-dd', $Inv); $d = [datetime]::ParseExact($p.depart, 'yyyy-MM-dd', $Inv)
  $adultes = [int]$p.adultes; $nuits = [math]::Max(1, ($d - $a).Days)
  $url = Url-Fiche $p.lien $a $d $adultes
  $job.message = "Lecture des chambres et tarifs de « $($p.hotel) »…"; $job.progression = 30
  Log "Tarifs détaillés : $($p.hotel) $($p.arrivee)"
  $html = Lire-Rapide $url 'hprt-table|aucune disponibilit'
  $lignes = Lire-Tarifs $html $adultes $nuits
  if ($null -eq $lignes) {
    [IO.File]::WriteAllText((Join-Path $Dossier 'derniere_fiche_hotel.html'), "$html", (New-Object System.Text.UTF8Encoding $true))
    Log 'Tableau des chambres introuvable. Page enregistrée : derniere_fiche_hotel.html'
    throw "Le tableau des chambres de « $($p.hotel) » n'a pas pu être lu. La page a été enregistrée (derniere_fiche_hotel.html) pour analyse."
  }
  $job.progression = 100
  return @{ hotel = $p.hotel; lien = $p.lien; url = $url; arrivee = $p.arrivee; depart = $p.depart; nuits = $nuits; adultes = $adultes; lignes = @($lignes) }
}

# ---------- Cache des tarifs (réutilisé pendant 6 h : relance ou reprise après un arrêt) ----------
function Charger-Cache {
  $f = Join-Path $Dossier 'cache_tarifs_v2.json'
  $c = @{}
  if (Test-Path $f) {
    try {
      $o = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json
      $limite = (Get-Date).AddHours(-6).ToString('yyyy-MM-dd HH:mm')
      foreach ($pr in $o.PSObject.Properties) { if ("$($pr.Value.t)" -ge $limite) { $c[$pr.Name] = $pr.Value } }
    } catch { Log "Cache illisible, ignoré : $($_.Exception.Message)" }
  }
  return $c
}
function Sauver-Cache($c) {
  try { [IO.File]::WriteAllText((Join-Path $Dossier 'cache_tarifs_v2.json'), (ConvertTo-Json -InputObject $c -Depth 6 -Compress), (New-Object System.Text.UTF8Encoding $false)) }
  catch { Log "Cache non enregistré : $($_.Exception.Message)" }
}

function Tache-TarifsCompset($p, $job) {
  $debut = [datetime]::ParseExact($p.debut, 'yyyy-MM-dd', $Inv)
  $jours = [int]$p.jours; $adultes = [int]$p.adultes
  $hotels = @($p.hotels)
  $t0 = Get-Date
  Log "Tarifs compset : $($hotels.Count) hôtels x $jours jours"

  # 1. Calendrier rapide : on ne lit pas les jours où l'hôtel est complet ou fermé
  $cal = $null
  if ($jours -gt 1) {
    try { $cal = Calendriers-Paralleles $hotels $debut $jours $adultes $job } catch { if (Arret) { throw 'Comparaison arrêtée.' }; Log "Calendrier préalable impossible : $($_.Exception.Message)" }
  }
  $cache = Charger-Cache
  $grille = @{}                                   # "k-i" -> lignes (tableau, vide = complet)
  $aLire = New-Object System.Collections.ArrayList # @(k, i, url, cle)
  $complets = 0; $enCache = 0
  for ($k = 0; $k -lt $hotels.Count; $k++) {
    for ($i = 0; $i -lt $jours; $i++) {
      $a = $debut.AddDays($i); $d = $a.ToString('yyyy-MM-dd')
      $cle = "$($hotels[$k].lien)|$d|$adultes"
      if ($cal -and $cal.ContainsKey("h$k")) {
        $dj = $cal["h$k"][$d]
        if ($dj -and -not $dj.available) { $grille["$k-$i"] = @(); $complets++; continue }
      }
      if ($cache.ContainsKey($cle)) { $grille["$k-$i"] = @($cache[$cle].l); $enCache++; continue }
      [void]$aLire.Add(@($k, $i, (Url-Fiche $hotels[$k].lien $a $a.AddDays(1) $adultes), $cle))
    }
  }
  $total = $aLire.Count
  Log "Tarifs : $total pages à lire, $complets jours complets d'après le calendrier, $enCache déjà en cache"

  # 2. Navigateur piloté : un seul Edge, 8 fiches à la fois
  $enregistrer = {
    param($x, $l)
    $grille["$($x[0])-$($x[1])"] = $l
    $cache[$x[3]] = @{ t = (Get-Date).ToString('yyyy-MM-dd HH:mm'); l = @($l | ForEach-Object { , @($_.chambre, $_.categorie, $_.prix_nuit, $_.flex, [bool]$_.pdj) }) }
  }
  $restants = @()
  $script:lus = 0; $script:dernierSave = Get-Date
  if ($total -gt 0) {
    $job.message = "Démarrage du navigateur… ($total fiches à lire)"
    $lot = @($aLire); $echecs = New-Object System.Collections.ArrayList
    try {
      Lire-Fiches-Pilote @($lot | ForEach-Object { $_[2] }) $adultes {
        param($j, $l)
        $x = $lot[$j]
        if ($null -eq $l) { [void]$echecs.Add($x) } else { & $enregistrer $x $l; $script:lus++ }
        $fait = $script:lus + $echecs.Count
        $reste = [math]::Ceiling(((Get-Date) - $t0).TotalSeconds / [math]::Max(1, $fait) * ($total - $fait) / 60)
        $job.progression = [math]::Round(95 * $fait / $total)
        $job.message = "Tarifs détaillés : $fait fiches lues sur $total… environ $reste min restantes"
        if (((Get-Date) - $script:dernierSave).TotalSeconds -gt 30) { Sauver-Cache $cache; $script:dernierSave = Get-Date }
      }
      $restants = @($echecs)
    } catch {
      if (Arret) { Sauver-Cache $cache; throw 'Comparaison arrêtée.' }
      Log "Navigateur piloté indisponible : $($_.Exception.Message)"
      $restants = @($aLire | Where-Object { -not $grille.ContainsKey("$($_[0])-$($_[1])") })
    }
    Log "Navigateur piloté : $($script:lus)/$total fiches lues en $([math]::Round(((Get-Date) - $t0).TotalSeconds)) s"
  }
  Sauver-Cache $cache

  # 3. Pages encore illisibles : navigateur invisible (plus lent)
  $script:vides = 0
  if ($restants.Count -gt 0) {
    $script:faits2 = 0; $lot = $restants
    Lire-Pages @($lot | ForEach-Object { $_[2] }) 6 {
      param($j, $html)
      $x = $lot[$j]; $l = $null
      if ($html) { $l = Lire-Tarifs $html $adultes 1 }
      if ($null -eq $l) {
        $script:vides++
        if ($html) { [IO.File]::WriteAllText((Join-Path $Dossier 'derniere_fiche_hotel.html'), "$html", (New-Object System.Text.UTF8Encoding $true)) }
      } else { & $enregistrer $x $l }
      $script:faits2++
      $job.progression = 95 + [math]::Round(5 * $script:faits2 / $lot.Count)
      $job.message = "Lecture complémentaire avec le navigateur : $($script:faits2) sur $($lot.Count)…"
    } 5000
    Sauver-Cache $cache
  }
  if ($total -gt 0 -and $script:vides -eq $total) { throw "Aucun tableau de chambres n'a pu être lu. La page a été enregistrée (derniere_fiche_hotel.html) pour analyse." }

  # 4. Résultat compact : liste des chambres par hôtel + [chambre, prix, flex, pdj] par jour
  $sortie = @()
  for ($k = 0; $k -lt $hotels.Count; $k++) {
    $noms = @{}; $chambres = New-Object System.Collections.ArrayList; $js = New-Object System.Collections.ArrayList
    for ($i = 0; $i -lt $jours; $i++) {
      $g = "$k-$i"
      if (-not $grille.ContainsKey($g)) { [void]$js.Add($null); continue }
      $l = @($grille[$g] | Where-Object { $_ })
      $lig = New-Object System.Collections.ArrayList
      foreach ($r in $l) {
        if ($r -is [array]) { $nom = $r[0]; $cat = $r[1]; $pr = $r[2]; $fx = $r[3]; $pd = $r[4] } else { $nom = $r.chambre; $cat = $r.categorie; $pr = $r.prix_nuit; $fx = $r.flex; $pd = $r.pdj }
        if (-not $noms.ContainsKey($nom)) { $noms[$nom] = $chambres.Count; [void]$chambres.Add(@($nom, $cat)) }
        [void]$lig.Add(@($noms[$nom], [math]::Round([double]$pr, 0), "$fx", [bool]$pd))
      }
      [void]$js.Add($lig.ToArray())
    }
    $sortie += [pscustomobject]@{ hotel = $hotels[$k].hotel; lien = $hotels[$k].lien; moi = [bool]$hotels[$k].moi; chambres = $chambres.ToArray(); jours = $js.ToArray() }
  }
  $duree = [math]::Round(((Get-Date) - $t0).TotalSeconds)
  try { Nettoyer-Profils } catch {}
  Log "Tarifs compset terminés en $duree s : $($total - $script:vides)/$total pages lues, $complets complets, $enCache en cache"
  return @{ debut = $p.debut; jours = $jours; adultes = $adultes; hotels = $sortie; duree = $duree; fait_le = (Get-Date).ToString('yyyy-MM-dd HH:mm'); format = 2 }
}

# ---------------- Diagnostic (une fois par jour, en arrière-plan) ----------------
# Vérifie ce que Booking accepte en accès direct, pour choisir la méthode la plus rapide.
function Envoyer-Http($c, $msg) {
  $t = $c.SendAsync($msg)
  try { $t.Wait() } catch { $e = $_.Exception; while ($e.InnerException) { $e = $e.InnerException }; throw $e.Message }
  return $t.Result
}
function Diagnostic-Booking {
  $f = Join-Path $Dossier 'diagnostic.txt'
  $out = New-Object System.Collections.Generic.List[string]
  $ecrire = { param($t) $out.Add(("{0}  {1}" -f (Get-Date).ToString('HH:mm:ss'), $t)) }
  & $ecrire "Diagnostic du $((Get-Date).ToString('yyyy-MM-dd HH:mm'))"
  $lien = ''
  try {
    $cs = Join-Path $Dossier 'compset.csv'
    if (Test-Path $cs) { $lien = @(Import-Csv $cs -Delimiter ';' -Encoding UTF8 | Where-Object { $_.lien })[0].lien }
  } catch {}
  if (-not $lien) { $lien = 'https://www.booking.com/hotel/fr/millenium-hotel-paris-opera.fr.html' }
  & $ecrire "Hôtel de test : $lien"
  $c = Client-Http
  # 1. Page hôtel en accès direct
  $a = (Get-Date).Date.AddDays(20)
  $url = Url-Fiche $lien $a $a.AddDays(1) 2
  foreach ($variante in 1, 2) {
    try {
      $msg = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Get, $url)
      if ($variante -eq 2) {
        foreach ($h in @(@('Sec-Fetch-Dest', 'document'), @('Sec-Fetch-Mode', 'navigate'), @('Sec-Fetch-Site', 'none'), @('Sec-Fetch-User', '?1'), @('Upgrade-Insecure-Requests', '1'),
                          @('sec-ch-ua', '"Microsoft Edge";v="129", "Not=A?Brand";v="8", "Chromium";v="129"'), @('sec-ch-ua-mobile', '?0'), @('sec-ch-ua-platform', '"Windows"'))) {
          [void]$msg.Headers.TryAddWithoutValidation($h[0], $h[1]) }
      }
      $r = (Envoyer-Http $c $msg)
      $t = "$($r.Content.ReadAsStringAsync().Result)"
      $debut = ($t.Substring(0, [math]::Min(160, $t.Length)) -replace '\s+', ' ')
      & $ecrire ("Page hôtel directe (variante $variante) : code {0}, {1} ko, tableau chambres={2}, jeton={3}, défi={4} | {5}" -f [int]$r.StatusCode, [math]::Round($t.Length / 1024), ($t -match 'hprt-table'), [bool](Trouver-Jeton $t), ($t -match 'awswaf|challenge|captcha'), $debut)
    } catch { & $ecrire "Page hôtel directe (variante $variante) : erreur $($_.Exception.Message)" }
  }
  # 2. Introspection GraphQL du calendrier
  $jeton = ''
  try { $jeton = Jeton-Booking $lien } catch {}
  & $ecrire ("Jeton : " + $(if ($jeton) { 'trouvé' } else { 'absent' }))
  $post = {
    param($corps)
    $msg = New-Object System.Net.Http.HttpRequestMessage([System.Net.Http.HttpMethod]::Post, "https://www.booking.com/dml/graphql?lang=fr")
    $msg.Content = New-Object System.Net.Http.StringContent($corps, [Text.Encoding]::UTF8, 'application/json')
    [void]$msg.Headers.TryAddWithoutValidation('Origin', 'https://www.booking.com')
    [void]$msg.Headers.TryAddWithoutValidation('Referer', $lien)
    if ($jeton) { [void]$msg.Headers.TryAddWithoutValidation('x-booking-csrf-token', $jeton) }
    $r = (Envoyer-Http $c $msg)
    return ("HTTP $([int]$r.StatusCode) " + "$($r.Content.ReadAsStringAsync().Result)")
  }
  $vus = @{}; $file = New-Object System.Collections.Queue
  foreach ($n in 'AvailabilityCalendarQueryInput', 'AvailabilityCalendarQueryResult') { $file.Enqueue($n) }
  $nb = 0
  while ($file.Count -gt 0 -and $nb -lt 14) {
    $n = $file.Dequeue(); if ($vus.ContainsKey($n)) { continue }; $vus[$n] = 1; $nb++
    $q = @{ query = "query { __type(name: `"$n`") { name kind inputFields { name type { name kind ofType { name kind ofType { name kind } } } } fields { name type { name kind ofType { name kind ofType { name kind } } } } enumValues { name } } }" } | ConvertTo-Json -Compress
    try {
      $rep = & $post $q
      & $ecrire "Type $n : $($rep.Substring(0, [math]::Min(1500, $rep.Length)))"
      $o = ($rep -replace '^HTTP \d+ ', '') | ConvertFrom-Json
      foreach ($champ in @($o.data.__type.inputFields) + @($o.data.__type.fields)) {
        $ty = $champ.type; while ($ty -and -not $ty.name) { $ty = $ty.ofType }
        if ($ty -and $ty.name -and $ty.kind -in 'INPUT_OBJECT', 'OBJECT', 'ENUM' -and -not $ty.name.StartsWith('__')) { $file.Enqueue($ty.name) }
      }
    } catch { & $ecrire "Type $n : erreur $($_.Exception.InnerException.Message) $($_.Exception.Message)" }
  }
  # 3. Si l'introspection est fermée : un champ inconnu fait souvent apparaître la liste des champs possibles
  $sonde = @{ operationName = 'AvailabilityCalendar'; query = 'query AvailabilityCalendar($input: AvailabilityCalendarQueryInput!) { availabilityCalendar(input: $input) { __typename } }'
    variables = @{ input = @{ zzTest = 1; travelPurpose = 2; pagenameDetails = @{ countryCode = 'fr'; pagename = 'x' } } } } | ConvertTo-Json -Depth 6 -Compress
  try { $rep = & $post $sonde; & $ecrire "Sonde champ inconnu : $($rep.Substring(0, [math]::Min(1200, $rep.Length)))" } catch { & $ecrire "Sonde : erreur $($_.Exception.Message)" }
  [IO.File]::WriteAllLines($f, $out, (New-Object System.Text.UTF8Encoding $true))
}

# Vide les caches des navigateurs invisibles (ils peuvent grossir de plusieurs Go)
function Nettoyer-Profils {
  $tmp = if ($env:TEMP) { $env:TEMP } else { [IO.Path]::GetTempPath() }
  foreach ($p in @(Get-ChildItem -Path $tmp -Directory -Filter 'releve-booking-profil*' -ErrorAction SilentlyContinue)) {
    foreach ($sous in 'Default\Cache', 'Default\Code Cache', 'Default\Service Worker', 'Default\GPUCache', 'GrShaderCache', 'ShaderCache', 'GraphiteDawnCache', 'Default\IndexedDB', 'component_crx_cache') {
      $c = Join-Path $p.FullName $sous
      if (Test-Path $c) { Remove-Item -Path $c -Recurse -Force -ErrorAction SilentlyContinue }
    }
  }
}

# ---------------- Fiches hôtels : équipements, règles, chambres, notes… ----------------
function Tache-Fiches($p, $job) {
  $hotels = @($p.hotels)
  $f = Join-Path $Dossier 'fiches_hotels.json'
  $cache = @{}
  if ((Test-Path $f) -and -not $p.forcer) {
    try {
      $o = [IO.File]::ReadAllText($f, [Text.Encoding]::UTF8) | ConvertFrom-Json
      $limite = (Get-Date).AddDays(-7).ToString('yyyy-MM-dd HH:mm')
      foreach ($pr in $o.PSObject.Properties) { if ("$($pr.Value.t)" -ge $limite) { $cache[$pr.Name] = $pr.Value } }
    } catch { Log "Fiches en cache illisibles : $($_.Exception.Message)" }
  }
  $aLire = @($hotels | Where-Object { -not $cache.ContainsKey("$($_.lien)") })
  Log "Fiches hôtels : $($hotels.Count) hôtel(s), $($aLire.Count) à lire"
  if ($aLire.Count -gt 0) {
    $js = [IO.File]::ReadAllText((Join-Path $App 'fiche.js'), [Text.Encoding]::UTF8)
    $job.message = 'Ouverture de Booking…'; $job.progression = 5
    Cdp-Demarrer (([uri]$aLire[0].lien).GetLeftPart([UriPartial]::Authority))
    try {
      $a = (Get-Date).Date.AddDays(30); $k = 0
      foreach ($h in $aLire) {
        if (Arret) { throw 'Lecture arrêtée.' }
        $k++
        $job.message = "Lecture de la fiche de « $($h.hotel) » ($k sur $($aLire.Count))…"
        $job.progression = [math]::Round(5 + 90 * ($k - 1) / $aLire.Count)
        $url = Url-Fiche $h.lien $a $a.AddDays(1) 2
        $nomPage = ([regex]::Match($h.lien, '/hotel/[a-z]{2}/([^/.?]+)')).Groups[1].Value
        try {
          [void](Cdp-Appel 'Page.navigate' @{ url = $url } 60)
          Attendre 2
          for ($t = 0; $t -lt 60; $t++) {
            $etat = $null
            try { $etat = Cdp-Eval "document.readyState + '|' + location.href" 5 } catch {}
            if ($etat -and $etat.StartsWith('complete') -and (-not $nomPage -or $etat.Contains($nomPage))) { break }
            Start-Sleep -Milliseconds 500
          }
          $fiche = Cdp-Eval $js 120
          if ($fiche) { $cache["$($h.lien)"] = [pscustomobject]@{ t = (Get-Date).ToString('yyyy-MM-dd HH:mm'); fiche = $fiche } }
        } catch { if (Arret) { throw }; Log "Fiche de $($h.hotel) non lue : $($_.Exception.Message)" }
      }
    } finally { Cdp-Arreter }
    try {
      $sortie = [ordered]@{}; foreach ($k2 in $cache.Keys) { $sortie[$k2] = $cache[$k2] }
      [IO.File]::WriteAllText($f, (ConvertTo-Json -InputObject $sortie -Depth 14 -Compress), (New-Object System.Text.UTF8Encoding $false))
    } catch { Log "Fiches non enregistrées : $($_.Exception.Message)" }
  }
  $job.progression = 100
  $res = @($hotels | ForEach-Object { $c = $cache["$($_.lien)"]; [pscustomobject]@{ hotel = $_.hotel; lien = $_.lien; moi = [bool]$_.moi; lu = [bool]$c; t = $(if ($c) { $c.t } else { '' }); fiche = $(if ($c) { $c.fiche } else { $null }) } })
  Log "Fiches hôtels : $(@($res | Where-Object { $_.lu }).Count)/$($hotels.Count) disponibles"
  return @{ hotels = $res; fait_le = (Get-Date).ToString('yyyy-MM-dd HH:mm') }
}
