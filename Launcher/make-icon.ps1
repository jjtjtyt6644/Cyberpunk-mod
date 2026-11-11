# Draws the launcher icon (an original design in Cyberpunk-style colours, not
# the game's logo) and writes it as a multi-size .ico next to this script.
#   .\make-icon.ps1            writes icon.ico
#   .\make-icon.ps1 -Preview   also writes icon-preview.png (256 px)

param([switch]$Preview)

$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.Drawing
$root = Split-Path -Parent $MyInvocation.MyCommand.Path

function New-IconBitmap([int]$size) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
    $g.TextRenderingHint = [System.Drawing.Text.TextRenderingHint]::AntiAliasGridFit
    $g.Clear([System.Drawing.Color]::Transparent)
    $s = $size / 256.0

    # Chamfered plate: a square with the top-right and bottom-left corners cut.
    function P([double]$x, [double]$y) { New-Object System.Drawing.PointF ([float]($x * $s)), ([float]($y * $s)) }
    $plate = [System.Drawing.PointF[]]@((P 8 8), (P 196 8), (P 248 60), (P 248 248), (P 60 248), (P 8 196))
    $yellow = [System.Drawing.Color]::FromArgb(255, 252, 238, 10)
    $cyan = [System.Drawing.Color]::FromArgb(255, 0, 240, 255)
    $dark = [System.Drawing.Color]::FromArgb(255, 10, 11, 18)
    $g.FillPolygon((New-Object System.Drawing.SolidBrush $yellow), $plate)

    # Inner dark panel.
    $inner = [System.Drawing.PointF[]]@((P 26 26), (P 188 26), (P 230 68), (P 230 230), (P 68 230), (P 26 188))
    $g.FillPolygon((New-Object System.Drawing.SolidBrush $dark), $inner)

    # A cyan "N" offset behind a yellow "N" gives a glitch look.
    $fontSize = [float](150 * $s)
    $font = New-Object System.Drawing.Font "Bahnschrift", $fontSize, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    if ($font.Name -ne "Bahnschrift") {
        $font = New-Object System.Drawing.Font "Segoe UI", $fontSize, ([System.Drawing.FontStyle]::Bold), ([System.Drawing.GraphicsUnit]::Pixel)
    }
    $fmt = New-Object System.Drawing.StringFormat
    $fmt.Alignment = [System.Drawing.StringAlignment]::Center
    $fmt.LineAlignment = [System.Drawing.StringAlignment]::Center
    $box = New-Object System.Drawing.RectangleF ([float](26 * $s)), ([float](30 * $s)), ([float](204 * $s)), ([float](204 * $s))
    $shift = New-Object System.Drawing.RectangleF ([float](26 * $s - 7 * $s)), ([float](30 * $s + 3 * $s)), ([float](204 * $s)), ([float](204 * $s))
    $g.DrawString("N", $font, (New-Object System.Drawing.SolidBrush $cyan), $shift, $fmt)
    $g.DrawString("N", $font, (New-Object System.Drawing.SolidBrush $yellow), $box, $fmt)

    # Two scan lines through the letter, for larger sizes only.
    if ($size -ge 48) {
        $g.FillRectangle((New-Object System.Drawing.SolidBrush $dark), [float](40 * $s), [float](118 * $s), [float](176 * $s), [float](7 * $s))
        $g.FillRectangle((New-Object System.Drawing.SolidBrush $cyan), [float](150 * $s), [float](168 * $s), [float](58 * $s), [float](5 * $s))
    }
    $g.Dispose()
    return $bmp
}

$sizes = 256, 64, 48, 32, 24, 16
$pngs = @()
foreach ($size in $sizes) {
    $bmp = New-IconBitmap $size
    $ms = New-Object System.IO.MemoryStream
    $bmp.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    if ($Preview -and $size -eq 256) { $bmp.Save((Join-Path $root "icon-preview.png"), [System.Drawing.Imaging.ImageFormat]::Png) }
    $bmp.Dispose()
    $pngs += , $ms.ToArray()
}

# ICO file: header, one directory entry per size, then the PNG images.
$out = New-Object System.IO.MemoryStream
$w = New-Object System.IO.BinaryWriter $out
$w.Write([UInt16]0); $w.Write([UInt16]1); $w.Write([UInt16]$sizes.Count)
$offset = 6 + 16 * $sizes.Count
for ($i = 0; $i -lt $sizes.Count; $i++) {
    $dim = if ($sizes[$i] -ge 256) { 0 } else { $sizes[$i] }
    $w.Write([byte]$dim); $w.Write([byte]$dim); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([UInt16]1); $w.Write([UInt16]32)
    $w.Write([UInt32]$pngs[$i].Length); $w.Write([UInt32]$offset)
    $offset += $pngs[$i].Length
}
foreach ($png in $pngs) { $w.Write($png) }
$w.Flush()
[IO.File]::WriteAllBytes((Join-Path $root "icon.ico"), $out.ToArray())
"Wrote icon.ico"
