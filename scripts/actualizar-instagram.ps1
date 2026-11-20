# Lee las ultimas publicaciones de la cuenta de Instagram del estudio (@estudioquacquarini) desde el feed JSON
# de Behold (behold.so), que esta conectado a la cuenta y se encarga de renovar el permiso de Instagram,
# y las guarda en datos/instagram.json (lo usa novedades.html).
# Las fotos se descargan a img/instagram/ (de los videos se guarda la portada) para no depender de Behold
# al mostrar la pagina, y se borran las de publicaciones que ya no se muestran.
# Si el feed falla, el archivo queda como estaba y la pagina sigue mostrando las ultimas publicaciones guardadas.
# Lo ejecuta todos los dias la tarea .github/workflows/actualizar-datos.yml.
param([int]$cantidad = 12)
$ErrorActionPreference = 'Stop'
$feed = 'https://feeds.behold.so/y1RdhwW9tG4xnsvtQg3T'
$raiz = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$carpetaImg = Join-Path $raiz 'img/instagram'
New-Item -ItemType Directory -Force $carpetaImg | Out-Null

$bytes = (Invoke-WebRequest $feed -UseBasicParsing -TimeoutSec 60).RawContentStream.ToArray()
$items = @(([Text.Encoding]::UTF8.GetString($bytes) | ConvertFrom-Json).posts | Select-Object -First $cantidad)
if ($items.Count -eq 0) { throw "El feed de Behold no trae ninguna publicacion. Revisar la conexion con Instagram en behold.so." }

$publicaciones = @()
foreach ($m in $items) {
  $archivo = Join-Path $carpetaImg "$($m.id).jpg"
  if (-not (Test-Path $archivo)) {
    Invoke-WebRequest $m.sizes.medium.mediaUrl -OutFile $archivo -UseBasicParsing -TimeoutSec 60
  }
  # prunedCaption es el texto sin el bloque de hashtags del final.
  $texto = if ($m.prunedCaption) { $m.prunedCaption } else { [string]$m.caption }
  $publicaciones += [ordered]@{
    id     = [string]$m.id
    fecha  = [string]$m.timestamp
    tipo   = $m.mediaType
    texto  = $texto
    link   = $m.permalink
    imagen = "img/instagram/$($m.id).jpg"
  }
}

$ids = $publicaciones | ForEach-Object { $_.id }
Get-ChildItem $carpetaImg -Filter '*.jpg' | Where-Object { $ids -notcontains $_.BaseName } | Remove-Item

# La fecha de actualizacion solo cambia si cambiaron las publicaciones, para no guardar el archivo todos los dias.
$destino = Join-Path $raiz 'datos/instagram.json'
$utf8 = New-Object Text.UTF8Encoding $false
$firma = { param($lista) ($lista | ForEach-Object { "$($_.id)|$($_.texto)" }) -join "`n" }
$anterior = if (Test-Path $destino) { [IO.File]::ReadAllText($destino, $utf8) | ConvertFrom-Json } else { $null }
if (-not $anterior -or (& $firma $publicaciones) -ne (& $firma $anterior.publicaciones)) {
  $datos = [ordered]@{
    cuenta        = 'estudioquacquarini'
    actualizado   = (Get-Date).ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
    publicaciones = $publicaciones
  }
  [IO.File]::WriteAllText($destino, (ConvertTo-Json $datos -Depth 5), $utf8)
  Write-Output "Instagram: $($publicaciones.Count) publicaciones (hubo cambios)."
} else {
  Write-Output "Instagram: sin publicaciones nuevas."
}
