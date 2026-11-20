# Lee los vencimientos del mes que publica ARCA (vencimientos.xml) y los suma a datos/vencimientos.json.
# ARCA muestra solo el mes en curso, por eso cada mes se guarda acá: quedan las fechas oficiales,
# incluidas las prorrogas, de todos los impuestos que publica.
# Formato: { "Autonomos | Pago mensual": { "2026-11": { "0-1-2-3": "2026-11-05", ... } }, ... }
# Lo ejecuta todos los dias la tarea .github/workflows/actualizar-datos.yml.
$ErrorActionPreference = 'Stop'
$url = 'https://www.arca.gob.ar/vencimientos/xml/vencimientos.xml'
$archivo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../datos/vencimientos.json'))
$utf8 = New-Object Text.UTF8Encoding $false

$datos = [ordered]@{}
if (Test-Path $archivo) {
  foreach ($imp in ([IO.File]::ReadAllText($archivo, $utf8) | ConvertFrom-Json).PSObject.Properties) {
    $datos[$imp.Name] = [ordered]@{}
    foreach ($mes in $imp.Value.PSObject.Properties) {
      $datos[$imp.Name][$mes.Name] = [ordered]@{}
      foreach ($g in $mes.Value.PSObject.Properties) { $datos[$imp.Name][$mes.Name][$g.Name] = $g.Value }
    }
  }
}

$xml = New-Object Xml.XmlDocument
$xml.Load((New-Object IO.MemoryStream (, (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 60).RawContentStream.ToArray())))
$items = $xml.SelectNodes('//item')
if ($items.Count -eq 0) { throw 'El archivo de vencimientos de ARCA no trae ningun item. Revisar si cambio el formato.' }

$total = 0
foreach ($it in $items) {
  $html = $it.SelectSingleNode('descripcion').InnerText
  $detalle = ($html -split '<')[0].Trim()   # texto antes de la tabla, por ejemplo "Pago mensual"
  $clave = $it.SelectSingleNode('titulo').InnerText.Trim() + ' | ' + $detalle
  $filas = [regex]::Matches($html, '<td>\s*([^<]+?)\s*</td>\s*<td>\s*(\d{2})/(\d{2})/(\d{4})\s*</td>')
  if ($filas.Count -eq 0) { continue }
  $mes = '{0}-{1}' -f $filas[0].Groups[4].Value, $filas[0].Groups[3].Value
  if (-not $datos.Contains($clave)) { $datos[$clave] = [ordered]@{} }
  $grupos = [ordered]@{}
  foreach ($f in $filas) { $grupos[$f.Groups[1].Value] = '{0}-{1}-{2}' -f $f.Groups[4].Value, $f.Groups[3].Value, $f.Groups[2].Value }
  $datos[$clave][$mes] = $grupos
  $total++
}

# Se escribe a mano, ordenado, para que el archivo solo cambie cuando cambian los datos.
$texto = { param($s) '"' + ($s -replace '\\', '\\' -replace '"', '\"') + '"' }
$bloques = foreach ($imp in ($datos.Keys | Sort-Object)) {
  $meses = foreach ($mes in ($datos[$imp].Keys | Sort-Object)) {
    $g = foreach ($k in $datos[$imp][$mes].Keys) { '{0}: {1}' -f (& $texto $k), (& $texto $datos[$imp][$mes][$k]) }
    '    {0}: {{ {1} }}' -f (& $texto $mes), ($g -join ', ')
  }
  "  $(& $texto $imp): {`n" + ($meses -join ",`n") + "`n  }"
}
[IO.File]::WriteAllText($archivo, "{`n" + ($bloques -join ",`n") + "`n}`n", $utf8)
Write-Output "Vencimientos: $total items leidos de ARCA."
