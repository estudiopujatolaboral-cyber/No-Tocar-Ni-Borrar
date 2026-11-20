# Lee de ARCA la tabla "Evolucion de Tasas de Intereses" (resarcitorios y punitorios) y la guarda
# en datos/intereses-arca.json (lo usa datos-intereses-afip.html).
# Cuando el Ministerio de Economia cambia las tasas, ARCA agrega la fila nueva arriba y la pagina la muestra sola.
# Antes de guardar controla que haya filas, que la primera este vigente (hasta 31/12/2999) y que las fechas
# sean continuas; si algo no cierra, falla y el archivo queda como estaba.
# Lo ejecuta todos los dias la tarea .github/workflows/actualizar-datos.yml.
$ErrorActionPreference = 'Stop'
$url = 'https://serviciosweb.afip.gob.ar/genericos/calculointeres/punitorios.aspx'
$carpeta = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../datos'))

$h = [Text.Encoding]::UTF8.GetString((Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 60).RawContentStream.ToArray())
$h = $h -replace '<script[\s\S]*?</script>', '' -replace '<style[\s\S]*?</style>', ''
$inicio = $h.IndexOf('Evoluci')
if ($inicio -lt 0) { throw "No se encontro la tabla de evolucion de tasas en $url. Revisar si cambio la pagina." }
$h = $h.Substring($inicio)

function Fecha($s) { $p = $s.Split('/'); "$($p[2])-$($p[1])-$($p[0])" }   # dd/mm/aaaa -> aaaa-mm-dd
function Num($s) { [decimal]($s.Trim() -replace ',', '.') }

$filas = New-Object System.Collections.ArrayList
$regimen = 'actual'
foreach ($tr in [regex]::Matches($h, '<tr[\s\S]*?</tr>', 'IgnoreCase')) {
  $celdas = @([regex]::Matches($tr.Value, '<t[dh][^>]*>([\s\S]*?)</t[dh]>', 'IgnoreCase') | ForEach-Object {
    ([Net.WebUtility]::HtmlDecode(($_.Groups[1].Value -replace '<[^>]+>', ' ')) -replace '\s+', ' ').Trim()
  })
  if ($celdas -match '^R.gimen Anterior$') { $regimen = 'anterior' }
  # Fila de datos: desde, hasta, norma, res. mensual, res. diario, pun. mensual, pun. diario (puede venir precedida por el rotulo del regimen).
  $c = @($celdas | Where-Object { $_ -notmatch '^R.gimen (Actual|Anterior)$' -and $_ -ne '' })
  if ($c.Count -lt 7 -or $c[0] -notmatch '^[0-9]{2}/[0-9]{2}/[0-9]{4}$' -or $c[1] -notmatch '^[0-9]{2}/[0-9]{2}/[0-9]{4}$') { continue }
  [void]$filas.Add([ordered]@{
    desde        = Fecha $c[0]
    hasta        = $(if ($c[1] -eq '31/12/2999') { $null } else { Fecha $c[1] })
    norma        = $c[2]
    regimen      = $regimen
    resarcMes    = Num $c[3]
    resarcDia    = Num $c[4]
    punitMes     = Num $c[5]
    punitDia     = Num $c[6]
  })
}

if ($filas.Count -lt 20) { throw "Se leyeron solo $($filas.Count) filas de tasas en $url. Revisar la pagina de ARCA." }
if ($null -ne $filas[0].hasta) { throw "La primera fila de la tabla de tasas no esta vigente. Revisar la pagina de ARCA." }
if (@($filas | Where-Object { $null -eq $_.hasta }).Count -ne 1) { throw "Hay mas de una tasa vigente en la tabla de ARCA. Revisar la pagina." }

$datos = [ordered]@{ fuente = $url; tasas = @($filas) }
[IO.File]::WriteAllText((Join-Path $carpeta 'intereses-arca.json'), (ConvertTo-Json $datos -Depth 6), (New-Object Text.UTF8Encoding $false))
Write-Output "Intereses ARCA: $($filas.Count) tasas; vigente desde $($filas[0].desde): resarcitorios $($filas[0].resarcMes)%, punitorios $($filas[0].punitMes)%."
