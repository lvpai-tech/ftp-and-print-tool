param(
  [Parameter(Mandatory = $true)][string]$Printer
)
# 读取打印机与其Windows打印队列状态，单行JSON输出到stdout；读不到状态时非0退出，由代理按失败处理。
# 只能反映驱动上报的状态（缺纸、卡纸、离线等），不能证明纸张已真正出纸。
$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$device = Get-Printer -Name $Printer
$jobs = @(Get-PrintJob -PrinterName $Printer | ForEach-Object {
  [pscustomobject]@{
    id = [int]$_.Id
    documentName = [string]$_.DocumentName
    status = [string]$_.JobStatus
    submittedAt = $_.SubmittedTime.ToUniversalTime().ToString('o')
  }
})
[pscustomobject]@{
  printer = [string]$device.Name
  printerStatus = [string]$device.PrinterStatus
  jobs = $jobs
} | ConvertTo-Json -Compress -Depth 4
