# Prix Hôtel - petit serveur local : affiche l'application dans une fenêtre Edge
# et fait les recherches Booking en arrière-plan. Rien n'est accessible depuis l'extérieur du PC.

$ErrorActionPreference = 'Stop'
$App = Split-Path -Parent $MyInvocation.MyCommand.Path
$Dossier = Split-Path -Parent $App          # dossier releve-booking (données, journal)
$SansFenetre = $args -contains '--sans-fenetre'
$Version = 14   # augmente à chaque mise à jour : une ancienne version encore ouverte est remplacée
$sync = [hashtable]::Synchronized(@{ arret = $false; job = $null })
. (Join-Path $App 'booking.ps1')

# ---------- Déjà ouverte ? on réaffiche simplement la fenêtre ----------
function Ouvrir-Fenetre($port) {
  if ($SansFenetre) { return }
  $url = "http://127.0.0.1:$port/"
  $nav = Trouver-Navigateur
  if ($nav) { Start-Process -FilePath $nav -ArgumentList "--app=$url", '--window-size=1280,860' }
  else { Start-Process $url }
}
foreach ($port in 8765..8775) {
  try {
    $r = Invoke-WebRequest -Uri "http://127.0.0.1:$port/api/ping" -UseBasicParsing -TimeoutSec 1
    $info = $r.Content | ConvertFrom-Json
    if ($info.app -eq 'prix-hotel') {
      if ([int]$info.version -ge $Version) { Ouvrir-Fenetre $port; exit 0 }
      try { Invoke-WebRequest -Uri "http://127.0.0.1:$port/api/quitter" -Method Post -Body '{}' -UseBasicParsing -TimeoutSec 2 | Out-Null } catch {}
    }
  } catch {}
}

# ---------- Démarrage du serveur ----------
$ecoute = $null
foreach ($port in 8765..8775) {
  try { $ecoute = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, $port); $ecoute.Start(); break }
  catch { $ecoute = $null }
}
if (-not $ecoute) { Log 'Serveur : aucun port libre'; exit 1 }
Log "Application démarrée sur http://127.0.0.1:$port/"

# ---------- Tâches de fond ----------
$script:ps = $null
$ScriptTache = {
  param($sync, $Dossier, $App, $type, $params)
  $ErrorActionPreference = 'Stop'
  . (Join-Path $App 'booking.ps1')
  $job = $sync.job
  try {
    switch ($type) {
      'recherche' { $job.resultat = Tache-Recherche $params $job }
      'compset'   { $job.resultat = Tache-Compset $params $job }
      'fiche'     { $job.resultat = Tache-Fiche $params $job }
      'fiches'    { $job.resultat = Tache-Fiches $params $job }
      'tarifs'    { $job.resultat = Tache-Tarifs $params $job }
      'tarifscs'  { $job.resultat = Tache-TarifsCompset $params $job }
    }
    $job.etat = 'fini'; $job.message = 'Terminé'
  } catch {
    $job.etat = 'erreur'; $job.message = $_.Exception.Message
    Log "Erreur ($type) : $($_.Exception.Message)"
  }
}
function Lancer-Tache($type, $params) {
  if ($sync.job -and $sync.job.etat -eq 'en_cours') { return @{ erreur = 'Une recherche est déjà en cours. Attendez la fin ou arrêtez-la.' } }
  if ($script:ps) { try { $script:ps.Dispose() } catch {} }
  $id = [guid]::NewGuid().ToString('N').Substring(0, 8)
  $sync.arret = $false
  $sync.job = [hashtable]::Synchronized(@{ id = $id; type = $type; etat = 'en_cours'; message = 'Démarrage…'; progression = 0; resultat = $null })
  $ps = [powershell]::Create()
  [void]$ps.AddScript($ScriptTache).AddArgument($sync).AddArgument($Dossier).AddArgument($App).AddArgument($type).AddArgument($params)
  [void]$ps.BeginInvoke()
  $script:ps = $ps
  return @{ id = $id }
}

# ---------- HTTP minimal ----------
function Lire-Requete($flux) {
  $flux.ReadTimeout = 10000
  $tampon = New-Object byte[] 65536
  $ms = New-Object System.IO.MemoryStream
  $fin = -1
  while ($fin -lt 0) {
    $n = $flux.Read($tampon, 0, $tampon.Length)
    if ($n -le 0) { return $null }
    $ms.Write($tampon, 0, $n)
    $fin = [Text.Encoding]::ASCII.GetString($ms.ToArray()).IndexOf("`r`n`r`n")
    if ($ms.Length -gt 1MB) { return $null }
  }
  $tout = $ms.ToArray()
  $entete = [Text.Encoding]::ASCII.GetString($tout, 0, $fin) -split "`r`n"
  $premiere = $entete[0] -split ' '
  $longueur = 0
  foreach ($l in $entete) { if ($l -match '^(?i)content-length:\s*(\d+)') { $longueur = [int]$matches[1] } }
  $debutCorps = $fin + 4
  while (($tout.Length - $debutCorps) -lt $longueur) {
    $n = $flux.Read($tampon, 0, $tampon.Length); if ($n -le 0) { break }
    $ms.Write($tampon, 0, $n); $tout = $ms.ToArray()
  }
  $corps = ''
  if ($longueur -gt 0) { $corps = [Text.Encoding]::UTF8.GetString($tout, $debutCorps, [math]::Min($longueur, $tout.Length - $debutCorps)) }
  $chemin = $premiere[1]; $requete = ''
  if ($chemin -match '^([^?]*)\?(.*)$') { $chemin = $matches[1]; $requete = $matches[2] }
  return @{ methode = $premiere[0]; chemin = $chemin; requete = $requete; corps = $corps }
}
function Repondre($flux, $code, $type, [byte[]]$octets) {
  $texte = @{ 200 = 'OK'; 400 = 'Bad Request'; 404 = 'Not Found'; 500 = 'Internal Server Error' }[$code]
  $entete = "HTTP/1.1 $code $texte`r`nContent-Type: $type`r`nContent-Length: $($octets.Length)`r`nCache-Control: no-store`r`nConnection: close`r`n`r`n"
  $e = [Text.Encoding]::ASCII.GetBytes($entete)
  $flux.Write($e, 0, $e.Length); $flux.Write($octets, 0, $octets.Length); $flux.Flush()
}
function Json($objet) { return [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $objet -Depth 14 -Compress)) }

# ---------- Compset enregistré ----------
$FichierCompset = Join-Path $Dossier 'compset.csv'
function Lire-Compset {
  if (-not (Test-Path $FichierCompset)) { return @() }
  return @(Import-Csv -Path $FichierCompset -Delimiter ';' -Encoding UTF8 | ForEach-Object {
    [pscustomobject]@{ hotel = $_.hotel; adresse = $_.adresse; lien = $_.lien; moi = ($_.mon_hotel -eq 'oui') } })
}
function Ecrire-Compset($liste) {
  $lignes = @($liste | ForEach-Object { [pscustomobject][ordered]@{ mon_hotel = $(if ($_.moi) { 'oui' } else { '' }); hotel = $_.hotel; adresse = $_.adresse; lien = $_.lien } })
  if ($lignes.Count -eq 0) { if (Test-Path $FichierCompset) { Remove-Item $FichierCompset }; return }
  $lignes | Export-Csv -Path $FichierCompset -Delimiter ';' -NoTypeInformation -Encoding UTF8
}

function Traiter($req) {
  $c = $req.chemin
  if ($req.methode -eq 'GET' -and ($c -eq '/' -or $c -eq '/index.html')) {
    return @(200, 'text/html; charset=utf-8', [IO.File]::ReadAllBytes((Join-Path $App 'app.html')))
  }
  if ($c -eq '/api/ping') { return @(200, 'application/json', (Json @{ app = 'prix-hotel'; ok = $true; version = $Version; page = (Get-Item (Join-Path $App 'app.html')).LastWriteTimeUtc.Ticks.ToString() })) }
  if ($c -eq '/api/suggestions') {
    $q = ''
    if ($req.requete -match '(?:^|&)q=([^&]*)') { $q = [uri]::UnescapeDataString(($matches[1] -replace '\+', ' ')) }
    if ($q.Trim().Length -lt 2) { return @(200, 'application/json', (Json @{ resultats = @() })) }
    try { $r = @(Suggestions-Booking $q.Trim() 8) } catch { Log "Suggestions : $($_.Exception.Message)"; $r = @() }
    return @(200, 'application/json', (Json @{ resultats = $r }))
  }
  if ($c -eq '/api/tache') {
    $j = $sync.job
    if (-not $j) { return @(200, 'application/json', (Json @{ etat = 'aucune' })) }
    $o = @{ id = $j.id; type = $j.type; etat = $j.etat; message = $j.message; progression = $j.progression }
    if ($j.etat -eq 'fini') { $o.resultat = $j.resultat }
    return @(200, 'application/json', (Json $o))
  }
  $p = $null
  if ($req.corps) { $p = $req.corps | ConvertFrom-Json }
  switch ($c) {
    '/api/tarifs'    { return @(200, 'application/json', (Json (Lancer-Tache 'tarifs' $p))) }
    '/api/tarifscs'  { return @(200, 'application/json', (Json (Lancer-Tache 'tarifscs' $p))) }
    '/api/fiches'    { return @(200, 'application/json', (Json (Lancer-Tache 'fiches' $p))) }
    '/api/fiche'     { return @(200, 'application/json', (Json (Lancer-Tache 'fiche' $p))) }
    '/api/recherche' { return @(200, 'application/json', (Json (Lancer-Tache 'recherche' $p))) }
    '/api/comparer'  { return @(200, 'application/json', (Json (Lancer-Tache 'compset' $p))) }
    '/api/quitter'   { $script:Quitter = $true; $sync.arret = $true; return @(200, 'application/json', (Json @{ ok = $true })) }
    '/api/arreter'   { $sync.arret = $true; return @(200, 'application/json', (Json @{ ok = $true })) }
    '/api/compset' {
      if ($req.methode -eq 'POST') { Ecrire-Compset @($p.hotels); return @(200, 'application/json', (Json @{ ok = $true })) }
      return @(200, 'application/json', (Json @{ hotels = @(Lire-Compset) }))
    }
    '/api/excel' {
      $nomFic = ("$($p.nom)" -replace '[^\w\-]+', '_') + '.csv'
      $chemin = Join-Path $Dossier $nomFic
      [IO.File]::WriteAllText($chemin, "$($p.contenu)", (New-Object System.Text.UTF8Encoding $true))
      if (-not $SansFenetre) { Start-Process $chemin }
      return @(200, 'application/json', (Json @{ ok = $true; fichier = $nomFic }))
    }
    '/api/xlsx' {
      if (-not ('XlsxEcrivain' -as [type])) {
        Add-Type -TypeDefinition ([IO.File]::ReadAllText((Join-Path $App 'xlsx.cs'))) -ReferencedAssemblies 'System.IO.Compression' -ErrorAction Stop
      }
      $nomFic = ("$($p.nom)" -replace '[^\w\-]+', '_') + '.xlsx'
      $chemin = Join-Path $Dossier $nomFic
      $fs = @($p.feuilles)
      [XlsxEcrivain]::Ecrire($chemin, [string[]]@($fs | ForEach-Object { "$($_.nom)" }), [string[]]@($fs | ForEach-Object { "$($_.tsv)" }))
      if (-not $SansFenetre) { Start-Process $chemin }
      return @(200, 'application/json', (Json @{ ok = $true; fichier = $nomFic }))
    }
    '/api/categories' {
      $fc = Join-Path $Dossier 'categories.json'
      if ($req.methode -eq 'POST') { [IO.File]::WriteAllText($fc, (ConvertTo-Json -InputObject $p -Depth 4 -Compress), (New-Object System.Text.UTF8Encoding $false)); return @(200, 'application/json', (Json @{ ok = $true })) }
      if (Test-Path $fc) { return @(200, 'application/json', [IO.File]::ReadAllBytes($fc)) }
      return @(200, 'application/json', (Json @{ categories = @{} }))
    }
    '/api/dossier' { if (-not $SansFenetre) { Start-Process explorer.exe $Dossier }; return @(200, 'application/json', (Json @{ ok = $true })) }
  }
  return @(404, 'text/plain; charset=utf-8', [Text.Encoding]::UTF8.GetBytes('Introuvable'))
}

Ouvrir-Fenetre $port
try { Nettoyer-Profils } catch {}

# ---------- Version à partager avec l'équipe : « Prix Hotel.zip », régénérée dès que l'application change ----------
$FichierPartage = Join-Path (Split-Path -Parent $Dossier) 'Prix Hotel.zip'
function Generer-Partage {
  try {
    $sources = @(
      @{ f = Join-Path $App 'booking.ps1'; e = 'Prix Hotel/app/booking.ps1' },
      @{ f = Join-Path $App 'serveur.ps1'; e = 'Prix Hotel/app/serveur.ps1' },
      @{ f = Join-Path $App 'app.html';    e = 'Prix Hotel/app/app.html' },
      @{ f = Join-Path $App 'xlsx.cs';     e = 'Prix Hotel/app/xlsx.cs' },
      @{ f = Join-Path $App 'fiche.js';    e = 'Prix Hotel/app/fiche.js' },
      @{ f = Join-Path $App 'LISEZMOI.txt'; e = 'Prix Hotel/LISEZMOI.txt' },
      @{ f = Join-Path $Dossier 'Prix hotel Booking.bat'; e = 'Prix Hotel/Prix hotel Booking.bat' }
    ) | Where-Object { Test-Path $_.f }
    $recent = ($sources | ForEach-Object { (Get-Item $_.f).LastWriteTimeUtc } | Measure-Object -Maximum).Maximum
    if ((Test-Path $FichierPartage) -and (Get-Item $FichierPartage).LastWriteTimeUtc -ge $recent) { return }
    Add-Type -AssemblyName System.IO.Compression, System.IO.Compression.FileSystem
    $tmp = "$FichierPartage.tmp"
    if (Test-Path $tmp) { Remove-Item $tmp -Force }
    $z = [System.IO.Compression.ZipFile]::Open($tmp, 'Create')
    try { foreach ($s in $sources) { [void][System.IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $s.f, $s.e, 'Optimal') } }
    finally { $z.Dispose() }
    Move-Item -Path $tmp -Destination $FichierPartage -Force
    Log "Version à partager mise à jour : $FichierPartage"
  } catch { Log "Version à partager non mise à jour : $($_.Exception.Message)" }
}
Generer-Partage
$script:dernierPartage = Get-Date
# Diagnostic Booking en arrière-plan (une fois par jour)
try {
  $fd = Join-Path $Dossier 'diagnostic.txt'
  if (-not (Test-Path $fd) -or (Get-Item $fd).LastWriteTime.Date -lt (Get-Date).Date) {
    $psd = [powershell]::Create()
    [void]$psd.AddScript({ param($sync, $Dossier, $App) . (Join-Path $App 'booking.ps1'); try { Diagnostic-Booking } catch { Log "Diagnostic : $($_.Exception.Message)" } }).AddArgument(@{ arret = $false }).AddArgument($Dossier).AddArgument($App)
    [void]$psd.BeginInvoke()
  }
} catch {}
$dernier = Get-Date
$clients = New-Object System.Collections.ArrayList   # connexions ouvertes en attente de données
while ($true) {
  $actif = $false
  while ($ecoute.Pending()) { [void]$clients.Add(@{ c = $ecoute.AcceptTcpClient(); t = (Get-Date) }); $actif = $true }
  foreach ($x in @($clients)) {
    $client = $x.c
    $pret = $false
    try { $pret = $client.Connected -and $client.GetStream().DataAvailable } catch {}
    if ($pret) {
      [void]$clients.Remove($x); $actif = $true
      try {
        $flux = $client.GetStream()
        $req = Lire-Requete $flux
        if ($req) {
          $dernier = Get-Date
          try { $rep = Traiter $req } catch { Log "Serveur : $($_.Exception.Message)"; $rep = @(500, 'application/json', (Json @{ erreur = $_.Exception.Message })) }
          Repondre $flux $rep[0] $rep[1] $rep[2]
        }
      } catch { } finally { $client.Close() }
    } elseif (((Get-Date) - $x.t).TotalSeconds -gt 30 -or -not $client.Connected) {
      [void]$clients.Remove($x); try { $client.Close() } catch {}
    }
  }
  if ($script:Quitter) { break }
  if (((Get-Date) - $script:dernierPartage).TotalSeconds -gt 60) { $script:dernierPartage = Get-Date; Generer-Partage }
  if (-not $actif) {
    Start-Sleep -Milliseconds 20
    # fenêtre fermée depuis plus de 2 minutes et rien en cours : on s'arrête
    $occupe = $sync.job -and $sync.job.etat -eq 'en_cours'
    if (-not $occupe -and ((Get-Date) - $dernier).TotalSeconds -gt 120) { break }
  }
}
$ecoute.Stop()
Log 'Application fermée'
