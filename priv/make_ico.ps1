Add-Type -AssemblyName System.Drawing

$repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$srcPath = Join-Path $PSScriptRoot 'static/images/icon.png'
if (-not (Test-Path -LiteralPath $srcPath)) {
    throw "Canonical icon not found at $srcPath"
}

$srcBmp = [System.Drawing.Bitmap]::FromFile($srcPath)

# The same checked-in artwork supplies the app, installer and website icons.
Copy-Item -LiteralPath $srcPath -Destination (Join-Path $repoRoot 'web/assets/icon.png')

# Generate multi-resolution ICO file
$sizes = @(16, 32, 48, 64, 128, 256)
$pngBytesList = @()

foreach ($size in $sizes) {
    $resized = New-Object System.Drawing.Bitmap($size, $size)
    $g = [System.Drawing.Graphics]::FromImage($resized)
    $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
    $g.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $g.Clear([System.Drawing.Color]::Transparent)
    $g.DrawImage($srcBmp, 0, 0, $size, $size)
    $g.Dispose()

    $ms = New-Object System.IO.MemoryStream
    $resized.Save($ms, [System.Drawing.Imaging.ImageFormat]::Png)
    $pngBytesList += ,@($size, $ms.ToArray())
    $resized.Dispose()
}
$srcBmp.Dispose()

# Create ICO binary
function Write-IcoFile($outputPath, $entries) {
    $fs = New-Object System.IO.FileStream($outputPath, [System.IO.FileMode]::Create)
    $bw = New-Object System.IO.BinaryWriter($fs)

    # ICONDIR header
    $bw.Write([uint16]0)          # Reserved
    $bw.Write([uint16]1)          # Type: 1 = icon
    $bw.Write([uint16]$entries.Count) # Count of images

    $offset = 6 + (16 * $entries.Count)

    # ICONDIRENTRY headers
    foreach ($item in $entries) {
        $dim = $item[0]
        $bytes = $item[1]

        $w = if ($dim -ge 256) { 0 } else { [byte]$dim }
        $h = if ($dim -ge 256) { 0 } else { [byte]$dim }

        $bw.Write([byte]$w)       # Width
        $bw.Write([byte]$h)       # Height
        $bw.Write([byte]0)        # Color count (0 for 32bpp)
        $bw.Write([byte]0)        # Reserved
        $bw.Write([uint16]1)      # Color planes
        $bw.Write([uint16]32)     # Bits per pixel
        $bw.Write([uint32]$bytes.Length) # Size of image data
        $bw.Write([uint32]$offset)       # Offset of image data

        $offset += $bytes.Length
    }

    # Image data
    foreach ($item in $entries) {
        $bytes = $item[1]
        $bw.Write($bytes)
    }

    $bw.Close()
    $fs.Close()
    Write-Output "Generated: $outputPath"
}

Write-IcoFile (Join-Path $repoRoot "windows/app.ico") $pngBytesList
Write-IcoFile (Join-Path $repoRoot "priv/static/favicon.ico") $pngBytesList
Write-IcoFile (Join-Path $repoRoot "web/assets/favicon.ico") $pngBytesList

Write-Output "All icons generated successfully!"
