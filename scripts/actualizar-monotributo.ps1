# Lee el cuadro de categorias vigentes del Monotributo de la pagina oficial de ARCA
# (https://www.arca.gob.ar/monotributo/categorias.asp) y lo guarda en datos/monotributo.json
# (lo usa datos-categorias-monotributo.html). ARCA actualiza los valores dos veces por anio.
# Antes de guardar controla que esten las 11 categorias y que los totales cierren; si algo no cierra,
# falla y el archivo queda como estaba.
# Lo ejecuta todos los dias la tarea .github/workflows/actualizar-datos.yml.
$ErrorActionPreference = 'Stop'
$url = 'https://www.arca.gob.ar/monotributo/categorias.asp'
$carpeta = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../datos'))

$bytes = (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 60).RawContentStream.ToArray()
$html = [regex]::Replace([Text.Encoding]::UTF8.GetString($bytes), '<!--.*?-->', '', 'Singleline')

$vigencia = [regex]::Match($html, 'Valores de aplicaci\S+ desde el\s*([0-9]{1,2}/[0-9]{1,2}/[0-9]{4})')
if (-not $vigencia.Success) { throw "No se encontro la fecha de vigencia en la pagina de ARCA. Revisar si cambio el formato." }
$tbody = [regex]::Match($html, '<tbody>(.*?)</tbody>', 'Singleline').Groups[1].Value

function Texto($s) { ([Net.WebUtility]::HtmlDecode(($s -replace '<[^>]+>', ''))).Trim() }
function Importe($s) { [decimal]((Texto $s) -replace '[$\s.]', '' -replace ',', '.') }

$categorias = @()
foreach ($fila in [regex]::Matches($tbody, '<tr>(.*?)</tr>', 'Singleline')) {
  $cat = Texto ([regex]::Match($fila.Groups[1].Value, '<th[^>]*>(.*?)</th>', 'Singleline').Groups[1].Value)
  $c = @([regex]::Matches($fila.Groups[1].Value, '<td[^>]*>(.*?)</td>', 'Singleline') | ForEach-Object { $_.Groups[1].Value })
  if ($c.Count -ne 11) { throw "La categoria $cat tiene $($c.Count) columnas y se esperaban 11. Revisar si cambio el formato." }
  $categorias += [ordered]@{
    categoria      = $cat
    ingresos       = Importe $c[0]
    superficie     = Texto $c[1]
    energia        = Texto $c[2]
    alquileres     = Importe $c[3]
    precioUnitario = Importe $c[4]
    impServicios   = Importe $c[5]
    impVentas      = Importe $c[6]
    sipa           = Importe $c[7]
    obraSocial     = Importe $c[8]
    totalServicios = Importe $c[9]
    totalVentas    = Importe $c[10]
  }
}

if ($categorias.Count -ne 11 -or $categorias[0].categoria -ne 'A' -or $categorias[10].categoria -ne 'K') {
  throw "Se esperaban las categorias A a K y se leyeron $($categorias.Count). Revisar si cambio el formato."
}
foreach ($k in $categorias) {
  $aportes = $k.sipa + $k.obraSocial
  if ([Math]::Abs($k.impServicios + $aportes - $k.totalServicios) -gt 0.05 -or [Math]::Abs($k.impVentas + $aportes - $k.totalVentas) -gt 0.05) {
    throw "Los totales de la categoria $($k.categoria) no cierran. Revisar la lectura de la pagina de ARCA."
  }
}

$datos = [ordered]@{
  vigencia   = $vigencia.Groups[1].Value
  fuente     = $url
  categorias = $categorias
}
[IO.File]::WriteAllText((Join-Path $carpeta 'monotributo.json'), (ConvertTo-Json $datos -Depth 5), (New-Object Text.UTF8Encoding $false))
Write-Output "Monotributo: categorias vigentes desde el $($datos.vigencia)."
