# Genera, por cada datos/*.json, un datos/*.js que carga los mismos datos en window.DATOS["nombre"].
# Las paginas cargan los .js con <script src>, que funciona tambien abriendo el archivo con doble clic
# (el navegador no deja leer .json de la carpeta en ese caso). Los .json quedan como fuente para los scripts.
# Lo ejecuta todos los dias la tarea .github/workflows/actualizar-datos.yml, despues de actualizar los datos.
$ErrorActionPreference = 'Stop'
$carpeta = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../datos'))
$utf8 = New-Object Text.UTF8Encoding $false

foreach ($f in Get-ChildItem (Join-Path $carpeta '*.json')) {
  $json = [IO.File]::ReadAllText($f.FullName, $utf8).TrimStart([char]0xFEFF).Trim()
  $null = $json | ConvertFrom-Json   # si el archivo no es JSON valido, falla aca y no se genera un .js roto
  $js = "window.DATOS = window.DATOS || {};`nwindow.DATOS[""$($f.BaseName)""] = $json;`n"
  [IO.File]::WriteAllText([IO.Path]::ChangeExtension($f.FullName, '.js'), $js, $utf8)
  Write-Output "datos/$($f.BaseName).js generado."
}
