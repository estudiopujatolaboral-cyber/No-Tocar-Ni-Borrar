# Lee de la pagina de API Santa Fe las categorias del Regimen Simplificado de Ingresos Brutos
# (tramos de ingresos y cuota mensual) y las guarda en datos/iibb-santafe.json (lo usa datos-regimen-iibb.html).
# API las actualiza cada semestre (enero y julio). Cuando cambia el semestre, el anterior se guarda como "anterior"
# para poder compararlo.
# Antes de guardar controla que las categorias sean correlativas (1, 2, 3...) y que los tramos sean continuos;
# si algo no cierra, falla y el archivo queda como estaba.
# Lo ejecuta todos los dias la tarea .github/workflows/actualizar-datos.yml.
$ErrorActionPreference = 'Stop'
$url = 'https://www.santafe.gob.ar/index.php/web/content/view/full/211373/(subtema)/102284'
$archivo = Join-Path ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../datos'))) 'iibb-santafe.json'

$h = [Text.Encoding]::UTF8.GetString((Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 60).RawContentStream.ToArray())
$h = $h -replace '<script[\s\S]*?</script>', '' -replace '<style[\s\S]*?</style>', ''
$texto = [Net.WebUtility]::HtmlDecode(($h -replace '<[^>]+>', ' ')) -replace '\s+', ' '
function Importe($s) { [decimal](($s -replace '[$\s.]', '') -replace ',', '.') }

$titulo = [regex]::Match($texto, 'Categor\S{1,2}as de r\S{1,2}gimen simplificado\s*-\s*([^.]+?)\s+La Resoluci', 'IgnoreCase')
if (-not $titulo.Success) { throw "No se encontro el titulo de las categorias en $url. Revisar si cambio la pagina." }
$periodo = $titulo.Groups[1].Value.Trim()
$res = [regex]::Match($texto, 'Resoluci\S{1,2}n (?:Provincial|General)?\s*(?:N\S{1,2}\s*)?([0-9]{3,4}/[0-9]{4})', 'IgnoreCase')
$resolucion = $(if ($res.Success) { $res.Groups[1].Value } else { '' })

# Tabla: la primera <table> despues del titulo; filas de 4 celdas (categoria, desde, hasta, importe mensual).
$desdeTabla = $h.IndexOf('gimen simplificado - ')
if ($desdeTabla -lt 0) { $desdeTabla = 0 }
$tabla = [regex]::Match($h.Substring($desdeTabla), '<table[\s\S]*?</table>', 'IgnoreCase')
if (-not $tabla.Success) { throw "No se encontro la tabla de categorias en $url." }
$categorias = New-Object System.Collections.ArrayList
foreach ($tr in [regex]::Matches($tabla.Value, '<tr[\s\S]*?</tr>', 'IgnoreCase')) {
  $c = @([regex]::Matches($tr.Value, '<t[dh][^>]*>([\s\S]*?)</t[dh]>', 'IgnoreCase') | ForEach-Object {
    ([Net.WebUtility]::HtmlDecode(($_.Groups[1].Value -replace '<[^>]+>', ' ')) -replace '\s+', ' ').Trim()
  })
  if ($c.Count -lt 4 -or $c[0] -notmatch '^[0-9]+$') { continue }
  [void]$categorias.Add([ordered]@{ categoria = [int]$c[0]; desde = Importe $c[1]; hasta = Importe $c[2]; cuota = Importe $c[3] })
}

if ($categorias.Count -lt 5) { throw "Se leyeron solo $($categorias.Count) categorias en $url. Revisar la pagina de API." }
for ($k = 0; $k -lt $categorias.Count; $k++) {
  if ($categorias[$k].categoria -ne $k + 1) { throw "Las categorias de API no son correlativas. Revisar la pagina." }
  if ($k -gt 0 -and [math]::Abs($categorias[$k].desde - $categorias[$k - 1].hasta - 0.01) -gt 0.011) { throw "Los tramos de la categoria $($k + 1) no son continuos. Revisar la pagina de API." }
  if ($categorias[$k].hasta -le $categorias[$k].desde -or $categorias[$k].cuota -le 0) { throw "La categoria $($k + 1) tiene importes invalidos. Revisar la pagina de API." }
}

$nuevo = [ordered]@{ periodo = $periodo; resolucion = $resolucion; tope = $categorias[-1].hasta; categorias = @($categorias) }

# Si cambio el semestre, el que estaba pasa a "anterior"; si no, se conserva el anterior que ya habia.
$anterior = $null
if (Test-Path $archivo) {
  $viejo = Get-Content $archivo -Raw -Encoding UTF8 | ConvertFrom-Json
  if ($viejo.vigente.periodo -ne $periodo) { $anterior = $viejo.vigente } else { $anterior = $viejo.anterior }
}
$datos = [ordered]@{ fuente = $url; vigente = $nuevo; anterior = $anterior }
[IO.File]::WriteAllText($archivo, (ConvertTo-Json $datos -Depth 6), (New-Object Text.UTF8Encoding $false))
Write-Output "IIBB Santa Fe: $periodo (Res. $resolucion), $($categorias.Count) categorias, tope $($nuevo.tope)."
