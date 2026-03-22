<#
.SYNOPSIS
    VBS Scanner Utility - Scans local and UNC paths for .vbs files and generates an HTML report.

.DESCRIPTION
    This script scans specified local paths and/or UNC shares for .vbs files, collects metadata,
    generates a detailed HTML report with clickable links to open files in Notepad, and logs
    all activities using CMTRACE-compatible formatting.

.PARAMETER ScanRoots
    One or more paths to scan. Accepts local paths (e.g., C:\Scripts) and UNC paths (e.g., \\server\share).

.PARAMETER Recurse
    Recursively scan subdirectories. Default: $true

.PARAMETER ExcludePaths
    Array of paths to exclude from scanning.

.PARAMETER MaxDepth
    Maximum directory depth to scan. If not specified, scans all levels.

.PARAMETER FollowReparsePoints
    Follow reparse points (junction points, symlinks). Default: $false

.PARAMETER OutputFolder
    Folder where HTML report and log file will be saved. Default: Current directory.

.EXAMPLE
    .\VBSScanner.ps1 -ScanRoots "C:\Scripts", "D:\Automation"
    Scans both paths recursively for .vbs files.

.EXAMPLE
    .\VBSScanner.ps1 -ScanRoots "\\server\share\scripts" -ExcludePaths "\\server\share\scripts\archive"
    Scans a UNC path excluding the archive subfolder.

.EXAMPLE
    .\VBSScanner.ps1 -ScanRoots "C:\" -MaxDepth 3 -OutputFolder "C:\Reports"
    Scans C:\ to a depth of 3 levels and outputs reports to C:\Reports.

.NOTES
    Author: Enterprise Endpoint Engineering
    Version: 1.0.0
    Requires: PowerShell 5.1
    Date: 2026-03-22
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0, HelpMessage = "One or more scan root paths (local or UNC).")]
    [ValidateNotNullOrEmpty()]
    [string[]]$ScanRoots,

    [Parameter(Mandatory = $false, HelpMessage = "Recursively scan subdirectories.")]
    [bool]$Recurse = $true,

    [Parameter(Mandatory = $false, HelpMessage = "Array of paths to exclude from scanning.")]
    [string[]]$ExcludePaths = @(),

    [Parameter(Mandatory = $false, HelpMessage = "Maximum directory depth to scan.")]
    [ValidateRange(1, 100)]
    [int]$MaxDepth,

    [Parameter(Mandatory = $false, HelpMessage = "Follow reparse points (junctions/symlinks).")]
    [bool]$FollowReparsePoints = $false,

    [Parameter(Mandatory = $false, HelpMessage = "Output folder for HTML report and log file.")]
    [string]$OutputFolder = (Get-Location).Path
)

#region ===== CONFIGURATION =====
$Script:ScriptName = "VBSScanner"
$Script:ScriptVersion = "1.0.0"
$Script:StartTime = Get-Date
$Script:Timestamp = $Script:StartTime.ToString("yyyyMMdd_HHmmss")
$Script:LogFile = Join-Path -Path $OutputFolder -ChildPath "$($Script:ScriptName)_$($Script:Timestamp).log"
$Script:HtmlReportFile = Join-Path -Path $OutputFolder -ChildPath "$($Script:ScriptName)_Report_$($Script:Timestamp).html"
$Script:HelperScriptFile = Join-Path -Path $OutputFolder -ChildPath "$($Script:ScriptName)_OpenInNotepad.cmd"
$Script:ErrorCount = 0
$Script:FilesFound = @()
#endregion

#region ===== CMTRACE-COMPATIBLE LOGGING =====
function Write-CMTraceLog {
    <#
    .SYNOPSIS
        Writes a log entry in CMTRACE-compatible format.

    .DESCRIPTION
        Creates log entries that can be parsed and viewed by CMTRACE.exe or CMLogViewer.
        Format: <![LOG[Message]LOG]!><time="HH:mm:ss.fff+TZOffset" date="MM-DD-YYYY" component="Component" context="" type="Severity" thread="ThreadID" file="FileName">

    .PARAMETER Message
        The message to log.

    .PARAMETER Component
        The component or function name generating the log entry.

    .PARAMETER Severity
        1 = Informational, 2 = Warning, 3 = Error

    .PARAMETER LogFile
        Path to the log file. Uses script-level variable if not specified.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true, Position = 0)]
        [ValidateNotNullOrEmpty()]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [string]$Component = $Script:ScriptName,

        [Parameter(Mandatory = $false)]
        [ValidateSet(1, 2, 3)]
        [int]$Severity = 1,

        [Parameter(Mandatory = $false)]
        [string]$LogFile = $Script:LogFile
    )

    # Get current timestamp
    $Now = Get-Date
    $TimeString = $Now.ToString("HH:mm:ss.fff")
    $DateString = $Now.ToString("MM-dd-yyyy")

    # Calculate timezone offset
    $UtcOffset = [System.TimeZoneInfo]::Local.GetUtcOffset($Now)
    $OffsetMinutes = $UtcOffset.TotalMinutes
    $OffsetSign = if ($OffsetMinutes -ge 0) { "+" } else { "-" }
    $OffsetString = "{0}{1}" -f $OffsetSign, [Math]::Abs($OffsetMinutes)

    # Get thread ID
    $ThreadId = [System.Threading.Thread]::CurrentThread.ManagedThreadId

    # Build CMTrace log entry
    $LogEntry = "<![LOG[$Message]LOG]!><time=""$TimeString$OffsetString"" date=""$DateString"" component=""$Component"" context="""" type=""$Severity"" thread=""$ThreadId"" file=""$Script:ScriptName"">"

    # Ensure output directory exists
    $LogDir = Split-Path -Path $LogFile -Parent
    if (-not (Test-Path -Path $LogDir -PathType Container)) {
        try {
            New-Item -Path $LogDir -ItemType Directory -Force -ErrorAction Stop | Out-Null
        }
        catch {
            Write-Warning "Failed to create log directory: $LogDir"
            return
        }
    }

    # Write to log file with retry logic for file locks
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
            Start-Sleep -Milliseconds 100
        }
    }

    # Also write to verbose stream for console visibility
    $SeverityText = switch ($Severity) {
        1 { "INFO" }
        2 { "WARN" }
        3 { "ERROR" }
    }
    Write-Verbose "[$SeverityText] $Message"
}
#endregion

#region ===== HELPER FUNCTIONS =====
function Test-PathAccessible {
    <#
    .SYNOPSIS
        Tests if a path is accessible without throwing terminating errors.

    .PARAMETER Path
        The path to test.

    .OUTPUTS
        Boolean indicating if path is accessible.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path
    )

    try {
        $null = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

function Get-DirectoryDepth {
    <#
    .SYNOPSIS
        Calculates the depth of a path relative to a root path.

    .PARAMETER Path
        The full path to measure.

    .PARAMETER RootPath
        The root path to measure from.

    .OUTPUTS
        Integer representing the depth level.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $true)]
        [string]$RootPath
    )

    $NormalizedPath = $Path.TrimEnd('\', '/')
    $NormalizedRoot = $RootPath.TrimEnd('\', '/')

    if ($NormalizedPath -eq $NormalizedRoot) {
        return 0
    }

    $RelativePath = $NormalizedPath.Substring($NormalizedRoot.Length).TrimStart('\', '/')
    $Depth = ($RelativePath -split '[\\/]').Count

    return $Depth
}

function Test-PathExcluded {
    <#
    .SYNOPSIS
        Checks if a path should be excluded based on ExcludePaths array.

    .PARAMETER Path
        The path to check.

    .PARAMETER ExcludePaths
        Array of paths to exclude.

    .OUTPUTS
        Boolean indicating if path should be excluded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [string[]]$ExcludePaths = @()
    )

    foreach ($ExcludePath in $ExcludePaths) {
        $NormalizedExclude = $ExcludePath.TrimEnd('\', '/').ToLower()
        $NormalizedPath = $Path.TrimEnd('\', '/').ToLower()

        if ($NormalizedPath -eq $NormalizedExclude -or $NormalizedPath.StartsWith("$NormalizedExclude\") -or $NormalizedPath.StartsWith("$NormalizedExclude/")) {
            return $true
        }
    }

    return $false
}

function Get-VbsFiles {
    <#
    .SYNOPSIS
        Scans a directory for .vbs files with metadata collection.

    .DESCRIPTION
        Recursively or non-recursively scans a directory for .vbs files,
        collecting metadata and handling access denied errors gracefully.

    .PARAMETER Path
        The root path to scan.

    .PARAMETER Recurse
        Whether to scan subdirectories.

    .PARAMETER ExcludePaths
        Paths to exclude from scanning.

    .PARAMETER MaxDepth
        Maximum depth to scan.

    .PARAMETER FollowReparsePoints
        Whether to follow junction points and symlinks.

    .OUTPUTS
        Array of PSCustomObjects with file metadata.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$Path,

        [Parameter(Mandatory = $false)]
        [bool]$Recurse = $true,

        [Parameter(Mandatory = $false)]
        [string[]]$ExcludePaths = @(),

        [Parameter(Mandatory = $false)]
        [int]$MaxDepth = 0,

        [Parameter(Mandatory = $false)]
        [bool]$FollowReparsePoints = $false
    )

    $Results = [System.Collections.ArrayList]::new()
    $DirsToProcess = [System.Collections.Queue]::new()
    $RootPath = $Path.TrimEnd('\', '/')

    # Validate root path accessibility
    if (-not (Test-PathAccessible -Path $RootPath)) {
        Write-CMTraceLog -Message "Cannot access root path: $RootPath" -Severity 3 -Component "Get-VbsFiles"
        $Script:ErrorCount++
        return $Results.ToArray()
    }

    Write-CMTraceLog -Message "Starting scan of: $RootPath" -Component "Get-VbsFiles"

    # Initialize queue with root path and depth 0
    $DirsToProcess.Enqueue(@{ Path = $RootPath; Depth = 0 })

    while ($DirsToProcess.Count -gt 0) {
        $Current = $DirsToProcess.Dequeue()
        $CurrentPath = $Current.Path
        $CurrentDepth = $Current.Depth

        # Check if path should be excluded
        if (Test-PathExcluded -Path $CurrentPath -ExcludePaths $ExcludePaths) {
            Write-CMTraceLog -Message "Skipping excluded path: $CurrentPath" -Severity 2 -Component "Get-VbsFiles"
            continue
        }

        # Check max depth
        if ($MaxDepth -gt 0 -and $CurrentDepth -gt $MaxDepth) {
            continue
        }

        try {
            # Get directory info to check for reparse points
            $DirInfo = Get-Item -LiteralPath $CurrentPath -Force -ErrorAction Stop

            # Skip reparse points if not following them
            if (-not $FollowReparsePoints -and $DirInfo.Attributes -band [System.IO.FileAttributes]::ReparsePoint) {
                Write-CMTraceLog -Message "Skipping reparse point: $CurrentPath" -Severity 2 -Component "Get-VbsFiles"
                continue
            }

            # Get all items in current directory
            $Items = Get-ChildItem -LiteralPath $CurrentPath -Force -ErrorAction Stop

            foreach ($Item in $Items) {
                if ($Item.PSIsContainer) {
                    # It's a directory - add to queue if recursing
                    if ($Recurse) {
                        $DirsToProcess.Enqueue(@{ Path = $Item.FullName; Depth = $CurrentDepth + 1 })
                    }
                }
                else {
                    # It's a file - check if it's a .vbs file
                    if ($Item.Extension -ieq ".vbs") {
                        $FileInfo = [PSCustomObject]@{
                            FileName       = $Item.Name
                            FullPath       = $Item.FullName
                            ParentFolder   = $Item.DirectoryName
                            LastWriteTime  = $Item.LastWriteTime
                            SizeBytes      = $Item.Length
                        }
                        $null = $Results.Add($FileInfo)
                        Write-CMTraceLog -Message "Found VBS file: $($Item.FullName)" -Component "Get-VbsFiles"
                    }
                }
            }
        }
        catch [System.UnauthorizedAccessException] {
            Write-CMTraceLog -Message "Access denied to path: $CurrentPath - $($_.Exception.Message)" -Severity 3 -Component "Get-VbsFiles"
            $Script:ErrorCount++
        }
        catch [System.IO.DirectoryNotFoundException] {
            Write-CMTraceLog -Message "Directory not found: $CurrentPath - $($_.Exception.Message)" -Severity 3 -Component "Get-VbsFiles"
            $Script:ErrorCount++
        }
        catch [System.IO.IOException] {
            Write-CMTraceLog -Message "IO error accessing: $CurrentPath - $($_.Exception.Message)" -Severity 3 -Component "Get-VbsFiles"
            $Script:ErrorCount++
        }
        catch {
            Write-CMTraceLog -Message "Unexpected error scanning $CurrentPath - Exception: $($_.Exception.GetType().FullName) - Message: $($_.Exception.Message) - StackTrace: $($_.ScriptStackTrace)" -Severity 3 -Component "Get-VbsFiles"
            $Script:ErrorCount++
        }
    }

    Write-CMTraceLog -Message "Completed scan of $RootPath - Found $($Results.Count) VBS files" -Component "Get-VbsFiles"
    return $Results.ToArray()
}

function New-NotepadHelperScript {
    <#
    .SYNOPSIS
        Creates a helper CMD script that opens files in Notepad.

    .DESCRIPTION
        Generates a companion .cmd file that accepts a file path as an argument
        and opens it in Notepad. This is used for HTML report links.

    .PARAMETER OutputPath
        Path where the helper script will be created.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [string]$OutputPath
    )

    $HelperContent = @'
@echo off
REM VBS Scanner Utility - Notepad Launcher Helper
REM This script opens the specified file in Notepad
REM Usage: VBSScanner_OpenInNotepad.cmd "C:\Path\To\File.vbs"

if "%~1"=="" (
    echo Error: No file path specified.
    echo Usage: %~nx0 "path\to\file.vbs"
    pause
    exit /b 1
)

if not exist "%~1" (
    echo Error: File not found: %~1
    pause
    exit /b 1
)

start "" notepad.exe "%~1"
exit /b 0
'@

    try {
        Set-Content -Path $OutputPath -Value $HelperContent -Encoding ASCII -Force -ErrorAction Stop
        Write-CMTraceLog -Message "Created Notepad helper script: $OutputPath" -Component "New-NotepadHelperScript"
        return $true
    }
    catch {
        Write-CMTraceLog -Message "Failed to create helper script: $($_.Exception.Message)" -Severity 3 -Component "New-NotepadHelperScript"
        return $false
    }
}

function ConvertTo-HtmlReport {
    <#
    .SYNOPSIS
        Generates an HTML report from scan results.

    .DESCRIPTION
        Creates a formatted HTML report with summary statistics and a detailed
        table of all discovered VBS files with clickable links.

    .PARAMETER Results
        Array of file metadata objects from Get-VbsFiles.

    .PARAMETER ScanRoots
        Original scan root paths for reference.

    .PARAMETER StartTime
        When the scan started.

    .PARAMETER EndTime
        When the scan completed.

    .PARAMETER ErrorCount
        Number of errors encountered.

    .PARAMETER OutputPath
        Path for the HTML report file.

    .PARAMETER HelperScriptPath
        Path to the Notepad helper script for generating links.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory = $true)]
        [AllowEmptyCollection()]
        [array]$Results,

        [Parameter(Mandatory = $true)]
        [string[]]$ScanRoots,

        [Parameter(Mandatory = $true)]
        [datetime]$StartTime,

        [Parameter(Mandatory = $true)]
        [datetime]$EndTime,

        [Parameter(Mandatory = $true)]
        [int]$ErrorCount,

        [Parameter(Mandatory = $true)]
        [string]$OutputPath,

        [Parameter(Mandatory = $true)]
        [string]$HelperScriptPath
    )

    $Duration = $EndTime - $StartTime
    $DurationString = "{0:hh\:mm\:ss\.fff}" -f $Duration
    $TotalSizeBytes = ($Results | Measure-Object -Property SizeBytes -Sum).Sum
    $TotalSizeMB = if ($TotalSizeBytes) { [math]::Round($TotalSizeBytes / 1MB, 2) } else { 0 }

    # Build table rows
    $TableRows = ""
    $RowNumber = 0
    foreach ($File in $Results) {
        $RowNumber++
        $RowClass = if ($RowNumber % 2 -eq 0) { "even" } else { "odd" }

        # Escape HTML characters
        $SafeFileName = [System.Web.HttpUtility]::HtmlEncode($File.FileName)
        $SafeFullPath = [System.Web.HttpUtility]::HtmlEncode($File.FullPath)
        $SafeParentFolder = [System.Web.HttpUtility]::HtmlEncode($File.ParentFolder)
        $FormattedDate = $File.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss")
        $FormattedSize = "{0:N0}" -f $File.SizeBytes

        # Create link that calls the helper script
        # Using file:// protocol with the helper CMD script
        $EscapedPath = $File.FullPath -replace '"', '\"'
        $HelperScriptName = Split-Path -Path $HelperScriptPath -Leaf

        $TableRows += @"

        <tr class="$RowClass">
            <td class="row-num">$RowNumber</td>
            <td>$SafeFileName</td>
            <td class="path-cell">
                <a href="file:///$($HelperScriptPath -replace '\\','/')?$($File.FullPath -replace '\\','/' -replace ' ','%20')" 
                   onclick="alert('To open in Notepad: Copy the path below and open manually, or run the helper script.\n\nPath: $($SafeFullPath -replace "'","\'")'); return false;"
                   title="Click for instructions to open in Notepad">$SafeFullPath</a>
                <button class="copy-btn" onclick="copyToClipboard('$($SafeFullPath -replace "'","\'")')">Copy</button>
            </td>
            <td>$SafeParentFolder</td>
            <td class="date-cell">$FormattedDate</td>
            <td class="size-cell">$FormattedSize</td>
        </tr>
"@
    }

    # Build scan roots list
    $ScanRootsList = ($ScanRoots | ForEach-Object { "<li>$([System.Web.HttpUtility]::HtmlEncode($_))</li>" }) -join "`n                    "

    $HtmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>VBS Scanner Report - $($StartTime.ToString("yyyy-MM-dd HH:mm:ss"))</title>
    <style>
        :root {
            --primary-color: #0078d4;
            --success-color: #107c10;
            --warning-color: #ffb900;
            --error-color: #d83b01;
            --bg-color: #f3f2f1;
            --card-bg: #ffffff;
            --text-color: #323130;
            --border-color: #e1dfdd;
        }

        * {
            box-sizing: border-box;
            margin: 0;
            padding: 0;
        }

        body {
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            background-color: var(--bg-color);
            color: var(--text-color);
            line-height: 1.5;
            padding: 20px;
        }

        .container {
            max-width: 1400px;
            margin: 0 auto;
        }

        header {
            background: linear-gradient(135deg, var(--primary-color), #106ebe);
            color: white;
            padding: 30px;
            border-radius: 8px;
            margin-bottom: 20px;
            box-shadow: 0 2px 8px rgba(0,0,0,0.15);
        }

        header h1 {
            font-size: 28px;
            font-weight: 600;
            margin-bottom: 10px;
        }

        header .subtitle {
            opacity: 0.9;
            font-size: 14px;
        }

        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(200px, 1fr));
            gap: 15px;
            margin-bottom: 20px;
        }

        .summary-card {
            background: var(--card-bg);
            border-radius: 8px;
            padding: 20px;
            box-shadow: 0 1px 4px rgba(0,0,0,0.1);
            border-left: 4px solid var(--primary-color);
        }

        .summary-card.success { border-left-color: var(--success-color); }
        .summary-card.warning { border-left-color: var(--warning-color); }
        .summary-card.error { border-left-color: var(--error-color); }

        .summary-card .label {
            font-size: 12px;
            text-transform: uppercase;
            letter-spacing: 0.5px;
            color: #605e5c;
            margin-bottom: 5px;
        }

        .summary-card .value {
            font-size: 24px;
            font-weight: 600;
        }

        .info-section {
            background: var(--card-bg);
            border-radius: 8px;
            padding: 20px;
            margin-bottom: 20px;
            box-shadow: 0 1px 4px rgba(0,0,0,0.1);
        }

        .info-section h2 {
            font-size: 18px;
            margin-bottom: 15px;
            color: var(--primary-color);
            border-bottom: 2px solid var(--primary-color);
            padding-bottom: 8px;
        }

        .info-section ul {
            list-style-type: none;
            padding-left: 0;
        }

        .info-section li {
            padding: 5px 0;
            padding-left: 20px;
            position: relative;
        }

        .info-section li::before {
            content: "▸";
            position: absolute;
            left: 0;
            color: var(--primary-color);
        }

        .instructions {
            background: #fff4ce;
            border: 1px solid var(--warning-color);
            border-radius: 8px;
            padding: 15px 20px;
            margin-bottom: 20px;
        }

        .instructions h3 {
            color: #8a6914;
            margin-bottom: 10px;
            font-size: 14px;
        }

        .instructions ol {
            margin-left: 20px;
            color: #665d1e;
            font-size: 13px;
        }

        .instructions code {
            background: rgba(0,0,0,0.1);
            padding: 2px 6px;
            border-radius: 3px;
            font-family: 'Consolas', monospace;
        }

        .results-section {
            background: var(--card-bg);
            border-radius: 8px;
            padding: 20px;
            box-shadow: 0 1px 4px rgba(0,0,0,0.1);
        }

        .results-section h2 {
            font-size: 18px;
            margin-bottom: 15px;
            color: var(--primary-color);
        }

        .table-container {
            overflow-x: auto;
        }

        table {
            width: 100%;
            border-collapse: collapse;
            font-size: 13px;
        }

        th {
            background: var(--primary-color);
            color: white;
            padding: 12px 10px;
            text-align: left;
            font-weight: 600;
            position: sticky;
            top: 0;
        }

        td {
            padding: 10px;
            border-bottom: 1px solid var(--border-color);
            vertical-align: middle;
        }

        tr.odd { background-color: #fafafa; }
        tr.even { background-color: #ffffff; }
        tr:hover { background-color: #e8f4ff; }

        .row-num {
            text-align: center;
            color: #605e5c;
            font-size: 12px;
            width: 50px;
        }

        .path-cell {
            max-width: 400px;
            word-break: break-all;
        }

        .path-cell a {
            color: var(--primary-color);
            text-decoration: none;
        }

        .path-cell a:hover {
            text-decoration: underline;
        }

        .copy-btn {
            margin-left: 8px;
            padding: 2px 8px;
            font-size: 11px;
            background: #f3f2f1;
            border: 1px solid #c8c6c4;
            border-radius: 3px;
            cursor: pointer;
        }

        .copy-btn:hover {
            background: #e1dfdd;
        }

        .date-cell {
            white-space: nowrap;
            font-family: 'Consolas', monospace;
            font-size: 12px;
        }

        .size-cell {
            text-align: right;
            font-family: 'Consolas', monospace;
            font-size: 12px;
        }

        footer {
            margin-top: 20px;
            text-align: center;
            color: #605e5c;
            font-size: 12px;
        }

        .no-results {
            text-align: center;
            padding: 40px;
            color: #605e5c;
            font-style: italic;
        }

        @media print {
            body { background: white; }
            header { background: var(--primary-color); }
            .copy-btn { display: none; }
        }
    </style>
    <script>
        function copyToClipboard(text) {
            if (navigator.clipboard && navigator.clipboard.writeText) {
                navigator.clipboard.writeText(text).then(function() {
                    showNotification('Path copied to clipboard!');
                }).catch(function() {
                    fallbackCopy(text);
                });
            } else {
                fallbackCopy(text);
            }
        }

        function fallbackCopy(text) {
            var textarea = document.createElement('textarea');
            textarea.value = text;
            textarea.style.position = 'fixed';
            textarea.style.opacity = '0';
            document.body.appendChild(textarea);
            textarea.select();
            try {
                document.execCommand('copy');
                showNotification('Path copied to clipboard!');
            } catch (err) {
                showNotification('Copy failed. Path: ' + text);
            }
            document.body.removeChild(textarea);
        }

        function showNotification(message) {
            var notification = document.createElement('div');
            notification.textContent = message;
            notification.style.cssText = 'position:fixed;bottom:20px;right:20px;background:#107c10;color:white;padding:12px 20px;border-radius:4px;box-shadow:0 2px 8px rgba(0,0,0,0.2);z-index:9999;font-size:14px;';
            document.body.appendChild(notification);
            setTimeout(function() {
                notification.style.transition = 'opacity 0.3s';
                notification.style.opacity = '0';
                setTimeout(function() { document.body.removeChild(notification); }, 300);
            }, 2000);
        }
    </script>
</head>
<body>
    <div class="container">
        <header>
            <h1>VBS Scanner Report</h1>
            <div class="subtitle">Generated: $($EndTime.ToString("yyyy-MM-dd HH:mm:ss")) | VBS Scanner Utility v$Script:ScriptVersion</div>
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

        <div class="info-section">
            <h2>Scan Configuration</h2>
            <ul>
                <li><strong>Scan Roots:</strong></li>
                <ul style="margin-left: 20px;">
                    $ScanRootsList
                </ul>
                <li><strong>Recursive:</strong> $Recurse</li>
                <li><strong>Max Depth:</strong> $(if ($MaxDepth) { $MaxDepth } else { 'Unlimited' })</li>
                <li><strong>Follow Reparse Points:</strong> $FollowReparsePoints</li>
                <li><strong>Excluded Paths:</strong> $(if ($ExcludePaths.Count -gt 0) { $ExcludePaths -join ', ' } else { 'None' })</li>
            </ul>
        </div>

        <div class="instructions">
            <h3>📝 How to Open Files in Notepad</h3>
            <ol>
                <li>Click the <strong>Copy</strong> button next to any file path to copy it to your clipboard.</li>
                <li>Open Notepad (press <code>Win+R</code>, type <code>notepad</code>, press Enter).</li>
                <li>Press <code>Ctrl+O</code> and paste the path (<code>Ctrl+V</code>).</li>
                <li>Alternatively, run the helper script: <code>$HelperScriptName "path\to\file.vbs"</code></li>
            </ol>
        </div>

        <div class="results-section">
            <h2>Discovered VBS Files ($($Results.Count))</h2>
            $(if ($Results.Count -eq 0) {
                '<div class="no-results">No .vbs files were found in the specified scan root(s).</div>'
            } else {
                @"
            <div class="table-container">
                <table>
                    <thead>
                        <tr>
                            <th>#</th>
                            <th>File Name</th>
                            <th>Full Path</th>
                            <th>Parent Folder</th>
                            <th>Last Modified</th>
                            <th>Size (Bytes)</th>
                        </tr>
                    </thead>
                    <tbody>$TableRows
                    </tbody>
                </table>
            </div>
"@
            })
        </div>

        <footer>
            <p>VBS Scanner Utility v$Script:ScriptVersion | Report generated by PowerShell $($PSVersionTable.PSVersion.ToString())</p>
            <p>Log file: $Script:LogFile</p>
        </footer>
    </div>
</body>
</html>
"@

    try {
        # Ensure System.Web assembly is loaded for HTML encoding
        Add-Type -AssemblyName System.Web -ErrorAction SilentlyContinue

        Set-Content -Path $OutputPath -Value $HtmlContent -Encoding UTF8 -Force -ErrorAction Stop
        Write-CMTraceLog -Message "HTML report created: $OutputPath" -Component "ConvertTo-HtmlReport"
        return $true
    }
    catch {
        Write-CMTraceLog -Message "Failed to create HTML report: $($_.Exception.Message)" -Severity 3 -Component "ConvertTo-HtmlReport"
        return $false
    }
}
#endregion

#region ===== MAIN EXECUTION =====
function Start-VbsScan {
    <#
    .SYNOPSIS
        Main entry point for the VBS scanning operation.

    .DESCRIPTION
        Orchestrates the scanning of all specified roots, generates reports,
        and handles all logging.
    #>
    [CmdletBinding()]
    param()

    # Ensure output folder exists
    if (-not (Test-Path -Path $OutputFolder -PathType Container)) {
        try {
            New-Item -Path $OutputFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
            Write-CMTraceLog -Message "Created output folder: $OutputFolder" -Component "Start-VbsScan"
        }
        catch {
            Write-Error "Failed to create output folder '$OutputFolder': $($_.Exception.Message)"
            return
        }
    }

    # Log start
    Write-CMTraceLog -Message "========== VBS Scanner Utility v$Script:ScriptVersion Started ==========" -Component "Start-VbsScan"
    Write-CMTraceLog -Message "PowerShell Version: $($PSVersionTable.PSVersion.ToString())" -Component "Start-VbsScan"
    Write-CMTraceLog -Message "Computer Name: $env:COMPUTERNAME" -Component "Start-VbsScan"
    Write-CMTraceLog -Message "User: $env:USERNAME" -Component "Start-VbsScan"

    # Log parameters
    Write-CMTraceLog -Message "Parameters - ScanRoots: $($ScanRoots -join '; ')" -Component "Start-VbsScan"
    Write-CMTraceLog -Message "Parameters - Recurse: $Recurse" -Component "Start-VbsScan"
    Write-CMTraceLog -Message "Parameters - ExcludePaths: $(if ($ExcludePaths.Count -gt 0) { $ExcludePaths -join '; ' } else { 'None' })" -Component "Start-VbsScan"
    Write-CMTraceLog -Message "Parameters - MaxDepth: $(if ($MaxDepth) { $MaxDepth } else { 'Unlimited' })" -Component "Start-VbsScan"
    Write-CMTraceLog -Message "Parameters - FollowReparsePoints: $FollowReparsePoints" -Component "Start-VbsScan"
    Write-CMTraceLog -Message "Parameters - OutputFolder: $OutputFolder" -Component "Start-VbsScan"

    # Create helper script
    $null = New-NotepadHelperScript -OutputPath $Script:HelperScriptFile

    # Process each scan root
    $AllResults = [System.Collections.ArrayList]::new()

    foreach ($Root in $ScanRoots) {
        Write-CMTraceLog -Message "Processing scan root: $Root" -Component "Start-VbsScan"
        Write-Host "Scanning: $Root" -ForegroundColor Cyan

        $RootResults = Get-VbsFiles -Path $Root -Recurse $Recurse -ExcludePaths $ExcludePaths -MaxDepth $MaxDepth -FollowReparsePoints $FollowReparsePoints

        foreach ($Result in $RootResults) {
            $null = $AllResults.Add($Result)
        }

        Write-CMTraceLog -Message "Scan root '$Root' complete - Found $($RootResults.Count) files" -Component "Start-VbsScan"
    }

    $Script:FilesFound = $AllResults.ToArray()
    $EndTime = Get-Date

    # Generate HTML report
    Write-CMTraceLog -Message "Generating HTML report..." -Component "Start-VbsScan"
    $ReportSuccess = ConvertTo-HtmlReport -Results $Script:FilesFound -ScanRoots $ScanRoots -StartTime $Script:StartTime -EndTime $EndTime -ErrorCount $Script:ErrorCount -OutputPath $Script:HtmlReportFile -HelperScriptPath $Script:HelperScriptFile

    # Log completion summary
    $Duration = $EndTime - $Script:StartTime
    Write-CMTraceLog -Message "========== Scan Complete ==========" -Component "Start-VbsScan"
    Write-CMTraceLog -Message "Total VBS files found: $($Script:FilesFound.Count)" -Component "Start-VbsScan"
    Write-CMTraceLog -Message "Total errors encountered: $Script:ErrorCount" -Component "Start-VbsScan"
    Write-CMTraceLog -Message "Duration: $($Duration.ToString('hh\:mm\:ss\.fff'))" -Component "Start-VbsScan"
    Write-CMTraceLog -Message "HTML Report: $Script:HtmlReportFile" -Component "Start-VbsScan"
    Write-CMTraceLog -Message "Log File: $Script:LogFile" -Component "Start-VbsScan"
    Write-CMTraceLog -Message "Helper Script: $Script:HelperScriptFile" -Component "Start-VbsScan"

    # Console output
    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor Green
    Write-Host "  VBS Scanner Utility - Scan Complete" -ForegroundColor Green
    Write-Host "=====================================================" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Files Found:    $($Script:FilesFound.Count)" -ForegroundColor White
    Write-Host "  Errors:         $Script:ErrorCount" -ForegroundColor $(if ($Script:ErrorCount -gt 0) { "Yellow" } else { "White" })
    Write-Host "  Duration:       $($Duration.ToString('hh\:mm\:ss\.fff'))" -ForegroundColor White
    Write-Host ""
    Write-Host "  Output Files:" -ForegroundColor Cyan
    Write-Host "    HTML Report:  $Script:HtmlReportFile" -ForegroundColor White
    Write-Host "    Log File:     $Script:LogFile" -ForegroundColor White
    Write-Host "    Helper:       $Script:HelperScriptFile" -ForegroundColor White
    Write-Host ""
    Write-Host "=====================================================" -ForegroundColor Green

    # Return output object for pipeline usage
    [PSCustomObject]@{
        FilesFound     = $Script:FilesFound.Count
        ErrorCount     = $Script:ErrorCount
        Duration       = $Duration
        HtmlReportPath = $Script:HtmlReportFile
        LogFilePath    = $Script:LogFile
        HelperScript   = $Script:HelperScriptFile
        Results        = $Script:FilesFound
    }
}

# Execute main function
Start-VbsScan
#endregion
