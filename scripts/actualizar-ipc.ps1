# Lee el archivo del IPC por divisiones que publica el INDEC y guarda en datos/ipc.json:
# - nivel: el índice nacional de cada mes (base dic 2016 = 100), para calcular variaciones con dos decimales;
# - rubros: la variación mensual e interanual de cada división en el último mes publicado.
# Lo ejecuta todos los dias la tarea .github/workflows/actualizar-datos.yml.
$ErrorActionPreference = 'Stop'
$url = 'https://www.indec.gob.ar/ftp/cuadros/economia/serie_ipc_divisiones.csv'
$archivo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../datos/ipc.json'))
$inv = [Globalization.CultureInfo]::InvariantCulture
$numero = { param($t) [decimal]::Parse(($t -replace ',', '.'), $inv) }

$bytes = (Invoke-WebRequest $url -UseBasicParsing -TimeoutSec 120).RawContentStream.ToArray()
$filas = [Text.Encoding]::GetEncoding('iso-8859-1').GetString($bytes) -split "`r?`n" | ConvertFrom-Csv -Delimiter ';' |
  Where-Object { $_.Region -eq 'Nacional' -and $_.Clasificador -like 'Nivel general y divisiones*' -and $_.Indice_IPC }
$general = $filas | Where-Object { $_.Codigo -eq '0' } | Sort-Object Periodo
if (-not $general) { throw 'No se encontro el nivel general nacional en el archivo del INDEC. Revisar si cambio el formato.' }

$ultimo = $general[-1].Periodo
$nivel = $general | ForEach-Object { '    "{0}-{1}": {2}' -f $_.Periodo.Substring(0, 4), $_.Periodo.Substring(4, 2), (& $numero $_.Indice_IPC).ToString($inv) }
$rubros = $filas | Where-Object { $_.Periodo -eq $ultimo -and $_.Codigo -ne '0' } | Sort-Object Codigo | ForEach-Object {
  '    {{ "nombre": "{0}", "mensual": {1}, "interanual": {2} }}' -f ($_.Descripcion -replace '"', ''), (& $numero $_.v_m_IPC).ToString($inv), (& $numero $_.v_i_a_IPC).ToString($inv)
}
if (@($rubros).Count -lt 12) { throw "Se esperaban 12 rubros y se encontraron $(@($rubros).Count)." }

$json = "{`n  ""nivel"": {`n" + ($nivel -join ",`n") + "`n  },`n" +
        "  ""rubros"": {`n    ""periodo"": ""$($ultimo.Substring(0, 4))-$($ultimo.Substring(4, 2))"",`n    ""divisiones"": [`n" +
        (($rubros | ForEach-Object { '  ' + $_ }) -join ",`n") + "`n    ]`n  }`n}`n"
[IO.File]::WriteAllText($archivo, $json, (New-Object Text.UTF8Encoding $false))
Write-Output "IPC: ultimo mes publicado $ultimo ($(@($nivel).Count) meses)."
