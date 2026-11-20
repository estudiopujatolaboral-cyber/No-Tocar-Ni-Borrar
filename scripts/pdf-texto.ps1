# Funcion para extraer el texto de un PDF sin programas externos, agrupado en renglones.
# Sirve para PDFs simples como los que publica ARCA (texto con fuentes que traen tabla ToUnicode,
# streams comprimidos con FlateDecode). Devuelve una lista de renglones por pagina; cada renglon es una
# lista de fragmentos con su posicion x, ordenados de izquierda a derecha.
# Se usa con: . (Join-Path $PSScriptRoot 'pdf-texto.ps1'); $paginas = Leer-TextoPdf $bytes

function Leer-TextoPdf([byte[]]$bytes) {
  $latin = [Text.Encoding]::GetEncoding(28591)
  $s = $latin.GetString($bytes)

  # Objetos del PDF: numero -> texto del diccionario y posicion del stream (si tiene).
  $objs = @{}
  foreach ($m in [regex]::Matches($s, '(?s)(\d+)\s+0\s+obj\b(.*?)\bendobj')) {
    $objs[[int]$m.Groups[1].Value] = @{ cuerpo = $m.Groups[2].Value; inicio = $m.Groups[2].Index }
  }

  $leerStream = {
    param($n)
    $o = $objs[$n]; if (-not $o) { return $null }
    $c = $o.cuerpo
    $k = [regex]::Match($c, 'stream\r?\n'); if (-not $k.Success) { return $null }
    $dic = $c.Substring(0, $k.Index)
    $lm = [regex]::Match($dic, '/Length\s+(\d+)(\s+0\s+R)?')
    $largo = [int]$lm.Groups[1].Value
    if ($lm.Groups[2].Success) { $largo = [int]([regex]::Match($objs[$largo].cuerpo, '\d+').Value) }
    $ini = $o.inicio + $k.Index + $k.Length
    $datos = New-Object byte[] $largo
    [Array]::Copy($bytes, $ini, $datos, 0, $largo)
    if ($dic -notmatch '/FlateDecode') { return $latin.GetString($datos) }
    $ms = New-Object IO.MemoryStream(, $datos); $ms.Position = 2   # se saltea el encabezado zlib
    $z = New-Object IO.Compression.DeflateStream($ms, [IO.Compression.CompressionMode]::Decompress)
    $out = New-Object IO.MemoryStream
    $z.CopyTo($out)
    $latin.GetString($out.ToArray())
  }

  # Tablas ToUnicode de cada fuente: numero de objeto de la fuente -> @{ bytes; mapa }.
  $cmaps = @{}
  foreach ($n in @($objs.Keys)) {
    $c = $objs[$n].cuerpo
    if ($c -notmatch '/Type\s*/Font' -or $c -notmatch '/ToUnicode\s+(\d+)\s+0\s+R') { continue }
    $cm = & $leerStream ([int]$Matches[1])
    $mapa = @{}
    $hex2txt = { param($h) $t = ''; for ($i = 0; $i -lt $h.Length; $i += 4) { $t += [char][Convert]::ToInt32($h.Substring($i, 4), 16) }; $t }
    foreach ($b in [regex]::Matches($cm, '(?s)beginbfchar(.*?)endbfchar')) {
      foreach ($p in [regex]::Matches($b.Groups[1].Value, '<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>')) {
        $mapa[[Convert]::ToInt32($p.Groups[1].Value, 16)] = & $hex2txt $p.Groups[2].Value
      }
    }
    foreach ($b in [regex]::Matches($cm, '(?s)beginbfrange(.*?)endbfrange')) {
      foreach ($p in [regex]::Matches($b.Groups[1].Value, '<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>\s*<([0-9A-Fa-f]+)>')) {
        $a = [Convert]::ToInt32($p.Groups[1].Value, 16); $z2 = [Convert]::ToInt32($p.Groups[2].Value, 16); $d = [Convert]::ToInt32($p.Groups[3].Value, 16)
        for ($i = $a; $i -le $z2; $i++) { $mapa[$i] = [string][char]($d + $i - $a) }
      }
    }
    $cod = [regex]::Match($cm, 'begincodespacerange\s*<([0-9A-Fa-f]+)>')
    $cmaps[$n] = @{ bytes = $(if ($cod.Success) { $cod.Groups[1].Value.Length / 2 } else { 1 }); mapa = $mapa }
  }

  # Nombre de recurso de fuente (/F1, /TT0...) -> numero de objeto de la fuente.
  $fuentes = @{}
  foreach ($n in @($objs.Keys)) {
    foreach ($f in [regex]::Matches($objs[$n].cuerpo, '/Font\s*(<<(?:(?!>>).)*>>|\d+\s+0\s+R)', 'Singleline')) {
      $dicF = $f.Groups[1].Value
      if ($dicF -match '^(\d+)\s+0\s+R') { $dicF = $objs[[int]$Matches[1]].cuerpo }
      foreach ($e in [regex]::Matches($dicF, '/([^\s/<>\[\]]+)\s+(\d+)\s+0\s+R')) { $fuentes[$e.Groups[1].Value] = [int]$e.Groups[2].Value }
    }
  }

  $decodificar = {
    param($tok, $cmap)
    if ($tok.StartsWith('<')) {
      $h = ($tok.Trim('<', '>') -replace '\s', '')
      $raw = New-Object byte[] ($h.Length / 2)
      for ($i = 0; $i -lt $raw.Length; $i++) { $raw[$i] = [Convert]::ToByte($h.Substring($i * 2, 2), 16) }
    } else {
      $t = $tok.Substring(1, $tok.Length - 2)
      $t = [regex]::Replace($t, '\\([0-7]{1,3}|.)', { param($m) $v = $m.Groups[1].Value; if ($v -match '^[0-7]+$') { [string][char][Convert]::ToInt32($v, 8) } else { switch ($v) { 'n' { "`n" } 'r' { "`r" } 't' { "`t" } default { $v } } } })
      $raw = $latin.GetBytes($t)
    }
    if (-not $cmap) { return $latin.GetString($raw) }
    $txt = ''
    for ($i = 0; $i -lt $raw.Length; $i += $cmap.bytes) {
      $code = if ($cmap.bytes -eq 2) { [int]$raw[$i] * 256 + $raw[$i + 1] } else { [int]$raw[$i] }
      if ($cmap.mapa.ContainsKey($code)) { $txt += $cmap.mapa[$code] }
    }
    $txt
  }

  # Paginas en orden de aparicion y sus streams de contenido.
  $paginas = @()
  foreach ($n in ($objs.Keys | Sort-Object)) {
    $c = $objs[$n].cuerpo
    if ($c -notmatch '/Type\s*/Page\b') { continue }
    $cont = [regex]::Match($c, '/Contents\s*(\[[^\]]*\]|\d+\s+0\s+R)').Groups[1].Value
    $texto = (([regex]::Matches($cont, '(\d+)\s+0\s+R') | ForEach-Object { & $leerStream ([int]$_.Groups[1].Value) }) -join "`n")

    $items = New-Object System.Collections.ArrayList
    $tokens = [regex]::Matches($texto, '<[0-9A-Fa-f\s]*>|\((?:\\.|[^\\)])*\)|\[|\]|/[^\s/\[\]()<>]+|[-+]?(?:\d+\.?\d*|\.\d+)|[A-Za-z\*''"]+')
    $pila = New-Object System.Collections.ArrayList
    $cmap = $null; $lx = 0.0; $ly = 0.0; $a = 1.0; $d = 1.0; $tl = 0.0
    foreach ($tk in $tokens) {
      $v = $tk.Value
      switch -regex ($v) {
        '^BT$' { $lx = 0.0; $ly = 0.0; $a = 1.0; $d = 1.0; $pila.Clear(); break }
        '^Tf$' { $cmap = $cmaps[$fuentes[$pila[$pila.Count - 2].TrimStart('/')]]; $pila.Clear(); break }
        '^Tm$' { $a = [double]$pila[$pila.Count - 6]; $d = [double]$pila[$pila.Count - 3]; $lx = [double]$pila[$pila.Count - 2]; $ly = [double]$pila[$pila.Count - 1]; $pila.Clear(); break }
        '^T[dD]$' { $tx = [double]$pila[$pila.Count - 2]; $ty = [double]$pila[$pila.Count - 1]; $lx += $tx * $a; $ly += $ty * $d; if ($v -eq 'TD') { $tl = -$ty }; $pila.Clear(); break }
        '^TL$' { $tl = [double]$pila[$pila.Count - 1]; $pila.Clear(); break }
        '^T\*$' { $ly -= $tl * $d; $pila.Clear(); break }
        '^(Tj|TJ|''|")$' {
          if ($v -ne 'Tj' -and $v -ne 'TJ') { $ly -= $tl * $d }
          $partes = @($pila | Where-Object { $_ -match '^[<(]' -or $_ -match '^-?\d' })
          $t = ''
          foreach ($p in $partes) {
            if ($p -match '^[<(]') { $t += & $decodificar $p $cmap }
            elseif ($v -eq 'TJ' -and [double]$p -lt -200) { $t += ' ' }
          }
          if ($t.Trim()) { [void]$items.Add([pscustomobject]@{ x = [Math]::Round($lx, 1); y = [Math]::Round($ly, 1); t = $t }) }
          $pila.Clear(); break
        }
        '^\[$|^\]$' { break }
        '^[A-Za-z\*''"]+$' { $pila.Clear(); break }
        default { [void]$pila.Add($v) }
      }
    }

    # Renglones: fragmentos con la misma altura (tolerancia de 2 puntos), de arriba hacia abajo.
    $renglones = @()
    foreach ($it in ($items | Sort-Object { -$_.y }, x)) {
      if ($renglones.Count -and [Math]::Abs($renglones[-1].y - $it.y) -le 2) { $renglones[-1].partes += $it }
      else { $renglones += [pscustomobject]@{ y = $it.y; partes = @($it) } }
    }
    foreach ($r in $renglones) { $r.partes = @($r.partes | Sort-Object x) }
    $paginas += , $renglones
  }
  , $paginas
}
