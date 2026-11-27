# Bundled Windows PowerShell adapter for WinRT PDF rendering and the selected driver.
$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ne 5) { throw 'Windows PowerShell 5 is required for WinRT' }
if (-not (Test-Path -LiteralPath $env:LVPAI_PICKUP_PDF -PathType Leaf)) { exit 22 }

Add-Type -AssemblyName System.Runtime.WindowsRuntime
Add-Type -AssemblyName System.Drawing
$null = [Windows.Storage.StorageFile, Windows.Storage, ContentType = WindowsRuntime]
$null = [Windows.Data.Pdf.PdfDocument, Windows.Data.Pdf, ContentType = WindowsRuntime]
$null = [Windows.Data.Pdf.PdfPageRenderOptions, Windows.Data.Pdf, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.InMemoryRandomAccessStream, Windows.Storage.Streams, ContentType = WindowsRuntime]
$null = [Windows.Storage.Streams.DataReader, Windows.Storage.Streams, ContentType = WindowsRuntime]
$methods = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
    $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1
}
$operationTask = $methods | Where-Object {
    $_.IsGenericMethodDefinition -and $_.GetGenericArguments().Count -eq 1 -and
    $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1'
}
$actionTask = $methods | Where-Object {
    -not $_.IsGenericMethodDefinition -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction'
}

function Wait-PdfOperation($Operation, [type]$ResultType) {
    $task = $operationTask.MakeGenericMethod($ResultType).Invoke($null, @($Operation))
    return $task.GetAwaiter().GetResult()
}

function Read-PdfPageBitmap($Page, [uint32]$Width, [uint32]$Height) {
    $output = [Windows.Storage.Streams.InMemoryRandomAccessStream]::new()
    try {
        $options = [Windows.Data.Pdf.PdfPageRenderOptions]::new()
        $options.DestinationWidth = $Width
        $options.DestinationHeight = $Height
        $task = $actionTask.Invoke($null, @($Page.RenderToStreamAsync($output, $options)))
        $null = $task.GetAwaiter().GetResult()
        $reader = [Windows.Storage.Streams.DataReader]::new($output.GetInputStreamAt(0))
        try {
            $size = Wait-PdfOperation ($reader.LoadAsync([uint32]$output.Size)) ([uint32])
            $bytes = [byte[]]::new($size)
            $reader.ReadBytes($bytes)
            return ,$bytes
        } finally {
            $reader.Dispose()
        }
    } finally {
        $output.Dispose()
    }
}

$width = 54 / 25.4 * 100
$height = 90 / 25.4 * 100
$settings = [System.Drawing.Printing.PrinterSettings]::new()
$settings.PrinterName = $env:LVPAI_PICKUP_PRINTER
if (-not $settings.IsValid) { exit 21 }
$paper = $settings.PaperSizes | Where-Object {
    [Math]::Abs($_.Width - $width) -le 2 -and [Math]::Abs($_.Height - $height) -le 2
} | Select-Object -First 1
if ($null -eq $paper) { exit 21 }

try {
    $file = Wait-PdfOperation ([Windows.Storage.StorageFile]::GetFileFromPathAsync($env:LVPAI_PICKUP_PDF)) ([Windows.Storage.StorageFile])
    $pdf = Wait-PdfOperation ([Windows.Data.Pdf.PdfDocument]::LoadFromFileAsync($file)) ([Windows.Data.Pdf.PdfDocument])
    if ($pdf.PageCount -lt 1 -or $pdf.PageCount -gt 500) { exit 22 }
    for ($index = 0; $index -lt $pdf.PageCount; $index++) {
        $page = $pdf.GetPage($index)
        try {
            if ([Math]::Abs($page.Size.Width / 96 * 100 - $width) -gt 1 -or
                [Math]::Abs($page.Size.Height / 96 * 100 - $height) -gt 1) { exit 22 }
        } finally {
            $page.Dispose()
        }
    }
} catch {
    Write-Error -ErrorAction Continue $_
    exit 22
}

$document = [System.Drawing.Printing.PrintDocument]::new()
try {
    $settings.Copies = 1
    if ($settings.CanDuplex) { $settings.Duplex = [System.Drawing.Printing.Duplex]::Simplex }
    $document.PrinterSettings = $settings
    $document.DocumentName = [IO.Path]::GetFileName($env:LVPAI_PICKUP_PDF)
    $document.DefaultPageSettings.PaperSize = $paper
    $document.DefaultPageSettings.Landscape = $false
    $document.PrintController = [System.Drawing.Printing.StandardPrintController]::new()
    $progress = @{ Page = 0 }
    $document.add_PrintPage({
        param($sender, $eventArgs)
        if ([Math]::Abs($eventArgs.PageBounds.Width - $width) -gt 2 -or
            [Math]::Abs($eventArgs.PageBounds.Height - $height) -gt 2) {
            throw 'The printer driver changed the requested card size'
        }
        $page = $pdf.GetPage($progress.Page)
        try {
            # Render one page at 600 DPI, then draw in physical units from the paper origin.
            $bytes = Read-PdfPageBitmap $page ([uint32]($width * 6)) ([uint32]($height * 6))
            $stream = [IO.MemoryStream]::new($bytes)
            try {
                $image = [System.Drawing.Image]::FromStream($stream)
                try {
                    $eventArgs.Graphics.PageUnit = [System.Drawing.GraphicsUnit]::Inch
                    $rectangle = [System.Drawing.RectangleF]::new(
                        -$eventArgs.PageSettings.HardMarginX / 100, -$eventArgs.PageSettings.HardMarginY / 100,
                        $width / 100, $height / 100)
                    $eventArgs.Graphics.DrawImage($image, $rectangle)
                } finally {
                    $image.Dispose()
                }
            } finally {
                $stream.Dispose()
            }
        } finally {
            $page.Dispose()
        }
        $progress.Page++
        $eventArgs.HasMorePages = $progress.Page -lt $pdf.PageCount
    })
    $document.Print()
    if ($progress.Page -ne $pdf.PageCount) { throw 'The driver did not accept all pages' }
} finally {
    $document.Dispose()
}
