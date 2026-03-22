<#
.SYNOPSIS
    VBS Scanner Utility v2.0 - GUI-based tool for scanning .vbs files with Archive metadata extraction.

.DESCRIPTION
    A WinForms-based PowerShell 5.1 tool that:
    - Scans local devices (by name), UNC paths, or structured Archive roots for .vbs files
    - For Archive Root scans, extracts PackageName, Version, and Build from path structure
    - Shows live progress with responsive UI
    - Displays results in a DataGridView with context menu actions
    - Generates HTML reports with embedded WebBrowser preview
    - Logs all activities using CMTRACE-compatible format

    Phase 2 Enhancement: Archive Root scanning with metadata extraction
    Archive Structure: \\Server\Archive\Vendor\PackageName\Version\Type\Build\files

.NOTES
    Author: Enterprise Endpoint Engineering
    Version: 2.0.0
    Requires: PowerShell 5.1, .NET Framework 4.5+
    Date: 2026-03-22
#>

#Requires -Version 5.1

#region ===== ASSEMBLIES =====
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
Add-Type -AssemblyName System.Web
[System.Windows.Forms.Application]::EnableVisualStyles()
#endregion

#region ===== SCRIPT VARIABLES =====
$Script:AppName = "VBS Scanner Utility"
$Script:AppVersion = "2.0.0"
$Script:StartTime = Get-Date
$Script:Timestamp = $Script:StartTime.ToString("yyyyMMdd_HHmmss")
$Script:DefaultOutputFolder = [Environment]::GetFolderPath("MyDocuments")
$Script:LogFile = Join-Path -Path $Script:DefaultOutputFolder -ChildPath "VBSScanner_$($Script:Timestamp).log"
$Script:HtmlReportFile = ""
$Script:ScanResults = [System.Collections.ArrayList]::new()
$Script:ErrorCount = 0
$Script:ScanCancelled = $false
$Script:IsScanning = $false
$Script:CurrentEntryType = "DeviceName"  # DeviceName, UNC, ArchiveRoot
$Script:ArchiveRoot = ""  # Stores the archive root for metadata extraction
#endregion

#region ===== CMTRACE-COMPATIBLE LOGGING =====
function Write-CMTraceLog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$Component = "VBSScanner",

        [Parameter(Mandatory = $false)]
        [ValidateSet(1, 2, 3)]
        [int]$Severity = 1,

        [Parameter(Mandatory = $false)]
        [string]$LogFile = $Script:LogFile
    )

    $Now = Get-Date
    $TimeString = $Now.ToString("HH:mm:ss.fff")
    $DateString = $Now.ToString("MM-dd-yyyy")

    $UtcOffset = [System.TimeZoneInfo]::Local.GetUtcOffset($Now)
    $OffsetMinutes = $UtcOffset.TotalMinutes
    $OffsetSign = if ($OffsetMinutes -ge 0) { "+" } else { "-" }
    $OffsetString = "{0}{1}" -f $OffsetSign, [Math]::Abs($OffsetMinutes)

    $ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId

    $LogEntry = "<![LOG[$Message]LOG]!><time=""$TimeString$OffsetString"" date=""$DateString"" component=""$Component"" context="""" type=""$Severity"" thread=""$ThreadId"" file=""VBSScanner"">"

    $LogDir = Split-Path -Path $LogFile -Parent
    if (-not (Test-Path -Path $LogDir -PathType Container)) {
        try {
            New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        catch {
            return
        }
    }

    $MaxRetries = 3
    $RetryCount = 0
    $Written = $false

    while (-not $Written -and $RetryCount -lt $MaxRetries) {
        try {
            Add-Content -Path $LogFile -Value $LogEntry -Encoding UTF8 -ErrorAction Stop
            $Written = $true
        }
        catch {
            $RetryCount++
            Start-Sleep -Milliseconds 50
        }
    }
}
#endregion

#region ===== HELPER FUNCTIONS =====
function Test-PathAccessible {
    param([string]$Path)
    try {
        $null = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Test-PathExcluded {
    param(
        [string]$Path,
        [string[]]$ExcludePaths
    )
    foreach ($ExcludePath in $ExcludePaths) {
        if ([string]::IsNullOrWhiteSpace($ExcludePath)) { continue }
        $NormalizedExclude = $ExcludePath.Trim().TrimEnd('\', '/').ToLower()
        $NormalizedPath = $Path.TrimEnd('\', '/').ToLower()
        if ($NormalizedPath -eq $NormalizedExclude -or $NormalizedPath.StartsWith("$NormalizedExclude\") -or $NormalizedPath.StartsWith("$NormalizedExclude/")) {
            return $true
        }
    }
    return $false
}

function Get-ScanRootFromInput {
    <#
    .SYNOPSIS
        Determines the scan root path based on input type.
    #>
    param(
        [string]$InputType,
        [string]$DeviceName,
        [string]$UncPath,
        [string]$ArchiveRoot
    )

    switch ($InputType) {
        "DeviceName" {
            if ([string]::IsNullOrWhiteSpace($DeviceName)) {
                return $null
            }
            $CleanName = $DeviceName.Trim().TrimStart('\')
            # If it looks like a local path (e.g., C:\temp), use it directly
            if ($CleanName -match '^[A-Za-z]:\\') {
                return $CleanName
            }
            # Otherwise treat as device name and convert to admin share
            return "\\$CleanName\C$"
        }
        "UNC" {
            if ([string]::IsNullOrWhiteSpace($UncPath)) {
                return $null
            }
            return $UncPath.Trim()
        }
        "ArchiveRoot" {
            if ([string]::IsNullOrWhiteSpace($ArchiveRoot)) {
                return $null
            }
            return $ArchiveRoot.Trim().TrimEnd('\')
        }
        default {
            return $null
        }
    }
}

function Get-ArchiveMetadataFromPath {
    <#
    .SYNOPSIS
        Extracts PackageName, Version, and Build from an archive-structured path.

    .DESCRIPTION
        Parses the file path based on the expected archive structure:
        \\Server\Archive\Vendor\PackageName\Version\Type\Build\file.vbs

        Segments after the archive root:
        [0] = Vendor
        [1] = PackageName
        [2] = Version
        [3] = Type
        [4] = Build
        [5+] = Subfolders/File

    .PARAMETER ArchiveRoot
        The base archive path (e.g., \\Server\Archive)

    .PARAMETER FullPath
        The complete file path to parse

    .OUTPUTS
        PSCustomObject with PackageName, Version, Build properties
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$ArchiveRoot,

        [Parameter(Mandatory = $true)]
        [string]$FullPath
    )

    $Result = [PSCustomObject]@{
        PackageName = ""
        Version     = ""
        Build       = ""
    }

    try {
        # Normalize paths for comparison (case-insensitive, consistent separators)
        $NormalizedRoot = $ArchiveRoot.TrimEnd('\', '/').ToLower()
        $NormalizedPath = $FullPath.ToLower()

        # Verify the file is under the archive root
        if (-not $NormalizedPath.StartsWith($NormalizedRoot)) {
            Write-CMTraceLog -Message "Path does not match archive root. Path: $FullPath | Root: $ArchiveRoot" -Severity 2 -Component "ArchiveMetadata"
            return $Result
        }

        # Get the relative path after the archive root
        $RelativePath = $FullPath.Substring($ArchiveRoot.Length).TrimStart('\', '/')

        # Split into segments
        $Segments = $RelativePath -split '[\\/]' | Where-Object { $_ -ne '' }

        # Expected structure: Vendor\PackageName\Version\Type\Build\...\file.vbs
        # Minimum segments needed: Vendor(0), PackageName(1), Version(2), Type(3), Build(4), file(5+)
        if ($Segments.Count -ge 5) {
            $Result.PackageName = $Segments[1]  # PackageName is at index 1
            $Result.Version = $Segments[2]      # Version is at index 2
            $Result.Build = $Segments[4]        # Build is at index 4 (after Type)

            Write-CMTraceLog -Message "Extracted metadata - Package: $($Result.PackageName), Version: $($Result.Version), Build: $($Result.Build) from $FullPath" -Component "ArchiveMetadata"
        }
        else {
            Write-CMTraceLog -Message "Path structure incomplete (expected 5+ segments, got $($Segments.Count)). Path: $FullPath" -Severity 2 -Component "ArchiveMetadata"
        }
    }
    catch {
        Write-CMTraceLog -Message "Error extracting metadata from path: $FullPath - $($_.Exception.Message)" -Severity 3 -Component "ArchiveMetadata"
    }

    return $Result
}

function Open-FileInNotepad {
    param([string]$FilePath)
    try {
        if (Test-Path -LiteralPath $FilePath -PathType Leaf) {
            Start-Process -FilePath "notepad.exe" -ArgumentList "`"$FilePath`""
            Write-CMTraceLog -Message "Opened file in Notepad: $FilePath" -Component "OpenFile"
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("File not found: $FilePath", "File Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            Write-CMTraceLog -Message "File not found when trying to open: $FilePath" -Severity 2 -Component "OpenFile"
        }
    }
    catch {
        [System.Windows.Forms.MessageBox]::Show("Failed to open file: $($_.Exception.Message)", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
        Write-CMTraceLog -Message "Error opening file: $($_.Exception.Message)" -Severity 3 -Component "OpenFile"
    }
}
#endregion

#region ===== HTML REPORT GENERATION =====
function New-HtmlReport {
    <#
    .SYNOPSIS
        Generates an HTML report with Phase 2 enhancements for Archive metadata.
    #>
    param(
        [array]$Results,
        [string]$ScanRoot,
        [string]$EntryType,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [int]$ErrorCount,
        [string]$OutputPath
    )

    $Duration = $EndTime - $StartTime
    $DurationString = "{0:hh\:mm\:ss\.fff}" -f $Duration
    $TotalSizeBytes = ($Results | Measure-Object -Property SizeBytes -Sum).Sum
    $TotalSizeMB = if ($TotalSizeBytes) { [math]::Round($TotalSizeBytes / 1MB, 2) } else { 0 }

    # Generate package summary for Archive Root scans
    $PackageSummaryHtml = ""
    if ($EntryType -eq "ArchiveRoot" -and $Results.Count -gt 0) {
        $PackageGroups = $Results | Where-Object { $_.PackageName -ne "" } | Group-Object -Property PackageName | Sort-Object Count -Descending
        $VersionGroups = $Results | Where-Object { $_.Version -ne "" } | Group-Object -Property Version | Sort-Object Count -Descending

        if ($PackageGroups.Count -gt 0) {
            $PackageRows = ""
            foreach ($Pkg in $PackageGroups | Select-Object -First 10) {
                $PackageRows += "<tr><td>$([System.Web.HttpUtility]::HtmlEncode($Pkg.Name))</td><td class='size-cell'>$($Pkg.Count)</td></tr>"
            }

            $PackageSummaryHtml = @"
        <div class="info-box">
            <h2>Package Summary (Top 10)</h2>
            <table style="width: auto; min-width: 300px;">
                <thead><tr><th>Package Name</th><th>File Count</th></tr></thead>
                <tbody>$PackageRows</tbody>
            </table>
        </div>
"@
        }
    }

    # Build table rows with new columns
    $TableRows = ""
    $RowNumber = 0
    foreach ($File in $Results) {
        $RowNumber++
        $RowClass = if ($RowNumber % 2 -eq 0) { "even" } else { "odd" }
        $SafeFileName = [System.Web.HttpUtility]::HtmlEncode($File.FileName)
        $SafeFullPath = [System.Web.HttpUtility]::HtmlEncode($File.FullPath)
        $SafeParentFolder = [System.Web.HttpUtility]::HtmlEncode($File.ParentFolder)
        $SafePackageName = [System.Web.HttpUtility]::HtmlEncode($File.PackageName)
        $SafeVersion = [System.Web.HttpUtility]::HtmlEncode($File.Version)
        $SafeBuild = [System.Web.HttpUtility]::HtmlEncode($File.Build)
        $FormattedDate = $File.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        $FormattedSize = "{0:N0}" -f $File.SizeBytes

        # Create file:// link - WebBrowser.Navigating will intercept this
        $FileUri = "file:///" + ($File.FullPath -replace '\\', '/')

        $TableRows += @"

        <tr class="$RowClass">
            <td class="row-num">$RowNumber</td>
            <td>$SafeFileName</td>
            <td class="path-cell"><a href="$FileUri" title="Click to open in Notepad">$SafeFullPath</a></td>
            <td>$SafeParentFolder</td>
            <td>$SafePackageName</td>
            <td>$SafeVersion</td>
            <td>$SafeBuild</td>
            <td class="date-cell">$FormattedDate</td>
            <td class="size-cell">$FormattedSize</td>
        </tr>
"@
    }

    # Entry type display name
    $EntryTypeDisplay = switch ($EntryType) {
        "DeviceName" { "Device/Local Path" }
        "UNC" { "UNC Path" }
        "ArchiveRoot" { "Archive Root (Structured)" }
        default { $EntryType }
    }

    $HtmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VBS Scanner Report</title>
    <style>
        :root {
            --primary: #0078d4;
            --success: #107c10;
            --warning: #ffb900;
            --error: #d83b01;
            --bg: #f3f2f1;
            --card: #ffffff;
            --text: #323130;
            --border: #e1dfdd;
        }
        * { box-sizing: border-box; margin: 0; padding: 0; }
        body {
            font-family: 'Segoe UI', Tahoma, sans-serif;
            background: var(--bg);
            color: var(--text);
            line-height: 1.5;
            padding: 15px;
        }
        .container { max-width: 1400px; margin: 0 auto; }
        header {
            background: linear-gradient(135deg, var(--primary), #106ebe);
            color: white;
            padding: 20px;
            border-radius: 6px;
            margin-bottom: 15px;
        }
        header h1 { font-size: 22px; margin-bottom: 5px; }
        header .subtitle { opacity: 0.9; font-size: 12px; }
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(150px, 1fr));
            gap: 10px;
            margin-bottom: 15px;
        }
        .summary-card {
            background: var(--card);
            border-radius: 6px;
            padding: 15px;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
            border-left: 3px solid var(--primary);
        }
        .summary-card.success { border-left-color: var(--success); }
        .summary-card.error { border-left-color: var(--error); }
        .summary-card .label { font-size: 11px; text-transform: uppercase; color: #605e5c; }
        .summary-card .value { font-size: 20px; font-weight: 600; }
        .info-box {
            background: var(--card);
            border-radius: 6px;
            padding: 15px;
            margin-bottom: 15px;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
        }
        .info-box h2 { font-size: 14px; color: var(--primary); margin-bottom: 10px; border-bottom: 1px solid var(--border); padding-bottom: 5px; }
        .info-box p { font-size: 12px; margin: 3px 0; }
        .results-box {
            background: var(--card);
            border-radius: 6px;
            padding: 15px;
            box-shadow: 0 1px 3px rgba(0,0,0,0.1);
            overflow-x: auto;
        }
        .results-box h2 { font-size: 14px; color: var(--primary); margin-bottom: 10px; }
        table { width: 100%; border-collapse: collapse; font-size: 12px; }
        th {
            background: var(--primary);
            color: white;
            padding: 10px 8px;
            text-align: left;
            font-weight: 600;
            white-space: nowrap;
        }
        td { padding: 8px; border-bottom: 1px solid var(--border); }
        tr.odd { background: #fafafa; }
        tr.even { background: #ffffff; }
        tr:hover { background: #e8f4ff; }
        .row-num { text-align: center; color: #605e5c; width: 40px; }
        .path-cell { max-width: 300px; word-break: break-all; }
        .path-cell a { color: var(--primary); text-decoration: none; }
        .path-cell a:hover { text-decoration: underline; cursor: pointer; }
        .date-cell { white-space: nowrap; font-family: Consolas, monospace; font-size: 11px; }
        .size-cell { text-align: right; font-family: Consolas, monospace; font-size: 11px; }
        .no-results { text-align: center; padding: 30px; color: #605e5c; font-style: italic; }
        .note { background: #fff4ce; border: 1px solid var(--warning); border-radius: 4px; padding: 10px; margin-bottom: 15px; font-size: 12px; }
        .archive-badge { background: #e0f0ff; color: #0078d4; padding: 2px 8px; border-radius: 4px; font-size: 11px; margin-left: 8px; }
        footer { margin-top: 15px; text-align: center; color: #605e5c; font-size: 11px; }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>VBS Scanner Report $(if ($EntryType -eq 'ArchiveRoot') { '<span class="archive-badge">Archive Scan</span>' })</h1>
            <div class="subtitle">Generated: $($EndTime.ToString("yyyy-MM-dd HH:mm:ss")) | VBS Scanner Utility v$Script:AppVersion</div>
        </header>

        <div class="summary-grid">
            <div class="summary-card success">
                <div class="label">Files Found</div>
                <div class="value">$($Results.Count)</div>
            </div>
            <div class="summary-card">
                <div class="label">Total Size</div>
                <div class="value">$TotalSizeMB MB</div>
            </div>
            <div class="summary-card $(if ($ErrorCount -gt 0) { 'error' } else { 'success' })">
                <div class="label">Errors</div>
                <div class="value">$ErrorCount</div>
            </div>
            <div class="summary-card">
                <div class="label">Duration</div>
                <div class="value">$DurationString</div>
            </div>
        </div>

        <div class="info-box">
            <h2>Scan Details</h2>
            <p><strong>Entry Type:</strong> $EntryTypeDisplay</p>
            <p><strong>Scan Root:</strong> $([System.Web.HttpUtility]::HtmlEncode($ScanRoot))</p>
            <p><strong>Start Time:</strong> $($StartTime.ToString("yyyy-MM-dd HH:mm:ss"))</p>
            <p><strong>End Time:</strong> $($EndTime.ToString("yyyy-MM-dd HH:mm:ss"))</p>
        </div>

        $PackageSummaryHtml

        <div class="note">
            <strong>Tip:</strong> Click on any file path to open it in Notepad (when viewing in the application).
        </div>

        <div class="results-box">
            <h2>Discovered VBS Files ($($Results.Count))</h2>
            $(if ($Results.Count -eq 0) {
                '<div class="no-results">No .vbs files were found.</div>'
            } else {
                @"
            <table>
                <thead>
                    <tr>
                        <th>#</th>
                        <th>File Name</th>
                        <th>Full Path</th>
                        <th>Parent Folder</th>
                        <th>Package</th>
                        <th>Version</th>
                        <th>Build</th>
                        <th>Last Modified</th>
                        <th>Size (Bytes)</th>
                    </tr>
                </thead>
                <tbody>$TableRows
                </tbody>
            </table>
"@
            })
        </div>

        <footer>
            <p>VBS Scanner Utility v$Script:AppVersion | PowerShell $($PSVersionTable.PSVersion.ToString())</p>
        </footer>
    </div>
</body>
</html>
"@

    try {
        Set-Content -Path $OutputPath -Value $HtmlContent -Encoding UTF8 -Force -ErrorAction Stop
        Write-CMTraceLog -Message "HTML report created: $OutputPath" -Component "HtmlReport"
        return $true
    }
    catch {
        Write-CMTraceLog -Message "Failed to create HTML report: $($_.Exception.Message)" -Severity 3 -Component "HtmlReport"
        return $false
    }
}
#endregion

#region ===== SCAN FUNCTION =====
function Start-VbsScan {
    <#
    .SYNOPSIS
        Scans for .vbs files with Phase 2 Archive metadata extraction support.
    #>
    param(
        [string]$ScanRoot,
        [string]$EntryType,
        [bool]$Recurse,
        [string[]]$ExcludePaths,
        [System.Windows.Forms.ProgressBar]$ProgressBar,
        [System.Windows.Forms.Label]$StatusLabel,
        [System.Windows.Forms.DataGridView]$DataGrid,
        [System.Windows.Forms.Form]$ParentForm
    )

    $Script:ScanResults.Clear()
    $Script:ErrorCount = 0
    $Script:ScanCancelled = $false
    $Script:ArchiveRoot = if ($EntryType -eq "ArchiveRoot") { $ScanRoot } else { "" }
    $DataGrid.Rows.Clear()

    $DirsToProcess = [System.Collections.Queue]::new()
    $FileCount = 0
    $DirCount = 0
    $LastUIUpdate = Get-Date

    # Validate root path
    if (-not (Test-PathAccessible -Path $ScanRoot)) {
        Write-CMTraceLog -Message "Cannot access scan root: $ScanRoot" -Severity 3 -Component "Scan"
        $StatusLabel.Text = "Error: Cannot access $ScanRoot"
        $StatusLabel.ForeColor = [System.Drawing.Color]::Red
        return $false
    }

    Write-CMTraceLog -Message "Starting scan - EntryType: $EntryType | Root: $ScanRoot | Recurse: $Recurse" -Component "Scan"
    $DirsToProcess.Enqueue($ScanRoot)
    $ProgressBar.Style = "Marquee"
    $ProgressBar.MarqueeAnimationSpeed = 30

    while ($DirsToProcess.Count -gt 0) {
        # Check for cancellation
        if ($Script:ScanCancelled) {
            Write-CMTraceLog -Message "Scan cancelled by user" -Severity 2 -Component "Scan"
            $StatusLabel.Text = "Scan cancelled"
            $StatusLabel.ForeColor = [System.Drawing.Color]::Orange
            $ProgressBar.Style = "Continuous"
            return $false
        }

        $CurrentPath = $DirsToProcess.Dequeue()
        $DirCount++

        # Check exclusions
        if (Test-PathExcluded -Path $CurrentPath -ExcludePaths $ExcludePaths) {
            continue
        }

        # Update UI periodically (every 100ms) for responsiveness
        $Now = Get-Date
        if (($Now - $LastUIUpdate).TotalMilliseconds -ge 100) {
            $ShortPath = if ($CurrentPath.Length -gt 60) { "..." + $CurrentPath.Substring($CurrentPath.Length - 57) } else { $CurrentPath }
            $StatusLabel.Text = "Files: $FileCount | Dirs: $DirCount | $ShortPath"
            [System.Windows.Forms.Application]::DoEvents()
            $LastUIUpdate = $Now
        }

        try {
            $Items = Get-ChildItem -LiteralPath $CurrentPath -Force -ErrorAction Stop

            foreach ($Item in $Items) {
                if ($Script:ScanCancelled) {
                    break
                }

                if ($Item.PSIsContainer) {
                    if ($Recurse) {
                        # Skip reparse points
                        if (-not ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                            $DirsToProcess.Enqueue($Item.FullName)
                        }
                    }
                }
                else {
                    if ($Item.Extension -ieq ".vbs") {
                        # Extract archive metadata if applicable
                        $PackageName = ""
                        $Version = ""
                        $Build = ""

                        if ($EntryType -eq "ArchiveRoot" -and $Script:ArchiveRoot) {
                            $Metadata = Get-ArchiveMetadataFromPath -ArchiveRoot $Script:ArchiveRoot -FullPath $Item.FullName
                            $PackageName = $Metadata.PackageName
                            $Version = $Metadata.Version
                            $Build = $Metadata.Build
                        }

                        $FileInfo = [PSCustomObject]@{
                            FileName      = $Item.Name
                            FullPath      = $Item.FullName
                            ParentFolder  = $Item.DirectoryName
                            LastWriteTime = $Item.LastWriteTime
                            SizeBytes     = $Item.Length
                            PackageName   = $PackageName
                            Version       = $Version
                            Build         = $Build
                        }
                        $null = $Script:ScanResults.Add($FileInfo)
                        $FileCount++

                        # Add to grid with new columns
                        $null = $DataGrid.Rows.Add(
                            $Item.Name,
                            $Item.FullName,
                            $Item.DirectoryName,
                            $PackageName,
                            $Version,
                            $Build,
                            $Item.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"),
                            $Item.Length
                        )

                        Write-CMTraceLog -Message "Found: $($Item.FullName) | Pkg: $PackageName | Ver: $Version | Build: $Build" -Component "Scan"
                    }
                }
            }
        }
        catch [System.UnauthorizedAccessException] {
            $Script:ErrorCount++
            Write-CMTraceLog -Message "Access denied: $CurrentPath - $($_.Exception.Message)" -Severity 3 -Component "Scan"
        }
        catch [System.IO.DirectoryNotFoundException] {
            $Script:ErrorCount++
            Write-CMTraceLog -Message "Directory not found: $CurrentPath" -Severity 3 -Component "Scan"
        }
        catch {
            $Script:ErrorCount++
            Write-CMTraceLog -Message "Error scanning $CurrentPath - $($_.Exception.Message)" -Severity 3 -Component "Scan"
        }
    }

    $ProgressBar.Style = "Continuous"
    $ProgressBar.Value = 100
    Write-CMTraceLog -Message "Scan complete. Found $FileCount VBS files with $($Script:ErrorCount) errors" -Component "Scan"
    return $true
}
#endregion

#region ===== GUI CONSTRUCTION =====
function Build-MainForm {
    Write-CMTraceLog -Message "========== $Script:AppName v$Script:AppVersion Started ==========" -Component "Main"
    Write-CMTraceLog -Message "PowerShell Version: $($PSVersionTable.PSVersion.ToString())" -Component "Main"
    Write-CMTraceLog -Message "Computer: $env:COMPUTERNAME | User: $env:USERNAME" -Component "Main"

    #region Main Form
    $MainForm = New-Object System.Windows.Forms.Form
    $MainForm.Text = "$Script:AppName v$Script:AppVersion"
    $MainForm.Size = New-Object System.Drawing.Size(1300, 850)
    $MainForm.StartPosition = "CenterScreen"
    $MainForm.MinimumSize = New-Object System.Drawing.Size(1100, 650)
    $MainForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $MainForm.Icon = [System.Drawing.SystemIcons]::Application
    #endregion

    #region SplitContainer for Results/Report
    $SplitContainer = New-Object System.Windows.Forms.SplitContainer
    $SplitContainer.Dock = "Fill"
    $SplitContainer.Orientation = "Horizontal"
    $SplitContainer.SplitterDistance = 350
    $SplitContainer.Panel1MinSize = 200
    $SplitContainer.Panel2MinSize = 150
    #endregion

    #region Top Panel - Input Controls
    $TopPanel = New-Object System.Windows.Forms.Panel
    $TopPanel.Dock = "Top"
    $TopPanel.Height = 210
    $TopPanel.Padding = New-Object System.Windows.Forms.Padding(10)

    # GroupBox for Input Type - expanded for 3 options
    $InputGroupBox = New-Object System.Windows.Forms.GroupBox
    $InputGroupBox.Text = "Scan Target"
    $InputGroupBox.Location = New-Object System.Drawing.Point(10, 10)
    $InputGroupBox.Size = New-Object System.Drawing.Size(620, 120)

    # Radio 1: Device Name / Local Path
    $RadioDevice = New-Object System.Windows.Forms.RadioButton
    $RadioDevice.Text = "Device/Path:"
    $RadioDevice.Location = New-Object System.Drawing.Point(15, 25)
    $RadioDevice.Size = New-Object System.Drawing.Size(100, 20)
    $RadioDevice.Checked = $true

    $TxtDeviceName = New-Object System.Windows.Forms.TextBox
    $TxtDeviceName.Location = New-Object System.Drawing.Point(120, 23)
    $TxtDeviceName.Size = New-Object System.Drawing.Size(200, 23)
    $TxtDeviceName.Text = ""

    $LblDeviceHint = New-Object System.Windows.Forms.Label
    $LblDeviceHint.Text = "(e.g., C:\temp or PC-123)"
    $LblDeviceHint.Location = New-Object System.Drawing.Point(330, 26)
    $LblDeviceHint.Size = New-Object System.Drawing.Size(280, 18)
    $LblDeviceHint.ForeColor = [System.Drawing.Color]::Gray
    $LblDeviceHint.Font = New-Object System.Drawing.Font("Segoe UI", 8)

    # Radio 2: UNC Path
    $RadioUNC = New-Object System.Windows.Forms.RadioButton
    $RadioUNC.Text = "UNC Path:"
    $RadioUNC.Location = New-Object System.Drawing.Point(15, 55)
    $RadioUNC.Size = New-Object System.Drawing.Size(100, 20)

    $TxtUNCPath = New-Object System.Windows.Forms.TextBox
    $TxtUNCPath.Location = New-Object System.Drawing.Point(120, 53)
    $TxtUNCPath.Size = New-Object System.Drawing.Size(380, 23)
    $TxtUNCPath.Text = ""
    $TxtUNCPath.Enabled = $false

    $LblUNCHint = New-Object System.Windows.Forms.Label
    $LblUNCHint.Text = "(e.g., \\server\share\folder)"
    $LblUNCHint.Location = New-Object System.Drawing.Point(510, 56)
    $LblUNCHint.Size = New-Object System.Drawing.Size(100, 18)
    $LblUNCHint.ForeColor = [System.Drawing.Color]::Gray
    $LblUNCHint.Font = New-Object System.Drawing.Font("Segoe UI", 8)

    # Radio 3: Archive Root (NEW in Phase 2)
    $RadioArchive = New-Object System.Windows.Forms.RadioButton
    $RadioArchive.Text = "Archive Root:"
    $RadioArchive.Location = New-Object System.Drawing.Point(15, 85)
    $RadioArchive.Size = New-Object System.Drawing.Size(100, 20)

    $TxtArchiveRoot = New-Object System.Windows.Forms.TextBox
    $TxtArchiveRoot.Location = New-Object System.Drawing.Point(120, 83)
    $TxtArchiveRoot.Size = New-Object System.Drawing.Size(380, 23)
    $TxtArchiveRoot.Text = ""
    $TxtArchiveRoot.Enabled = $false

    $LblArchiveHint = New-Object System.Windows.Forms.Label
    $LblArchiveHint.Text = "(e.g., \\Server\Archive)"
    $LblArchiveHint.Location = New-Object System.Drawing.Point(510, 86)
    $LblArchiveHint.Size = New-Object System.Drawing.Size(100, 18)
    $LblArchiveHint.ForeColor = [System.Drawing.Color]::Gray
    $LblArchiveHint.Font = New-Object System.Drawing.Font("Segoe UI", 8)

    $InputGroupBox.Controls.Add($RadioDevice)
    $InputGroupBox.Controls.Add($TxtDeviceName)
    $InputGroupBox.Controls.Add($LblDeviceHint)
    $InputGroupBox.Controls.Add($RadioUNC)
    $InputGroupBox.Controls.Add($TxtUNCPath)
    $InputGroupBox.Controls.Add($LblUNCHint)
    $InputGroupBox.Controls.Add($RadioArchive)
    $InputGroupBox.Controls.Add($TxtArchiveRoot)
    $InputGroupBox.Controls.Add($LblArchiveHint)

    # GroupBox for Options
    $OptionsGroupBox = New-Object System.Windows.Forms.GroupBox
    $OptionsGroupBox.Text = "Options"
    $OptionsGroupBox.Location = New-Object System.Drawing.Point(640, 10)
    $OptionsGroupBox.Size = New-Object System.Drawing.Size(620, 120)

    $ChkRecurse = New-Object System.Windows.Forms.CheckBox
    $ChkRecurse.Text = "Recurse subdirectories"
    $ChkRecurse.Location = New-Object System.Drawing.Point(15, 25)
    $ChkRecurse.Size = New-Object System.Drawing.Size(160, 20)
    $ChkRecurse.Checked = $true

    $LblExclude = New-Object System.Windows.Forms.Label
    $LblExclude.Text = "Exclude paths (;-delimited):"
    $LblExclude.Location = New-Object System.Drawing.Point(15, 55)
    $LblExclude.Size = New-Object System.Drawing.Size(150, 18)

    $TxtExcludePaths = New-Object System.Windows.Forms.TextBox
    $TxtExcludePaths.Location = New-Object System.Drawing.Point(170, 53)
    $TxtExcludePaths.Size = New-Object System.Drawing.Size(430, 23)

    # Archive structure info label
    $LblArchiveInfo = New-Object System.Windows.Forms.Label
    $LblArchiveInfo.Text = "Archive structure: \\Server\Archive\Vendor\PackageName\Version\Type\Build\"
    $LblArchiveInfo.Location = New-Object System.Drawing.Point(15, 85)
    $LblArchiveInfo.Size = New-Object System.Drawing.Size(590, 18)
    $LblArchiveInfo.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $LblArchiveInfo.Font = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)

    $OptionsGroupBox.Controls.Add($ChkRecurse)
    $OptionsGroupBox.Controls.Add($LblExclude)
    $OptionsGroupBox.Controls.Add($TxtExcludePaths)
    $OptionsGroupBox.Controls.Add($LblArchiveInfo)

    # Output Folder Selection
    $LblOutputFolder = New-Object System.Windows.Forms.Label
    $LblOutputFolder.Text = "Output Folder:"
    $LblOutputFolder.Location = New-Object System.Drawing.Point(10, 140)
    $LblOutputFolder.Size = New-Object System.Drawing.Size(90, 20)

    $TxtOutputFolder = New-Object System.Windows.Forms.TextBox
    $TxtOutputFolder.Location = New-Object System.Drawing.Point(105, 138)
    $TxtOutputFolder.Size = New-Object System.Drawing.Size(800, 23)
    $TxtOutputFolder.Text = $Script:DefaultOutputFolder

    $BtnBrowseFolder = New-Object System.Windows.Forms.Button
    $BtnBrowseFolder.Text = "Browse..."
    $BtnBrowseFolder.Location = New-Object System.Drawing.Point(915, 136)
    $BtnBrowseFolder.Size = New-Object System.Drawing.Size(80, 27)

    # Action Buttons
    $BtnScan = New-Object System.Windows.Forms.Button
    $BtnScan.Text = "Scan"
    $BtnScan.Location = New-Object System.Drawing.Point(10, 175)
    $BtnScan.Size = New-Object System.Drawing.Size(100, 30)
    $BtnScan.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $BtnScan.ForeColor = [System.Drawing.Color]::White
    $BtnScan.FlatStyle = "Flat"
    $BtnScan.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

    $BtnCancel = New-Object System.Windows.Forms.Button
    $BtnCancel.Text = "Cancel"
    $BtnCancel.Location = New-Object System.Drawing.Point(120, 175)
    $BtnCancel.Size = New-Object System.Drawing.Size(80, 30)
    $BtnCancel.Enabled = $false

    $BtnGenerateReport = New-Object System.Windows.Forms.Button
    $BtnGenerateReport.Text = "Generate Report"
    $BtnGenerateReport.Location = New-Object System.Drawing.Point(210, 175)
    $BtnGenerateReport.Size = New-Object System.Drawing.Size(110, 30)
    $BtnGenerateReport.Enabled = $false

    $BtnOpenLog = New-Object System.Windows.Forms.Button
    $BtnOpenLog.Text = "Open Log"
    $BtnOpenLog.Location = New-Object System.Drawing.Point(330, 175)
    $BtnOpenLog.Size = New-Object System.Drawing.Size(80, 30)

    $BtnExportCSV = New-Object System.Windows.Forms.Button
    $BtnExportCSV.Text = "Export CSV"
    $BtnExportCSV.Location = New-Object System.Drawing.Point(420, 175)
    $BtnExportCSV.Size = New-Object System.Drawing.Size(90, 30)
    $BtnExportCSV.Enabled = $false

    # Progress Bar and Status
    $ProgressBar = New-Object System.Windows.Forms.ProgressBar
    $ProgressBar.Location = New-Object System.Drawing.Point(530, 175)
    $ProgressBar.Size = New-Object System.Drawing.Size(350, 25)
    $ProgressBar.Style = "Continuous"

    $LblStatus = New-Object System.Windows.Forms.Label
    $LblStatus.Text = "Ready"
    $LblStatus.Location = New-Object System.Drawing.Point(890, 180)
    $LblStatus.Size = New-Object System.Drawing.Size(350, 20)
    $LblStatus.ForeColor = [System.Drawing.Color]::DarkGreen

    $TopPanel.Controls.Add($InputGroupBox)
    $TopPanel.Controls.Add($OptionsGroupBox)
    $TopPanel.Controls.Add($LblOutputFolder)
    $TopPanel.Controls.Add($TxtOutputFolder)
    $TopPanel.Controls.Add($BtnBrowseFolder)
    $TopPanel.Controls.Add($BtnScan)
    $TopPanel.Controls.Add($BtnCancel)
    $TopPanel.Controls.Add($BtnGenerateReport)
    $TopPanel.Controls.Add($BtnOpenLog)
    $TopPanel.Controls.Add($BtnExportCSV)
    $TopPanel.Controls.Add($ProgressBar)
    $TopPanel.Controls.Add($LblStatus)
    #endregion

    #region DataGridView for Results - with Phase 2 columns
    $DataGridView = New-Object System.Windows.Forms.DataGridView
    $DataGridView.Dock = "Fill"
    $DataGridView.AllowUserToAddRows = $false
    $DataGridView.AllowUserToDeleteRows = $false
    $DataGridView.ReadOnly = $true
    $DataGridView.SelectionMode = "FullRowSelect"
    $DataGridView.MultiSelect = $false
    $DataGridView.AutoSizeColumnsMode = "Fill"
    $DataGridView.RowHeadersVisible = $false
    $DataGridView.BackgroundColor = [System.Drawing.Color]::White
    $DataGridView.BorderStyle = "None"
    $DataGridView.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $DataGridView.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $DataGridView.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $DataGridView.EnableHeadersVisualStyles = $false
    $DataGridView.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $DataGridView.AllowUserToOrderColumns = $true  # Enable column reordering

    # Define columns - with Phase 2 additions
    $ColFileName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColFileName.Name = "FileName"
    $ColFileName.HeaderText = "File Name"
    $ColFileName.FillWeight = 15
    $null = $DataGridView.Columns.Add($ColFileName)

    $ColFullPath = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColFullPath.Name = "FullPath"
    $ColFullPath.HeaderText = "Full Path"
    $ColFullPath.FillWeight = 25
    $null = $DataGridView.Columns.Add($ColFullPath)

    $ColParentFolder = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColParentFolder.Name = "ParentFolder"
    $ColParentFolder.HeaderText = "Parent Folder"
    $ColParentFolder.FillWeight = 18
    $null = $DataGridView.Columns.Add($ColParentFolder)

    # Phase 2: New columns for Archive metadata
    $ColPackageName = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColPackageName.Name = "PackageName"
    $ColPackageName.HeaderText = "Package"
    $ColPackageName.FillWeight = 10
    $null = $DataGridView.Columns.Add($ColPackageName)

    $ColVersion = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColVersion.Name = "Version"
    $ColVersion.HeaderText = "Version"
    $ColVersion.FillWeight = 8
    $null = $DataGridView.Columns.Add($ColVersion)

    $ColBuild = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColBuild.Name = "Build"
    $ColBuild.HeaderText = "Build"
    $ColBuild.FillWeight = 8
    $null = $DataGridView.Columns.Add($ColBuild)

    $ColLastWriteTime = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColLastWriteTime.Name = "LastWriteTime"
    $ColLastWriteTime.HeaderText = "Last Modified"
    $ColLastWriteTime.FillWeight = 10
    $null = $DataGridView.Columns.Add($ColLastWriteTime)

    $ColSizeBytes = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
    $ColSizeBytes.Name = "SizeBytes"
    $ColSizeBytes.HeaderText = "Size (Bytes)"
    $ColSizeBytes.FillWeight = 6
    $ColSizeBytes.DefaultCellStyle.Alignment = "MiddleRight"
    $null = $DataGridView.Columns.Add($ColSizeBytes)

    # Context Menu for DataGridView
    $ContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $MenuOpenNotepad = New-Object System.Windows.Forms.ToolStripMenuItem
    $MenuOpenNotepad.Text = "Open in Notepad"
    $MenuCopyPath = New-Object System.Windows.Forms.ToolStripMenuItem
    $MenuCopyPath.Text = "Copy Full Path"
    $MenuOpenFolder = New-Object System.Windows.Forms.ToolStripMenuItem
    $MenuOpenFolder.Text = "Open Containing Folder"
    $null = $ContextMenu.Items.Add($MenuOpenNotepad)
    $null = $ContextMenu.Items.Add($MenuCopyPath)
    $null = $ContextMenu.Items.Add($MenuOpenFolder)
    $DataGridView.ContextMenuStrip = $ContextMenu
    #endregion

    #region WebBrowser for HTML Report
    $LblReportHeader = New-Object System.Windows.Forms.Label
    $LblReportHeader.Text = "HTML Report Preview:"
    $LblReportHeader.Dock = "Top"
    $LblReportHeader.Height = 25
    $LblReportHeader.TextAlign = "MiddleLeft"
    $LblReportHeader.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $LblReportHeader.ForeColor = [System.Drawing.Color]::White
    $LblReportHeader.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $LblReportHeader.Padding = New-Object System.Windows.Forms.Padding(5, 0, 0, 0)

    $WebBrowser = New-Object System.Windows.Forms.WebBrowser
    $WebBrowser.Dock = "Fill"
    $WebBrowser.ScriptErrorsSuppressed = $true
    #endregion

    #region Assemble Layout
    $SplitContainer.Panel1.Controls.Add($DataGridView)
    $SplitContainer.Panel2.Controls.Add($WebBrowser)
    $SplitContainer.Panel2.Controls.Add($LblReportHeader)

    $MainForm.Controls.Add($SplitContainer)
    $MainForm.Controls.Add($TopPanel)
    #endregion

    #region EVENT HANDLERS

    # Radio button toggle for entry type selection
    $RadioDevice.Add_CheckedChanged({
        $TxtDeviceName.Enabled = $RadioDevice.Checked
        $TxtUNCPath.Enabled = $RadioUNC.Checked
        $TxtArchiveRoot.Enabled = $RadioArchive.Checked
        if ($RadioDevice.Checked) { $Script:CurrentEntryType = "DeviceName" }
    })

    $RadioUNC.Add_CheckedChanged({
        $TxtDeviceName.Enabled = $RadioDevice.Checked
        $TxtUNCPath.Enabled = $RadioUNC.Checked
        $TxtArchiveRoot.Enabled = $RadioArchive.Checked
        if ($RadioUNC.Checked) { $Script:CurrentEntryType = "UNC" }
    })

    $RadioArchive.Add_CheckedChanged({
        $TxtDeviceName.Enabled = $RadioDevice.Checked
        $TxtUNCPath.Enabled = $RadioUNC.Checked
        $TxtArchiveRoot.Enabled = $RadioArchive.Checked
        if ($RadioArchive.Checked) { $Script:CurrentEntryType = "ArchiveRoot" }
    })

    # Browse folder
    $BtnBrowseFolder.Add_Click({
        $FolderBrowser = New-Object System.Windows.Forms.FolderBrowserDialog
        $FolderBrowser.Description = "Select Output Folder"
        $FolderBrowser.SelectedPath = $TxtOutputFolder.Text
        if ($FolderBrowser.ShowDialog() -eq "OK") {
            $TxtOutputFolder.Text = $FolderBrowser.SelectedPath
            $Script:LogFile = Join-Path -Path $FolderBrowser.SelectedPath -ChildPath "VBSScanner_$($Script:Timestamp).log"
        }
    })

    # Open Log button
    $BtnOpenLog.Add_Click({
        if (Test-Path -Path $Script:LogFile) {
            Start-Process -FilePath "notepad.exe" -ArgumentList "`"$Script:LogFile`""
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Log file not found: $Script:LogFile", "File Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
    })

    # Export CSV button - updated for Phase 2 columns
    $BtnExportCSV.Add_Click({
        if ($Script:ScanResults.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No results to export.", "Export CSV", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }

        $SaveDialog = New-Object System.Windows.Forms.SaveFileDialog
        $SaveDialog.Filter = "CSV Files (*.csv)|*.csv"
        $SaveDialog.FileName = "VBSScanner_Results_$($Script:Timestamp).csv"
        $SaveDialog.InitialDirectory = $TxtOutputFolder.Text

        if ($SaveDialog.ShowDialog() -eq "OK") {
            try {
                # Export with all columns including Phase 2 additions
                $Script:ScanResults | Select-Object FileName, FullPath, ParentFolder, PackageName, Version, Build, LastWriteTime, SizeBytes | 
                    Export-Csv -Path $SaveDialog.FileName -NoTypeInformation -Encoding UTF8
                Write-CMTraceLog -Message "Exported results to CSV: $($SaveDialog.FileName)" -Component "Export"
                [System.Windows.Forms.MessageBox]::Show("Results exported to: $($SaveDialog.FileName)", "Export Complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            }
            catch {
                Write-CMTraceLog -Message "Failed to export CSV: $($_.Exception.Message)" -Severity 3 -Component "Export"
                [System.Windows.Forms.MessageBox]::Show("Failed to export: $($_.Exception.Message)", "Export Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            }
        }
    })

    # DataGridView double-click to open in Notepad
    $DataGridView.Add_CellDoubleClick({
        param($sender, $e)
        if ($e.RowIndex -ge 0) {
            $FilePath = $DataGridView.Rows[$e.RowIndex].Cells["FullPath"].Value
            if ($FilePath) {
                Open-FileInNotepad -FilePath $FilePath
            }
        }
    })

    # Context menu - Open in Notepad
    $MenuOpenNotepad.Add_Click({
        if ($DataGridView.SelectedRows.Count -gt 0) {
            $FilePath = $DataGridView.SelectedRows[0].Cells["FullPath"].Value
            if ($FilePath) {
                Open-FileInNotepad -FilePath $FilePath
            }
        }
    })

    # Context menu - Copy Path
    $MenuCopyPath.Add_Click({
        if ($DataGridView.SelectedRows.Count -gt 0) {
            $FilePath = $DataGridView.SelectedRows[0].Cells["FullPath"].Value
            if ($FilePath) {
                [System.Windows.Forms.Clipboard]::SetText($FilePath)
                $LblStatus.Text = "Path copied to clipboard"
            }
        }
    })

    # Context menu - Open Containing Folder
    $MenuOpenFolder.Add_Click({
        if ($DataGridView.SelectedRows.Count -gt 0) {
            $FilePath = $DataGridView.SelectedRows[0].Cells["FullPath"].Value
            if ($FilePath) {
                $ParentFolder = Split-Path -Path $FilePath -Parent
                if (Test-Path -Path $ParentFolder) {
                    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$ParentFolder`""
                }
            }
        }
    })

    # WebBrowser Navigating event - intercept file:// links to open in Notepad
    $WebBrowser.Add_Navigating({
        param($sender, $e)
        $Url = $e.Url.ToString()

        if ($Url -like "file:///*" -and $Url -like "*.vbs") {
            $e.Cancel = $true

            # Convert file URI to local path
            $FilePath = $Url -replace "^file:///", ""
            $FilePath = $FilePath -replace "/", "\"
            $FilePath = [System.Web.HttpUtility]::UrlDecode($FilePath)

            Write-CMTraceLog -Message "WebBrowser link clicked: $FilePath" -Component "WebBrowser"
            Open-FileInNotepad -FilePath $FilePath
        }
    })

    # Generate Report button - updated for Phase 2
    $BtnGenerateReport.Add_Click({
        if ($Script:ScanResults.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No results to generate report from.", "Generate Report", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }

        $EndTime = Get-Date
        $Script:HtmlReportFile = Join-Path -Path $TxtOutputFolder.Text -ChildPath "VBSScanner_Report_$($Script:Timestamp).html"

        # Determine entry type and scan root
        $EntryType = $Script:CurrentEntryType
        $ScanRoot = Get-ScanRootFromInput -InputType $EntryType -DeviceName $TxtDeviceName.Text -UncPath $TxtUNCPath.Text -ArchiveRoot $TxtArchiveRoot.Text

        $LblStatus.Text = "Generating HTML report..."
        $MainForm.Refresh()

        $Success = New-HtmlReport -Results $Script:ScanResults -ScanRoot $ScanRoot -EntryType $EntryType -StartTime $Script:StartTime -EndTime $EndTime -ErrorCount $Script:ErrorCount -OutputPath $Script:HtmlReportFile

        if ($Success) {
            $WebBrowser.Navigate($Script:HtmlReportFile)
            $LblStatus.Text = "Report generated: $Script:HtmlReportFile"
            $LblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            Write-CMTraceLog -Message "Report displayed in WebBrowser" -Component "Report"
        }
        else {
            $LblStatus.Text = "Failed to generate report"
            $LblStatus.ForeColor = [System.Drawing.Color]::Red
        }
    })

    # Cancel button
    $BtnCancel.Add_Click({
        $Script:ScanCancelled = $true
        $LblStatus.Text = "Cancelling..."
        Write-CMTraceLog -Message "Scan cancellation requested by user" -Severity 2 -Component "Scan"
    })

    # Scan button click - updated for Phase 2
    $BtnScan.Add_Click({
        # Determine entry type
        $EntryType = "DeviceName"
        if ($RadioUNC.Checked) { $EntryType = "UNC" }
        if ($RadioArchive.Checked) { $EntryType = "ArchiveRoot" }
        $Script:CurrentEntryType = $EntryType

        # Get scan root based on entry type
        $ScanRoot = Get-ScanRootFromInput -InputType $EntryType -DeviceName $TxtDeviceName.Text -UncPath $TxtUNCPath.Text -ArchiveRoot $TxtArchiveRoot.Text

        if ([string]::IsNullOrWhiteSpace($ScanRoot)) {
            $ErrorMsg = switch ($EntryType) {
                "DeviceName" { "Please enter a valid Device Name or Local Path." }
                "UNC" { "Please enter a valid UNC Path." }
                "ArchiveRoot" { "Please enter a valid Archive Root (e.g., \\Server\Archive)." }
            }
            [System.Windows.Forms.MessageBox]::Show($ErrorMsg, "Input Required", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Warning)
            return
        }

        # Validate output folder
        if (-not (Test-Path -Path $TxtOutputFolder.Text -PathType Container)) {
            try {
                New-Item -Path $TxtOutputFolder.Text -ItemType Directory -Force | Out-Null
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show("Cannot create output folder: $($TxtOutputFolder.Text)", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                return
            }
        }

        # Update log file path
        $Script:Timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
        $Script:LogFile = Join-Path -Path $TxtOutputFolder.Text -ChildPath "VBSScanner_$($Script:Timestamp).log"

        # Parse exclude paths
        $ExcludePaths = @()
        if (-not [string]::IsNullOrWhiteSpace($TxtExcludePaths.Text)) {
            $ExcludePaths = $TxtExcludePaths.Text -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
        }

        Write-CMTraceLog -Message "Starting scan - EntryType: $EntryType | Root: $ScanRoot | Recurse: $($ChkRecurse.Checked) | Excludes: $($ExcludePaths -join ', ')" -Component "Scan"

        # Reset state
        $Script:StartTime = Get-Date
        $Script:ScanCancelled = $false
        $Script:IsScanning = $true
        $WebBrowser.Navigate("about:blank")

        # Update UI
        $BtnScan.Enabled = $false
        $BtnCancel.Enabled = $true
        $BtnGenerateReport.Enabled = $false
        $BtnExportCSV.Enabled = $false
        $ProgressBar.Value = 0
        $LblStatus.Text = "Initializing scan ($EntryType)..."
        $LblStatus.ForeColor = [System.Drawing.Color]::DarkBlue
        $MainForm.Refresh()

        # Run scan with entry type for metadata extraction
        $Success = Start-VbsScan -ScanRoot $ScanRoot -EntryType $EntryType -Recurse $ChkRecurse.Checked -ExcludePaths $ExcludePaths -ProgressBar $ProgressBar -StatusLabel $LblStatus -DataGrid $DataGridView -ParentForm $MainForm

        # Update UI after scan
        $Script:IsScanning = $false
        $BtnScan.Enabled = $true
        $BtnCancel.Enabled = $false
        $BtnGenerateReport.Enabled = $Script:ScanResults.Count -gt 0
        $BtnExportCSV.Enabled = $Script:ScanResults.Count -gt 0

        if ($Success -and -not $Script:ScanCancelled) {
            $Duration = (Get-Date) - $Script:StartTime
            $LblStatus.Text = "Complete: $($Script:ScanResults.Count) files | $($Script:ErrorCount) errors | $($Duration.ToString('hh\:mm\:ss'))"
            $LblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
            Write-CMTraceLog -Message "Scan completed ($EntryType). Results: $($Script:ScanResults.Count) files, $($Script:ErrorCount) errors" -Component "Scan"
        }
    })

    # Form closing
    $MainForm.Add_FormClosing({
        param($sender, $e)
        if ($Script:IsScanning) {
            $Result = [System.Windows.Forms.MessageBox]::Show("A scan is in progress. Are you sure you want to exit?", "Confirm Exit", [System.Windows.Forms.MessageBoxButtons]::YesNo, [System.Windows.Forms.MessageBoxIcon]::Question)
            if ($Result -eq "No") {
                $e.Cancel = $true
            }
            else {
                $Script:ScanCancelled = $true
            }
        }
        Write-CMTraceLog -Message "========== $Script:AppName Closed ==========" -Component "Main"
    })

    #endregion

    # Show the form
    $MainForm.Add_Shown({ $MainForm.Activate() })
    [void]$MainForm.ShowDialog()
}
#endregion

#region ===== MAIN ENTRY POINT =====
Build-MainForm
#endregion
