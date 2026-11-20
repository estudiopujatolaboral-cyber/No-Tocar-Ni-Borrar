# Lee los valores de aportes de trabajadores autonomos que ARCA publica cada mes en PDF
# (pagina https://www.arca.gob.ar/autonomos/categorias-y-aportes/AAAA.asp) y guarda los ultimos 3 meses
# en datos/autonomos.json (lo usa datos-tabla-autonomos.html).
# Los valores se actualizan todos los meses por IPC (DNU 274/2024) y rigen desde el dia 15.
# Antes de guardar controla que esten las categorias I a V y las rentas de referencia; si algo no cierra,
# falla y el archivo queda como estaba.
# Lo ejecuta todos los dias la tarea .github/workflows/actualizar-datos.yml.
param([int]$meses = 3)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pdf-texto.ps1')
$base = 'https://www.arca.gob.ar'
$carpeta = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../datos'))

# Enlaces a los PDF, del mas nuevo al mas viejo (si el anio recien empieza, se completa con el anterior).
$pdfs = @()
$anio = (Get-Date).Year
foreach ($a in $anio, ($anio - 1)) {
  try { $html = [Text.Encoding]::UTF8.GetString((Invoke-WebRequest "$base/autonomos/categorias-y-aportes/$a.asp" -UseBasicParsing -TimeoutSec 60).RawContentStream.ToArray()) }
  catch { continue }
  $pdfs += [regex]::Matches($html, 'href="([^"]*Valores-autonomos-desde-[^"]+\.pdf)"', 'IgnoreCase') | ForEach-Object { $_.Groups[1].Value }
  $pdfs = @($pdfs | Select-Object -Unique)
  if ($pdfs.Count -ge $meses) { break }
}
if ($pdfs.Count -eq 0) { throw "No se encontraron los PDF de valores de autonomos en la pagina de ARCA. Revisar si cambio el formato." }
$pdfs = @($pdfs | Select-Object -First $meses | ForEach-Object { if ($_ -like 'http*') { $_ } else { $base + $_ } })

$esImporte = '^\$?\s*[0-9.]+,[0-9]{2}$'
function Importe($s) { [decimal](($s -replace '[$\s.]', '') -replace ',', '.') }

# Convierte un PDF en: vigencia + lista de tablas (bloque, titulo, encabezado y filas categoria -> importe).
function Leer-Periodo($url) {
  $bytes = (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 60).RawContentStream.ToArray()
  $renglones = @((Leer-TextoPdf $bytes) | ForEach-Object { $_ })
  $todo = ($renglones | ForEach-Object { ($_.partes | ForEach-Object { $_.t }) -join ' ' }) -join "`n"
  $vig = [regex]::Match($todo, 'a partir del\s+d\S+\s+([0-9]{2}/[0-9]{2}/[0-9]{4})')
  if (-not $vig.Success) { throw "No se encontro la fecha de vigencia en $url" }

  $tablas = New-Object System.Collections.ArrayList
  $bloque = ''; $actual = $null
  foreach ($r in $renglones) {
    $p = @($r.partes | ForEach-Object { $_.t.Trim() })
    $linea = ($p -join ' ').Trim()
    if ($linea -match '^Categor\S+ m\S+nimas de revista') { $bloque = 'minimas'; $actual = $null; continue }
    if ($linea -match '^Categor\S+ de revista') { $bloque = 'revista'; $actual = $null; continue }
    if ($linea -match '^Rentas de Referencia') {
      $bloque = 'rentas'; $actual = [pscustomobject]@{ bloque = 'rentas'; letra = ''; titulo = $linea; encabezado = ''; filas = [ordered]@{} }
      [void]$tablas.Add($actual); continue
    }
    if ($linea -match '^Punto \d+ del art') { $bloque = ''; $actual = $null; continue }   # notas legales del final
    if (-not $bloque) { continue }
    # -cmatch: solo mayusculas (las notas legales usan "a)", "b)" en minuscula).
    if ($linea -cmatch '^([A-F])\)\s*(.+)$') {
      $actual = [pscustomobject]@{ bloque = $bloque; letra = $Matches[1]; titulo = $Matches[2].Trim(); encabezado = ''; filas = [ordered]@{} }
      [void]$tablas.Add($actual); continue
    }
    if (-not $actual) { continue }
    if ($p.Count -eq 2 -and $p[1] -match $esImporte) { $actual.filas[$p[0]] = Importe $p[1]; continue }
    if ($p[0] -match '^Categor') { $actual.encabezado = $p[0]; continue }
    if ($actual.filas.Count -eq 0) { $actual.titulo = ($actual.titulo + ' ' + $linea).Trim() }   # titulo en varios renglones
  }
  [pscustomobject]@{ vigencia = $vig.Groups[1].Value; url = $url; tablas = $tablas }
}

$periodos = @($pdfs | ForEach-Object { Leer-Periodo $_ })
$nuevo = $periodos[0]

$minA = $nuevo.tablas | Where-Object { $_.bloque -eq 'minimas' -and $_.letra -eq 'A' }
$rentas = $nuevo.tablas | Where-Object { $_.bloque -eq 'rentas' }
if (-not $minA -or (@($minA.filas.Keys) -join ',') -ne 'I,II,III,IV,V') { throw "No se leyeron las categorias I a V de aportes minimos. Revisar el PDF de ARCA." }
if (-not $rentas -or $rentas.filas.Count -ne 5) { throw "No se leyeron las 5 rentas de referencia. Revisar el PDF de ARCA." }

# Las tablas siguen la estructura del PDF mas nuevo; cada fila trae el importe de cada periodo (null si no esta).
$tablas = foreach ($t in $nuevo.tablas) {
  [ordered]@{
    bloque     = $t.bloque
    letra      = $t.letra
    titulo     = $t.titulo
    encabezado = $t.encabezado
    filas      = @(foreach ($cat in $t.filas.Keys) {
      [ordered]@{
        categoria = $cat
        importes  = @(foreach ($per in $periodos) {
          $igual = $per.tablas | Where-Object { $_.bloque -eq $t.bloque -and $_.letra -eq $t.letra } | Select-Object -First 1
          if ($igual -and $igual.filas.Contains($cat)) { $igual.filas[$cat] } else { $null }
        })
      }
    })
  }
}

$datos = [ordered]@{
  periodos = @($periodos | ForEach-Object { [ordered]@{ vigencia = $_.vigencia; pdf = $_.url } })
  tablas   = @($tablas)
}
[IO.File]::WriteAllText((Join-Path $carpeta 'autonomos.json'), (ConvertTo-Json $datos -Depth 8), (New-Object Text.UTF8Encoding $false))
Write-Output "Autonomos: valores vigentes desde el $($nuevo.vigencia) ($($periodos.Count) meses, $(@($tablas).Count) tablas)."
