# ==============================================================================
# Script Name: S2S-DNS-Sentinel
# Author:      Brandon Cook
# ==============================================================================

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [void][Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms.DataVisualization")
} catch {
    Write-Error "Charting libraries not found."
    return
}

# --- CONFIGURATION (LOCKED) ---
$InternalDCs = @("10.1.1.4", "10.1.1.5")
$InternalDomain = "clientsdomain.com"
$LogPath = "$env:USERPROFILE\Desktop\S2S_DNS_Log_$(Get-Date -Format 'yyyyMMdd').csv"
$PublicResolver = "8.8.8.8"
$Intervalms = 5000 

$ExternalTargets = @(
    "agent.sega.production.snap.bpcyber.com",
    "zinfandel-monitoring.centrastage.net",
    "teams.microsoft.com",
    "worldaz.tr.teams.microsoft.com",
    "outlook.office365.com"
)

$SRVRecord = "_ldap._tcp.Default-First-Site-Name._sites.dc._msdcs.$InternalDomain"

# --- GLOBAL STATE ---
$script:GlobalData = New-Object System.Collections.Generic.List[PSCustomObject]
$script:DisplayCount = 30
$script:AutoScale = $false

# --- GUI SETUP ---
$Form = New-Object System.Windows.Forms.Form
$Form.Text = "S2S-DNS-Monitor"
$Form.Width = 1200
$Form.Height = 850

$Chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
$Chart.Size = "1150, 400"; $Chart.Location = "10, 80"
$ChartArea = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
$ChartArea.AxisY.Maximum = 250 
$ChartArea.AxisX.MajorGrid.LineColor = [System.Drawing.Color]::LightGray
$ChartArea.AxisY.MajorGrid.LineColor = [System.Drawing.Color]::LightGray
$Chart.ChartAreas.Add($ChartArea)
$Chart.Legends.Add((New-Object System.Windows.Forms.DataVisualization.Charting.Legend))

# Initialize Series
$AllSeriesNames = @()
foreach ($url in $ExternalTargets) {
    $AllSeriesNames += "$url (Internal)"; $AllSeriesNames += "$url (8.8.8.8)"
}
foreach ($dc in $InternalDCs) { $AllSeriesNames += $dc }
$AllSeriesNames += "AD_SRV"

$Colors = @("Red", "Blue", "Green", "Orange", "Purple", "Cyan", "Magenta", "Teal", "Brown", "Black", "DarkGray", "Olive")
$i = 0
foreach ($name in $AllSeriesNames) {
    $Series = New-Object System.Windows.Forms.DataVisualization.Charting.Series($name)
    $Series.ChartType = "Line"; $Series.BorderWidth = 2
    $Series.Color = $Colors[$i % $Colors.Length]
    $Chart.Series.Add($Series)
    $i++
}
$Form.Controls.Add($Chart)

$infoBox = New-Object System.Windows.Forms.RichTextBox
$infoBox.Location = "10,500"; $infoBox.Size = "1150,300"; $infoBox.BackColor = "Black"; $infoBox.ForeColor = "Lime"; $infoBox.Font = "Consolas, 10"
$Form.Controls.Add($infoBox)

# --- REINSTATED BUTTONS ---
$btnLive = New-Object System.Windows.Forms.Button
$btnLive.Text = "Live"; $btnLive.Location = "20,10"; $btnLive.BackColor = "LightGreen"
$btnScale = New-Object System.Windows.Forms.Button
$btnScale.Text = "Auto-Scale"; $btnScale.Location = "110,10"
$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = "Export PNG"; $btnExport.Location = "220,10"

$btnLive.Add_Click({ Refresh-Chart })
$btnScale.Add_Click({
    $script:AutoScale = !$script:AutoScale
    $ChartArea.AxisY.Maximum = if($script:AutoScale){ [Double]::NaN } else { 250 }
    Refresh-Chart
})
$btnExport.Add_Click({
    $Chart.SaveImage("$env:USERPROFILE\Desktop\S2S_Report_$(Get-Date -Format 'yyyyMMdd_HHmm').png", [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png)
})
$Form.Controls.AddRange(@($btnLive, $btnScale, $btnExport))

# --- REFRESH FUNCTION ---
function Refresh-Chart {
    if ($script:GlobalData.Count -eq 0) { return }
    $LatestEntries = $script:GlobalData | Select-Object -Last $script:DisplayCount
    foreach ($s in $Chart.Series) { $s.Points.Clear() }
    foreach ($entry in $LatestEntries) {
        foreach ($sName in $AllSeriesNames) {
            $val = if ($null -ne $entry.$sName) { $entry.$sName } else { 0 }
            [void]$Chart.Series[$sName].Points.AddY($val)
        }
    }
}

# --- TIMER LOGIC ---
$Timer = New-Object System.Windows.Forms.Timer
$Timer.Interval = $Intervalms
$Timer.Add_Tick({
    $Timer.Stop()
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $resultSet = [ordered]@{ "Timestamp" = $timestamp }
    $diagText = "--- S2S Monitoring | $timestamp ---`n"

    # 1. External Targets
    foreach ($url in $ExternalTargets) {
        $iName = "$url (Internal)"; $pName = "$url (8.8.8.8)"
        $sw = [System.Diagnostics.Stopwatch]::StartNew()
        try { $null = Resolve-DnsName $url -Server $InternalDCs[0] -ErrorAction Stop; $latI = $sw.Elapsed.TotalMilliseconds } catch { $latI = 0 }
        $sw.Restart()
        try { $null = Resolve-DnsName $url -Server $PublicResolver -ErrorAction Stop; $latP = $sw.Elapsed.TotalMilliseconds } catch { $latP = 0 }
        
        $resultSet[$iName] = [math]::Round($latI, 2)
        $resultSet[$pName] = [math]::Round($latP, 2)
        $diagText += "$($iName.PadRight(45)) : $($resultSet[$iName])ms`n"
        $diagText += "$($pName.PadRight(45)) : $($resultSet[$pName])ms`n"
    }

    # 2. SRV Record Check
    $sw.Restart()
    try {
        $null = Resolve-DnsName $SRVRecord -Type SRV -Server $InternalDCs[0] -ErrorAction Stop
        $latSRV = $sw.Elapsed.TotalMilliseconds
    } catch { $latSRV = 0 }
    $resultSet["AD_SRV"] = [math]::Round($latSRV, 2)
    $diagText += "$("AD SRV Health ($InternalDomain)".PadRight(45)) : $($resultSet["AD_SRV"])ms`n"

    # 3. DC Reachability
    foreach ($dc in $InternalDCs) {
        if (Test-Connection -ComputerName $dc -Count 1 -Quiet) { $resultSet[$dc] = 1 } else { $resultSet[$dc] = 0 }
    }

    # 4. Save and Log
    $dataObject = [PSCustomObject]$resultSet
    $script:GlobalData.Add($dataObject)
    $dataObject | Export-Csv -Path $LogPath -Append -NoTypeInformation
    
    # 5. UI Update
    $infoBox.Text = $diagText
    Refresh-Chart
    $Timer.Start()
})

$Timer.Start()
[void]$Form.ShowDialog()
$Timer.Stop(); $Timer.Dispose()
