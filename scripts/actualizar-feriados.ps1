# Descarga el calendario oficial de feriados (argentina.gob.ar) del anio en curso y del siguiente
# y lo guarda tal cual en datos/feriados-AAAA.json (lo usa datos-feriados.html).
# Incluye feriados inamovibles, trasladables, dias no laborables, turisticos, feriados locales y las notas legales.
# El del anio siguiente se publica hacia fin de anio: mientras no exista, se omite.
# Lo ejecuta todos los dias la tarea .github/workflows/actualizar-datos.yml.
$ErrorActionPreference = 'Stop'
$carpeta = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../datos'))
$anio = (Get-Date).Year

foreach ($a in $anio, ($anio + 1)) {
  $url = "https://www.argentina.gob.ar/sites/default/files/holidays-$a-es.json"
  try {
    $bytes = (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 60).RawContentStream.ToArray()
  } catch {
    if ($a -eq $anio) { throw "No se pudo descargar el calendario de feriados $a de argentina.gob.ar." }
    Write-Output "Feriados ${a}: todavia no publicado."
    continue
  }
  $texto = [Text.Encoding]::UTF8.GetString($bytes).TrimStart([char]0xFEFF)
  $items = @(($texto | ConvertFrom-Json).mainEntity.itemListElement)
  if ($items.Count -eq 0) { throw "El calendario de feriados $a no trae ningun dia. Revisar si cambio el formato." }
  [IO.File]::WriteAllText((Join-Path $carpeta "feriados-$a.json"), $texto, (New-Object Text.UTF8Encoding $false))
  Write-Output "Feriados ${a}: $($items.Count) dias."
}
