# Lee la tabla del RIPTE de la pagina oficial de la Secretaria de Seguridad Social
# y suma los meses nuevos (o corregidos) a datos/ripte.json.
# La pagina oficial muestra solo los ultimos meses, por eso el historial se guarda en el archivo.
# Lo ejecuta todos los dias la tarea .github/workflows/actualizar-datos.yml.
$ErrorActionPreference = 'Stop'
$url = 'https://www.argentina.gob.ar/trabajo/seguridadsocial/ripte'
$archivo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../datos/ripte.json'))
$inv = [Globalization.CultureInfo]::InvariantCulture
$meses = @{ enero = 1; febrero = 2; marzo = 3; abril = 4; mayo = 5; junio = 6; julio = 7; agosto = 8;
            septiembre = 9; setiembre = 9; octubre = 10; noviembre = 11; diciembre = 12 }

$datos = [ordered]@{}
(Get-Content $archivo -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $datos[$_.Name] = [decimal]$_.Value }

# Cada fila de la tabla: <td>Agosto/2026</td><td>$ 1.982.518,19</td>... (antes venia sin barra: Agosto2026)
$html = (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 60).Content
$filas = [regex]::Matches($html, '<td[^>]*>\s*(\p{L}+)[\s/\-]*(\d{4})\s*</td>\s*<td[^>]*>\s*\$\s*([\d\.]+,\d{1,2})\s*</td>')
if ($filas.Count -eq 0) { throw 'No se encontro la tabla del RIPTE en la pagina oficial. Revisar si cambio el formato.' }

$cambios = @()
foreach ($f in $filas) {
  $mes = $meses[$f.Groups[1].Value.ToLower()]
  if (-not $mes) { throw "Mes desconocido en la pagina oficial: $($f.Groups[1].Value)" }
  $k = '{0}-{1:D2}' -f $f.Groups[2].Value, $mes
  $v = [decimal]::Parse(($f.Groups[3].Value -replace '\.', '' -replace ',', '.'), $inv)
  if ($datos[$k] -ne $v) { $datos[$k] = $v; $cambios += "$k = $v" }
}

if (-not $cambios) { Write-Output 'RIPTE: sin datos nuevos.'; exit 0 }

$lineas = $datos.Keys | Sort-Object | ForEach-Object { '  "{0}": {1}' -f $_, $datos[$_].ToString('0.00', $inv) }
[IO.File]::WriteAllText($archivo, "{`n" + ($lineas -join ",`n") + "`n}`n", (New-Object Text.UTF8Encoding $false))
Write-Output "RIPTE actualizado: $($cambios -join ', ')"
