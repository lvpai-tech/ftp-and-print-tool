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
  $document.PrinterSettings.Copies = [int16]$Copies
  # 去掉默认「正在打印 Document」状态小窗，静默送后台假脱机。
  $document.PrintController = New-Object System.Drawing.Printing.StandardPrintController
  $document.DocumentName = "lvpai-$Kind"
  $document.add_PrintPage({
    param($sender, $event)
    # 绘图原点在可打印区左上角；横向时 PrintableArea 不随方向旋转，需互换宽高。
    $area = $event.PageSettings.PrintableArea
    $areaWidth = if ($event.PageSettings.Landscape) { $area.Height } else { $area.Width }
    $areaHeight = if ($event.PageSettings.Landscape) { $area.Width } else { $area.Height }
    $scale = [Math]::Min($areaWidth / $image.Width, $areaHeight / $image.Height)
    $width = [int]($image.Width * $scale)
    $height = [int]($image.Height * $scale)
    $event.Graphics.DrawImage($image, [int](($areaWidth - $width) / 2), [int](($areaHeight - $height) / 2),
      $width, $height)
    $event.HasMorePages = $false
  })
  $document.Print()
} finally {
  $image.Dispose()
}
