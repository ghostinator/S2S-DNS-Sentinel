# ==============================================================================
# Script Name: DNS-S2S-Sentinel.ps1
# Version:     1.0.0
# Author:      Brandon Cook
# Description: Real-time Comparative DNS Monitor for Hybrid S2S Environments.
# ==============================================================================

try {
    Add-Type -AssemblyName System.Windows.Forms
    Add-Type -AssemblyName System.Drawing
    [void][Reflection.Assembly]::LoadWithPartialName("System.Windows.Forms.DataVisualization")
} catch {
    Write-Error "Charting libraries not found."
    return
}

# --- CONFIGURATION ---
$InternalDCs = @("10.1.1.4", "10.1.1.5") #
$InternalDomain = "InternalADDomain.com" #
$SRVRecord = "_ldap._tcp.Default-First-Site-Name._sites.dc._msdcs.$InternalDomain" #

# These will be queried against BOTH Internal DCs and 8.8.8.8
$ExternalTargets = @(
    "agent.sega.production.snap.bpcyber.com",
    "zinfandel-monitoring.centrastage.net",
    "teams.microsoft.com",
    "worldaz.tr.teams.microsoft.com",
    "outlook.office365.com"
)
$PublicResolver = "8.8.8.8"

# Global Variables
$script:GlobalData = New-Object System.Collections.Generic.List[PSCustomObject]
$DisplayCount = 30 
$Offset = 0 
$Interval = 5
$AutoScale = $false

# --- GUI SETUP ---
$Form = New-Object System.Windows.Forms.Form
$Form.Text = "S2S-DNS-Monitor"
$Form.Width = 1200
$Form.Height = 850

$Chart = New-Object System.Windows.Forms.DataVisualization.Charting.Chart
$Chart.Size = New-Object System.Drawing.Size(1150, 400)
$Chart.Location = New-Object System.Drawing.Point(10, 80)
$ChartArea = New-Object System.Windows.Forms.DataVisualization.Charting.ChartArea
$ChartArea.AxisY.Maximum = 200
$ChartArea.AxisX.MajorGrid.LineColor = [System.Drawing.Color]::LightGray
$ChartArea.AxisY.MajorGrid.LineColor = [System.Drawing.Color]::LightGray
$Chart.ChartAreas.Add($ChartArea)
$Chart.Legends.Add((New-Object System.Windows.Forms.DataVisualization.Charting.Legend))

# Build all series names for comparison
$AllSeriesNames = @()
foreach ($url in $ExternalTargets) {
    $AllSeriesNames += "$url (Internal)"
    $AllSeriesNames += "$url (8.8.8.8)"
}
$AllSeriesNames += $InternalDCs # Basic DC reachability
$AllSeriesNames += "AD_SRV"     #

$Colors = @("Red", "Crimson", "Blue", "DeepSkyBlue", "Green", "Lime", "Orange", "DarkOrange", "Purple", "Magenta", "Cyan", "Teal", "Brown", "Black")
$i = 0
foreach ($name in $AllSeriesNames) {
    $Series = New-Object System.Windows.Forms.DataVisualization.Charting.Series
    $Series.Name = $name
    $Series.ChartType = [System.Windows.Forms.DataVisualization.Charting.SeriesChartType]::Line
    $Series.BorderWidth = 2
    $Series.Color = $Colors[$i % $Colors.Length]
    $Chart.Series.Add($Series)
    $i++
}
$Form.Controls.Add($Chart)

$infoBox = New-Object System.Windows.Forms.RichTextBox
$infoBox.Location = "10,500"; $infoBox.Size = "1150,300"; $infoBox.BackColor = "Black"; $infoBox.ForeColor = "Lime"; $infoBox.Font = "Consolas, 10"
$Form.Controls.Add($infoBox)

# UI Buttons
$btnLive = New-Object System.Windows.Forms.Button
$btnLive.Text = "Live"; $btnLive.Location = "20,10"; $btnLive.BackColor = "LightGreen"
$btnScale = New-Object System.Windows.Forms.Button
$btnScale.Text = "Auto-Scale"; $btnScale.Location = "110,10"
$btnExport = New-Object System.Windows.Forms.Button
$btnExport.Text = "Export PNG"; $btnExport.Location = "220,10"

$btnLive.Add_Click({ $script:Offset = 0; Refresh-Chart })
$btnScale.Add_Click({
    $script:AutoScale = !$script:AutoScale
    $ChartArea.AxisY.Maximum = if($script:AutoScale){ [Double]::NaN } else { 200 }
    Refresh-Chart
})
$btnExport.Add_Click({
    $Chart.SaveImage("$env:USERPROFILE\Desktop\S2S_Report_$(Get-Date -Format 'yyyyMMdd_HHmm').png", [System.Windows.Forms.DataVisualization.Charting.ChartImageFormat]::Png)
})
$Form.Controls.AddRange(@($btnLive, $btnScale, $btnExport))

# --- REFRESH LOGIC ---
function Refresh-Chart {
    if ($script:GlobalData.Count -eq 0) { return }
    foreach ($s in $Chart.Series) { $s.Points.Clear() }
    $StartIdx = [math]::Max(0, $script:GlobalData.Count - $DisplayCount - $Offset)
    $EndIdx = [math]::Max(0, $script:GlobalData.Count - 1 - $Offset)
    for ($j = $StartIdx; $j -le $EndIdx; $j++) {
        $entry = $script:GlobalData[$j]
        foreach ($sName in $AllSeriesNames) {
            $val = if ($null -ne $entry.$sName) { $entry.$sName } else { 0 }
            $Chart.Series[$sName].Points.AddY($val)
        }
    }
}

# --- MONITORING LOOP ---
try {
    $Form.Show()
    while($Form.Visible) {
        [System.Windows.Forms.Application]::DoEvents()
        $resultSet = @{ "Timestamp" = (Get-Date -Format "HH:mm:ss") }
        $diagText = "--- S2S Comparison Diagnostics | $(Get-Date -Format 'HH:mm:ss') ---`n"

        # Test External Targets against Internal vs Public
        foreach ($url in $ExternalTargets) {
            $iName = "$url (Internal)"; $pName = "$url (8.8.8.8)"
            
            # Internal Test (Uses Primary DC)
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $null = Resolve-DnsName $url -Server $InternalDCs[0] -ErrorAction Stop
                $sw.Stop(); $latI = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
            } catch { $latI = 0 }
            
            # Public Test (Uses 8.8.8.8)
            try {
                $sw = [System.Diagnostics.Stopwatch]::StartNew()
                $null = Resolve-DnsName $url -Server $PublicResolver -ErrorAction Stop
                $sw.Stop(); $latP = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
            } catch { $latP = 0 }

            $resultSet[$iName] = $latI; $resultSet[$pName] = $latP
            $diagText += "$($iName.PadRight(45)) : $($latI)ms`n"
            $diagText += "$($pName.PadRight(45)) : $($latP)ms`n"
        }

        # AD Health Baseline
        try {
            $sw = [System.Diagnostics.Stopwatch]::StartNew()
            $null = Resolve-DnsName $SRVRecord -Type SRV -Server $InternalDCs[0] -ErrorAction Stop
            $sw.Stop(); $latSRV = [math]::Round($sw.Elapsed.TotalMilliseconds, 2)
            $resultSet["AD_SRV"] = $latSRV
        } catch { $resultSet["AD_SRV"] = 0 }

        $script:GlobalData.Add([PSCustomObject]$resultSet)
        $infoBox.Text = $diagText
        if ($Offset -eq 0) { Refresh-Chart }
        Start-Sleep -Seconds $Interval
    }
}
finally {
    if ($null -ne $Form) { $Form.Dispose() }
}
