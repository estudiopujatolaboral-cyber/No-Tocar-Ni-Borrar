# Lee de ARCA los valores del Impuesto sobre los Bienes Personales y guarda los 2 periodos mas nuevos
# en datos/bienes-personales.json (lo usa datos-tabla-bienes-personales.html):
#   - minimo no imponible y monto de casa-habitacion (pagina "Que es");
#   - escala general y escala para contribuyentes cumplidores (pagina "Alicuotas").
# Cuando ARCA publica un periodo nuevo (por ejemplo 2026), queda ese y el anterior; el mas viejo deja de mostrarse.
# Antes de guardar controla que cada escala empiece en 0, sea continua y termine "en adelante"; si algo
# no cierra, falla y el archivo queda como estaba.
# Lo ejecuta todos los dias la tarea .github/workflows/actualizar-datos.yml.
param([int]$periodos = 2)
$ErrorActionPreference = 'Stop'
$base = 'https://www.arca.gob.ar/gananciasYBienes/bienes-personales/conceptos-basicos'
$carpeta = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../datos'))

# Texto plano de la pagina; cada celda de tabla termina en "|".
function Texto($url) {
  $h = [Text.Encoding]::UTF8.GetString((Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 60).RawContentStream.ToArray())
  $h = $h -replace '<script[\s\S]*?</script>', '' -replace '<style[\s\S]*?</style>', '' -replace '</t[dh]>', ' | ' -replace '<[^>]+>', ' '
  [Net.WebUtility]::HtmlDecode($h) -replace '\s+', ' '
}
function Importe($s) { if ($s -eq '-') { [decimal]0 } else { [decimal](($s -replace '[$\s.%]', '') -replace ',', '.') } }

# --- Minimo no imponible y casa-habitacion por periodo ---
$queEs = Texto "$base/que-es.asp"
$minimos = @{}
foreach ($m in [regex]::Matches($queEs, 'Per\S{1,2}odo(?: fiscal)?\s+([0-9]{4})\s*:\s*\$\s*([0-9.,]+)\s+Inmuebles destinados a casa-habitaci\S{1,2}n:.*?inferior a\s*\$\s*([0-9.,]*[0-9])', 'IgnoreCase')) {
  $a = [int]$m.Groups[1].Value
  if (-not $minimos.ContainsKey($a)) { $minimos[$a] = @{ mni = Importe $m.Groups[2].Value; casa = Importe $m.Groups[3].Value } }
}

# --- Escalas por periodo ---
# Cada fila son 5 celdas: mas de, hasta (o "en adelante"), pagaran, mas el %, sobre el excedente de ("-" = 0).
function Leer-Escala($texto, $donde) {
  $celdas = @($texto -split '\|' | ForEach-Object { $_.Trim() } | Where-Object { $_ -match '^(-|[0-9.]+(,[0-9]+)?%?|en adelante)$' })
  if ($celdas.Count -eq 0 -or $celdas.Count % 5 -ne 0) { throw "No se pudo leer la escala $donde. Revisar la pagina de ARCA." }
  $filas = for ($k = 0; $k -lt $celdas.Count; $k += 5) {
    if ($celdas[$k + 3] -notmatch '%$') { throw "La escala $donde no tiene la alicuota donde se esperaba. Revisar la pagina de ARCA." }
    [ordered]@{
      desde     = Importe $celdas[$k]
      hasta     = $(if ($celdas[$k + 1] -match '^en adelante$') { $null } else { Importe $celdas[$k + 1] })
      fijo      = Importe $celdas[$k + 2]
      alicuota  = Importe $celdas[$k + 3]
      excedente = Importe $celdas[$k + 4]
    }
  }
  $filas = @($filas)
  if ($filas[0].desde -ne 0 -or $null -ne $filas[-1].hasta) { throw "La escala $donde no empieza en 0 o no termina 'en adelante'. Revisar la pagina de ARCA." }
  for ($k = 1; $k -lt $filas.Count; $k++) { if ($filas[$k].desde -ne $filas[$k - 1].hasta) { throw "La escala $donde no es continua. Revisar la pagina de ARCA." } }
  $filas
}

$alic = Texto "$base/alicuotas.asp"
$fin = [regex]::Match($alic, 'Sujetos adheridos al REIBP|Per\S{1,2}odos \d{4} y \d{4}', 'IgnoreCase')
if ($fin.Success) { $alic = $alic.Substring(0, $fin.Index) }
$secciones = [regex]::Matches($alic, 'Tabla general per\S{1,2}odo\s+([0-9]{4})', 'IgnoreCase')
$escalas = @{}
for ($s = 0; $s -lt $secciones.Count; $s++) {
  $a = [int]$secciones[$s].Groups[1].Value
  $desde = $secciones[$s].Index + $secciones[$s].Length
  $hasta = $(if ($s + 1 -lt $secciones.Count) { $secciones[$s + 1].Index } else { $alic.Length })
  $sec = $alic.Substring($desde, $hasta - $desde)
  # El texto del minimo ("que exceda de $384.728.044,57") va antes de la tabla: se corta en el primer encabezado.
  $sec = $sec.Substring([Math]::Max(0, $sec.IndexOf('|')))
  $c = [regex]::Match($sec, 'Contribuyentes cumplidores', 'IgnoreCase')
  if (-not $c.Success) { throw "No se encontro la escala de contribuyentes cumplidores del periodo $a. Revisar la pagina de ARCA." }
  $cump = $sec.Substring($c.Index)
  $cump = $cump.Substring([Math]::Max(0, $cump.IndexOf('|')))
  $escalas[$a] = @{ general = Leer-Escala $sec.Substring(0, $c.Index) "general $a"; cumplidores = Leer-Escala $cump "cumplidores $a" }
}

$anios = @($escalas.Keys | Where-Object { $minimos.ContainsKey($_) } | Sort-Object -Descending | Select-Object -First $periodos)
if ($anios.Count -eq 0) { throw "No se encontraron periodos completos de Bienes Personales en ARCA. Revisar si cambio la pagina." }
$datos = [ordered]@{
  periodos = @(foreach ($a in $anios) {
    [ordered]@{ anio = $a; minimo = $minimos[$a].mni; casaHabitacion = $minimos[$a].casa; escala = $escalas[$a].general; cumplidores = $escalas[$a].cumplidores }
  })
}
[IO.File]::WriteAllText((Join-Path $carpeta 'bienes-personales.json'), (ConvertTo-Json $datos -Depth 8), (New-Object Text.UTF8Encoding $false))
Write-Output "Bienes Personales: periodos $($anios -join ', ')."
