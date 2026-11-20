# Lee el calendario de la Comision Arbitral (Convenio Multilateral) y guarda en datos/convenio.json
# los vencimientos de SIFERE: anticipos mensuales por terminacion de CUIT y la DDJJ anual (CM05).
# Revisa desde dos meses atras hasta un anio adelante; lo ya guardado se conserva.
# Formato: { "anticipos": { "2026-11": { "0-1-2": "2026-11-17", ... } }, "anual": { "2026-06": "2026-06-30" } }
# Lo ejecuta todos los dias la tarea .github/workflows/actualizar-datos.yml.
# -mesesAtras permite cargar meses anteriores una sola vez (por ejemplo, -mesesAtras 12).
param([int]$mesesAtras = 2)
$ErrorActionPreference = 'Stop'
$archivo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../datos/convenio.json'))
$utf8 = New-Object Text.UTF8Encoding $false
$meses = @{ enero = 1; febrero = 2; marzo = 3; abril = 4; mayo = 5; junio = 6; julio = 7; agosto = 8;
            septiembre = 9; setiembre = 9; octubre = 10; noviembre = 11; diciembre = 12 }
$grupos = @{ '0 a 2' = '0-1-2'; '3 a 5' = '3-4-5'; '6 a 7' = '6-7'; '8 a 9' = '8-9' }

$anticipos = [ordered]@{}; $anual = [ordered]@{}
if (Test-Path $archivo) {
  $previo = [IO.File]::ReadAllText($archivo, $utf8) | ConvertFrom-Json
  foreach ($m in $previo.anticipos.PSObject.Properties) {
    $anticipos[$m.Name] = [ordered]@{}
    foreach ($g in $m.Value.PSObject.Properties) { $anticipos[$m.Name][$g.Name] = $g.Value }
  }
  foreach ($m in $previo.anual.PSObject.Properties) { $anual[$m.Name] = $m.Value }
}

$leidos = 0
$inicio = (Get-Date -Day 1).AddMonths(-$mesesAtras)
for ($i = 0; $i -le $mesesAtras + 12; $i++) {
  $mes = $inicio.AddMonths($i)
  $url = 'https://www.ca.gob.ar/servicios/calendario/eventospormes/{0}/{1:D2}/-' -f $mes.Year, $mes.Month
  $html = [Net.WebUtility]::HtmlDecode((Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 60).Content)
  # Cada evento: <div class="jevtt_title" ...>SIFERE - VENCIMIENTO ...</div>" data-bs-content="<div class="jevtt_text" >Martes, 17 Noviembre 2026
  foreach ($e in [regex]::Matches($html, 'jevtt_title"[^>]*>\s*(SIFERE[^<]*?)\s*</div>" data-bs-content="<div class="jevtt_text" >\s*\w+, (\d+) (\p{L}+) (\d{4})')) {
    $titulo = $e.Groups[1].Value
    $fecha = '{0}-{1:D2}-{2:D2}' -f $e.Groups[4].Value, $meses[$e.Groups[3].Value.ToLower()], [int]$e.Groups[2].Value
    $clave = $fecha.Substring(0, 7)
    if ($titulo -match 'Anticipo .*Terminaci\S+ CUIT (\d a \d)' -and $grupos[$Matches[1]]) {
      if (-not $anticipos.Contains($clave)) { $anticipos[$clave] = [ordered]@{} }
      $anticipos[$clave][$grupos[$Matches[1]]] = $fecha
      $leidos++
    } elseif ($titulo -match 'ANUAL|CM ?05') {
      $anual[$clave] = $fecha
      $leidos++
    }
  }
}
if ($leidos -eq 0) { throw 'No se encontro ningun vencimiento de SIFERE en el calendario de la Comision Arbitral. Revisar si cambio el formato.' }

# Se escribe a mano, ordenado, para que el archivo solo cambie cuando cambian los datos.
$orden = '0-1-2', '3-4-5', '6-7', '8-9'
$lineasA = foreach ($k in ($anticipos.Keys | Sort-Object)) {
  $g = foreach ($gr in $orden) { if ($anticipos[$k][$gr]) { '"{0}": "{1}"' -f $gr, $anticipos[$k][$gr] } }
  '    "{0}": {{ {1} }}' -f $k, ($g -join ', ')
}
$lineasB = foreach ($k in ($anual.Keys | Sort-Object)) { '    "{0}": "{1}"' -f $k, $anual[$k] }
$json = "{`n  ""anticipos"": {`n" + ($lineasA -join ",`n") + "`n  },`n  ""anual"": {`n" + ($lineasB -join ",`n") + "`n  }`n}`n"
[IO.File]::WriteAllText($archivo, $json, $utf8)
Write-Output "Convenio Multilateral: $leidos vencimientos leidos de la Comision Arbitral."
