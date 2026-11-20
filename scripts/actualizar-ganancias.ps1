# Lee de ARCA las tablas anuales del Impuesto a las Ganancias y guarda los 2 anios mas nuevos
# en datos/ganancias.json (lo usa datos-tabla-ganancias.html):
#   - Personas humanas: escala del art. 94 y deducciones personales del art. 30 (liquidacion anual),
#     mas el tope anual de primas de seguro de vida (deducciones generales).
#   - Personas juridicas: escala del art. 73 (ejercicios iniciados en cada anio).
# Cuando ARCA publica un anio nuevo (por ejemplo 2027), queda ese y el anterior; el mas viejo deja de mostrarse.
# Antes de guardar controla que las escalas tengan los tramos y alicuotas esperados y que esten las
# 7 deducciones personales; si algo no cierra, falla y el archivo queda como estaba.
# Lo ejecuta todos los dias la tarea .github/workflows/actualizar-datos.yml.
param([int]$anios = 2)
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'pdf-texto.ps1')
$base = 'https://www.arca.gob.ar'
$carpeta = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../datos'))

function Pagina($url) { [Text.Encoding]::UTF8.GetString((Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 60).RawContentStream.ToArray()) }
function Absoluta($href, $pagina) { if ($href -like 'http*') { $href } elseif ($href -like '/*') { $base + $href } else { ($pagina -replace '[^/]+$', '') + $href } }
function Importe($s) { [decimal](($s -replace '[$\s.]', '') -replace ',', '.') }
$esImporte = '^[0-9.]+,[0-9]{2}$'

# Devuelve { anio -> url } con los PDF de una pagina cuyo nombre cumple el patron (el anio es el grupo 1).
function Pdfs-Por-Anio($pagina, $patron) {
  $html = Pagina $pagina
  $res = @{}
  foreach ($m in [regex]::Matches($html, 'href="([^"]+\.pdf)"', 'IgnoreCase')) {
    $href = $m.Groups[1].Value
    $a = [regex]::Match($href, $patron, 'IgnoreCase')
    if ($a.Success -and -not $res.ContainsKey([int]$a.Groups[1].Value)) { $res[[int]$a.Groups[1].Value] = Absoluta $href $pagina }
  }
  $res
}
function Textos-Pdf($url) {
  $bytes = (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 60).RawContentStream.ToArray()
  @((Leer-TextoPdf $bytes) | ForEach-Object { $_.partes | ForEach-Object { $_.t.Trim() } } | Where-Object { $_ })
}

# Escala (humanas o juridicas): a partir del primer "0,00" vienen filas de 5 valores:
# mas de, hasta (o "en adelante"), pagaran, mas el %, sobre el excedente de.
function Leer-Escala($url, [int[]]$alicuotas) {
  $t = Textos-Pdf $url
  $i = [array]::IndexOf($t, '0,00')
  if ($i -lt 0) { throw "No se encontro la escala en $url" }
  $valores = @($t[$i..($t.Count - 1)] | Where-Object { $_ -match $esImporte -or $_ -match '^[0-9]{1,2}$' -or $_ -match '^en adelante$' })
  if ($valores.Count -ne 5 * $alicuotas.Count) { throw "La escala de $url no tiene $($alicuotas.Count) tramos. Revisar el PDF de ARCA." }
  $filas = for ($k = 0; $k -lt $valores.Count; $k += 5) {
    $hasta = $valores[$k + 1]
    [ordered]@{
      desde     = Importe $valores[$k]
      hasta     = $(if ($hasta -match '^en adelante$') { $null } else { Importe $hasta })
      fijo      = Importe $valores[$k + 2]
      alicuota  = [int]$valores[$k + 3]
      excedente = Importe $valores[$k + 4]
    }
  }
  if ((@($filas | ForEach-Object { $_.alicuota }) -join ',') -ne ($alicuotas -join ',')) { throw "Las alicuotas de la escala de $url no son las esperadas. Revisar el PDF de ARCA." }
  if ($null -ne $filas[-1].hasta) { throw "El ultimo tramo de la escala de $url no dice 'en adelante'. Revisar el PDF de ARCA." }
  @($filas)
}

# Deducciones personales: los 7 importes en el orden del PDF.
function Leer-Deducciones($url) {
  $imp = @((Textos-Pdf $url) | Where-Object { $_ -match $esImporte } | ForEach-Object { Importe $_ })
  if ($imp.Count -ne 7) { throw "Se esperaban 7 deducciones personales en $url y se leyeron $($imp.Count). Revisar el PDF de ARCA." }
  [ordered]@{ mni = $imp[0]; conyuge = $imp[1]; hijo = $imp[2]; hijoIncapacitado = $imp[3]; especial = $imp[4]; especialEmprendedores = $imp[5]; especialApartado2 = $imp[6] }
}

# --- Personas humanas ---
$pagDed = "$base/gananciasYBienes/ganancias/personas-humanas-sucesiones-indivisas/deducciones/deducciones-personales.asp"
$pagEsc = "$base/gananciasYBienes/ganancias/personas-humanas-sucesiones-indivisas/declaracion-jurada/determinativa/determinacion.asp"
$pagGen = "$base/gananciasYBienes/ganancias/personas-humanas-sucesiones-indivisas/deducciones/deducciones-generales.asp"
$pdfDed = Pdfs-Por-Anio $pagDed 'art-30-liq[a-z]*-anual-([0-9]{4})\.pdf$'
$pdfEsc = Pdfs-Por-Anio $pagEsc 'art-94[^/]*anual[^/]*-([0-9]{4})\.pdf$'

# Tope de primas de seguro de vida: tabla "ANIO TOPE 2026 753.472,14 2025 ..." de deducciones generales.
$seguro = @{}
$txtGen = (Pagina $pagGen) -replace '<[^>]+>', ' ' -replace '&nbsp;', ' ' -replace '\s+', ' '
$bloque = [regex]::Match($txtGen, 'TOPE\s+((?:[0-9]{4}\s+[0-9.]+(?:,[0-9]{2})?\s+)+)')
foreach ($m in [regex]::Matches($bloque.Groups[1].Value, '([0-9]{4})\s+([0-9.]+(?:,[0-9]{2})?)')) { $seguro[[int]$m.Groups[1].Value] = Importe $m.Groups[2].Value }

$aniosHum = @($pdfDed.Keys | Where-Object { $pdfEsc.ContainsKey($_) } | Sort-Object -Descending | Select-Object -First $anios)
if ($aniosHum.Count -eq 0) { throw "No se encontraron las tablas anuales de personas humanas en ARCA. Revisar si cambio la pagina." }
$humanas = foreach ($a in $aniosHum) {
  [ordered]@{
    anio            = $a
    escala          = Leer-Escala $pdfEsc[$a] @(5, 9, 12, 15, 19, 23, 27, 31, 35)
    deducciones     = Leer-Deducciones $pdfDed[$a]
    seguroVida      = $(if ($seguro.ContainsKey($a)) { $seguro[$a] } else { $null })
    pdfEscala       = $pdfEsc[$a]
    pdfDeducciones  = $pdfDed[$a]
  }
}

# --- Personas juridicas ---
$pagPJ = "$base/gananciasYBienes/ganancias/personas-juridicas/determinacion/escala.asp"
$pdfPJ = Pdfs-Por-Anio $pagPJ 'Escala-PJ-([0-9]{4})\.pdf$'
$aniosPJ = @($pdfPJ.Keys | Sort-Object -Descending | Select-Object -First $anios)
if ($aniosPJ.Count -eq 0) { throw "No se encontro la escala de personas juridicas en ARCA. Revisar si cambio la pagina." }
$juridicas = foreach ($a in $aniosPJ) {
  [ordered]@{ anio = $a; escala = Leer-Escala $pdfPJ[$a] @(25, 30, 35); pdf = $pdfPJ[$a] }
}

$datos = [ordered]@{ humanas = @($humanas); juridicas = @($juridicas) }
[IO.File]::WriteAllText((Join-Path $carpeta 'ganancias.json'), (ConvertTo-Json $datos -Depth 8), (New-Object Text.UTF8Encoding $false))
Write-Output "Ganancias: personas humanas $($aniosHum -join ', '); personas juridicas $($aniosPJ -join ', ')."
