param(
  [Parameter(Mandatory = $true)][string]$File,
  [string]$Printer = '',
  [int]$Copies = 1,
  [string]$Kind = 'ORIGINAL'
)
# 工作台出图脚本：一律用6寸纸（4x6英寸），按图片横竖设方向，在可打印区内等比缩放居中后送指定打印机；
# 退出码0只表示Windows已受理。打印机没有6寸纸张规格时直接失败，不退回驱动默认纸张。
# 等比留白还是裁切铺满属于版式（O08），这里只做等比。
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing
$printDpi = 300
if ($env:LVPAI_PRINT_DPI) {
  if (-not [int]::TryParse($env:LVPAI_PRINT_DPI, [ref]$printDpi) -or
    $printDpi -lt 72 -or $printDpi -gt 1200) {
    throw '打印分辨率须为 72–1200 DPI 的整数'
  }
}
$image = [System.Drawing.Image]::FromFile($File)
try {
  $document = New-Object System.Drawing.Printing.PrintDocument
  if ($Printer) { $document.PrinterSettings.PrinterName = $Printer }
  if (-not $document.PrinterSettings.IsValid) { throw "打印机不可用：$Printer" }
  # PaperSize 单位为百分之一英寸，6寸纸即 400x600。
  $sixInch = $document.PrinterSettings.PaperSizes | Where-Object {
    [Math]::Abs($_.Width - 400) -le 3 -and [Math]::Abs($_.Height - 600) -le 3
  } | Select-Object -First 1
  if (-not $sixInch) { throw "打印机没有6寸纸（4x6英寸）规格：$Printer" }
  $document.DefaultPageSettings.PaperSize = $sixInch
  $document.DefaultPageSettings.Landscape = $image.Width -gt $image.Height
  $document.DefaultPageSettings.Margins = New-Object System.Drawing.Printing.Margins(0, 0, 0, 0)
  # Windows 的画质档和数值分辨率通过同一个属性传给驱动。
  $resolutions = $document.PrinterSettings.PrinterResolutions
  $resolution = if ($env:LVPAI_PRINT_HIGH_QUALITY -eq '1') {
    $high = $resolutions | Where-Object Kind -eq High | Select-Object -First 1
    if (!$high) { throw '该打印驱动未提供高画质档，请关闭工作台高画质或检查驱动。' }
    $high
  } else {
    $resolutions | Where-Object { $_.X -eq $printDpi -and $_.Y -eq $printDpi } | Select-Object -First 1
  }
  if ($resolution) { $document.DefaultPageSettings.PrinterResolution = $resolution }
  $document.PrinterSettings.Copies = [int16]$Copies
  # 去掉默认「正在打印 Document」状态小窗，静默送后台假脱机。
  $document.PrintController = New-Object System.Drawing.Printing.StandardPrintController
  $document.DocumentName = if ($env:LVPAI_PRINT_DOCUMENT_NAME) { $env:LVPAI_PRINT_DOCUMENT_NAME } else { "lvpai-$Kind" }
  $document.add_PrintPage({
    param($sender, $event)
    # 绘图原点在可打印区左上角；横向时 PrintableArea 不随方向旋转，需互换宽高。
    $area = $event.PageSettings.PrintableArea
    $areaWidth = if ($event.PageSettings.Landscape) { $area.Height } else { $area.Width }
    $areaHeight = if ($event.PageSettings.Landscape) { $area.Width } else { $area.Height }
    $scale = [Math]::Min($areaWidth / $image.Width, $areaHeight / $image.Height)
    $width = [int]($image.Width * $scale)
    $height = [int]($image.Height * $scale)
    # 按设定分辨率生成位图，打印位置和尺寸仍以百分之一英寸计算。
    $rasterWidth = [Math]::Max(1, [int]($width * $printDpi / 100))
    $rasterHeight = [Math]::Max(1, [int]($height * $printDpi / 100))
    $raster = [System.Drawing.Bitmap]::new($rasterWidth, $rasterHeight)
    try {
      $raster.SetResolution($printDpi, $printDpi)
      $rasterGraphics = [System.Drawing.Graphics]::FromImage($raster)
      try {
        $rasterGraphics.Clear([System.Drawing.Color]::White)
        $rasterGraphics.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
        $rasterGraphics.DrawImage($image, 0, 0, $rasterWidth, $rasterHeight)
      } finally {
        $rasterGraphics.Dispose()
      }
      $event.Graphics.DrawImage($raster, [int](($areaWidth - $width) / 2), [int](($areaHeight - $height) / 2),
        $width, $height)
    } finally {
      $raster.Dispose()
    }
    $event.HasMorePages = $false
  })
  $document.Print()
} finally {
  $image.Dispose()
}
