<#
.SYNOPSIS
    VBS Scanner Utility v3.0 - GUI-based tool for scanning .vbs files and MSI/MST VBScript indicators.

.DESCRIPTION
    A WinForms-based PowerShell 5.1 tool that:
    - Scans local devices (by name), UNC paths, or structured Archive roots for .vbs files
    - NEW: Scans MSI/MST files for VBScript usage patterns (CustomActions, ActiveSetup, Binary streams)
    - For Archive Root scans, extracts PackageName, Version, and Build from path structure
    - Shows live progress with responsive UI
    - Displays results in DataGridView with context menu actions
    - Generates HTML reports with embedded WebBrowser preview
    - Logs all activities using CMTRACE-compatible format

    Phase 3 Enhancement: MSI/MST VBScript Indicator Scanner
    - Detects VBScript CustomActions in MSI files
    - Identifies Active Setup patterns with cscript/wscript references
    - Optional deep Binary stream scanning for embedded scripts

.NOTES
    Author: Enterprise Endpoint Engineering
    Version: 3.1.0
    Requires: PowerShell 5.1, .NET Framework 4.5+
    Date: 2026-05-31

    v3.1.0 Performance Improvements:
    - Two-phase VBS scan: fast-path Get-ChildItem -Recurse for UNC (single network pass)
    - Removed per-file Write-CMTraceLog disk I/O from scan hot-path
    - Stopwatch-based UI timer replaces Get-Date in hot loops (lower overhead)
    - Generic.Queue[string] replaces non-generic Queue in both scan functions
    - Batch DataGrid population with SuspendLayout/ResumeLayout (no per-row repaint)
    - Result collections upgraded to Generic.List[object]
    - UI refresh interval increased from 100 ms to 400 ms
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
$Script:AppVersion = "3.1.0"
$Script:StartTime = Get-Date
$Script:Timestamp = $Script:StartTime.ToString("yyyyMMdd_HHmmss")
$Script:DefaultOutputFolder = [Environment]::GetFolderPath("MyDocuments")
$Script:LogFile = Join-Path -Path $Script:DefaultOutputFolder -ChildPath "VBSScanner_$($Script:Timestamp).log"
$Script:HtmlReportFile = ""
$Script:ScanResults = [System.Collections.Generic.List[object]]::new()
$Script:ErrorCount = 0
$Script:ScanCancelled = $false
$Script:IsScanning = $false
$Script:CurrentEntryType = "DeviceName"
$Script:ArchiveRoot = ""
$Script:CurrentScanMode = "VBSFileScan"  # VBSFileScan or MSIMSTScan

# MSI/MST Scan specific variables
$Script:MsiScanResults = [System.Collections.Generic.List[object]]::new()
$Script:MsiErrorCount = 0
$Script:MsiFilesScanned = 0
$Script:MsiFilesWithFindings = 0
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
            if ($CleanName -match '^[A-Za-z]:\\') {
                return $CleanName
            }
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
        $NormalizedRoot = $ArchiveRoot.TrimEnd('\', '/').ToLower()
        $NormalizedPath = $FullPath.ToLower()

        if (-not $NormalizedPath.StartsWith($NormalizedRoot)) {
            Write-CMTraceLog -Message "Path does not match archive root. Path: $FullPath | Root: $ArchiveRoot" -Severity 2 -Component "ArchiveMetadata"
            return $Result
        }

        $RelativePath = $FullPath.Substring($ArchiveRoot.Length).TrimStart('\', '/')
        $Segments = $RelativePath -split '[\\/]' | Where-Object { $_ -ne '' }

        if ($Segments.Count -ge 5) {
            $Result.PackageName = $Segments[1]
            $Result.Version = $Segments[2]
            $Result.Build = $Segments[4]
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

function Open-FileInExplorer {
    param([string]$FilePath)
    try {
        if (Test-Path -LiteralPath $FilePath -PathType Leaf) {
            Start-Process -FilePath "explorer.exe" -ArgumentList "/select,`"$FilePath`""
            Write-CMTraceLog -Message "Opened Explorer at: $FilePath" -Component "OpenExplorer"
        }
        else {
            $ParentFolder = Split-Path -Path $FilePath -Parent
            if (Test-Path -Path $ParentFolder) {
                Start-Process -FilePath "explorer.exe" -ArgumentList "`"$ParentFolder`""
            }
        }
    }
    catch {
        Write-CMTraceLog -Message "Error opening Explorer: $($_.Exception.Message)" -Severity 3 -Component "OpenExplorer"
    }
}
#endregion

#region ===== MSI/MST SCANNING FUNCTIONS =====
function New-MsiFinding {
    <#
    .SYNOPSIS
        Creates a new MSI finding object.
    #>
    param(
        [string]$InstallerPath,
        [string]$FileType,
        [string]$ProductName,
        [string]$ProductVersion,
        [string]$Manufacturer,
        [string]$ProductCode,
        [string]$FindingCategory,
        [string]$TableOrSource,
        [string]$ItemName,
        [string]$Evidence,
        [string]$Severity = "Info"
    )

    return [PSCustomObject]@{
        InstallerPath   = $InstallerPath
        FileType        = $FileType
        ProductName     = $ProductName
        ProductVersion  = $ProductVersion
        Manufacturer    = $Manufacturer
        ProductCode     = $ProductCode
        FindingCategory = $FindingCategory
        TableOrSource   = $TableOrSource
        ItemName        = $ItemName
        Evidence        = $Evidence
        Severity        = $Severity
    }
}

function Get-MsiProductInfo {
    <#
    .SYNOPSIS
        Extracts product information from MSI Property table.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Database,
        [string]$MsiPath
    )

    $ProductInfo = @{
        ProductName    = ""
        ProductVersion = ""
        Manufacturer   = ""
        ProductCode    = ""
    }

    try {
        $Query = "SELECT Property, Value FROM Property WHERE Property IN ('ProductName', 'ProductVersion', 'ProductCode', 'Manufacturer')"
        $View = $Database.OpenView($Query)
        $View.Execute()

        $Record = $View.Fetch()
        while ($null -ne $Record) {
            $PropName = $Record.StringData(1)
            $PropValue = $Record.StringData(2)

            switch ($PropName) {
                "ProductName"    { $ProductInfo.ProductName = $PropValue }
                "ProductVersion" { $ProductInfo.ProductVersion = $PropValue }
                "Manufacturer"   { $ProductInfo.Manufacturer = $PropValue }
                "ProductCode"    { $ProductInfo.ProductCode = $PropValue }
            }
            $Record = $View.Fetch()
        }
        $View.Close()
    }
    catch {
        Write-CMTraceLog -Message "Error reading Property table from $MsiPath - $($_.Exception.Message)" -Severity 2 -Component "MSIScan"
    }

    return $ProductInfo
}

function Find-VBScriptCustomActions {
    <#
    .SYNOPSIS
        Detects VBScript-related custom actions in MSI CustomAction table.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Database,
        [string]$MsiPath,
        [hashtable]$ProductInfo
    )

    $Findings = [System.Collections.ArrayList]::new()

    # VBScript CA types:
    # Type 6 = VBScript stored in Binary table
    # Type 38 = VBScript stored in Binary table (deferred)
    # Type 22 = VBScript stored in Binary table (commit)
    # Type 54 = VBScript stored in Binary table (rollback)
    # Type 37, 53 = JScript variations
    $VBScriptTypes = @(6, 22, 38, 54)
    $ScriptIndicators = @("cscript", "wscript", ".vbs", "vbscript", "script.exe")

    try {
        Write-CMTraceLog -Message "Querying CustomAction table in $MsiPath" -Component "MSIScan"
        $Query = "SELECT Action, Type, Source, Target FROM CustomAction"
        $View = $Database.OpenView($Query)
        $View.Execute()

        $Record = $View.Fetch()
        while ($null -ne $Record) {
            $ActionName = $Record.StringData(1)
            $ActionType = $Record.IntegerData(2)
            $Source = $Record.StringData(3)
            $Target = $Record.StringData(4)

            # Check for VBScript type custom actions
            $BaseType = $ActionType -band 63  # Mask to get base type
            if ($VBScriptTypes -contains $BaseType) {
                $Finding = New-MsiFinding -InstallerPath $MsiPath `
                    -FileType "MSI" `
                    -ProductName $ProductInfo.ProductName `
                    -ProductVersion $ProductInfo.ProductVersion `
                    -Manufacturer $ProductInfo.Manufacturer `
                    -ProductCode $ProductInfo.ProductCode `
                    -FindingCategory "VBScriptCustomAction" `
                    -TableOrSource "CustomAction" `
                    -ItemName $ActionName `
                    -Evidence "Type=$ActionType (VBS), Source=$Source" `
                    -Severity "High"
                $null = $Findings.Add($Finding)
                Write-CMTraceLog -Message "Found VBScript CA: $ActionName (Type $ActionType)" -Component "MSIScan"
            }

            # Check Target field for script host invocations
            if ($Target) {
                $TargetLower = $Target.ToLower()
                foreach ($Indicator in $ScriptIndicators) {
                    if ($TargetLower -contains $Indicator) {
                        $Evidence = if ($Target.Length -gt 100) { $Target.Substring(0, 100) + "..." } else { $Target }
                        $Finding = New-MsiFinding -InstallerPath $MsiPath `
                            -FileType "MSI" `
                            -ProductName $ProductInfo.ProductName `
                            -ProductVersion $ProductInfo.ProductVersion `
                            -Manufacturer $ProductInfo.Manufacturer `
                            -ProductCode $ProductInfo.ProductCode `
                            -FindingCategory "ScriptHostInvocation" `
                            -TableOrSource "CustomAction" `
                            -ItemName $ActionName `
                            -Evidence "Target contains '$Indicator': $Evidence" `
                            -Severity "Warning"
                        $null = $Findings.Add($Finding)
                        Write-CMTraceLog -Message "Found script invocation in CA target: $ActionName - $Indicator" -Component "MSIScan"
                        break
                    }
                }
            }

            $Record = $View.Fetch()
        }
        $View.Close()
    }
    catch {
        Write-CMTraceLog -Message "Error querying CustomAction table: $($_.Exception.Message)" -Severity 2 -Component "MSIScan"
    }

    return $Findings
}

function Find-ActiveSetupIndicators {
    <#
    .SYNOPSIS
        Detects Active Setup registry entries that may invoke scripts.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Database,
        [string]$MsiPath,
        [hashtable]$ProductInfo
    )

    $Findings = [System.Collections.ArrayList]::new()
    $ActiveSetupPattern = "Active Setup\\Installed Components"
    $ScriptIndicators = @("cscript", "wscript", ".vbs", "script")

    try {
        Write-CMTraceLog -Message "Querying Registry table for Active Setup in $MsiPath" -Component "MSIScan"
        $Query = "SELECT Registry, Root, Key, Name, Value FROM Registry"
        $View = $Database.OpenView($Query)
        $View.Execute()

        $Record = $View.Fetch()
        while ($null -ne $Record) {
            $RegistryKey = $Record.StringData(1)
            $Root = $Record.IntegerData(2)
            $Key = $Record.StringData(3)
            $Name = $Record.StringData(4)
            $Value = $Record.StringData(5)

            # Check if this is an Active Setup key
            if ($Key -and $Key -like "*$ActiveSetupPattern*") {
                # Check StubPath or other values for script indicators
                if ($Name -ieq "StubPath" -or $Value) {
                    $ValueCheck = if ($Value) { $Value.ToLower() } else { "" }
                    $FoundIndicator = $false

                    foreach ($Indicator in $ScriptIndicators) {
                        if ($ValueCheck -contains $Indicator) {
                            $FoundIndicator = $true
                            $Evidence = "Key=$Key, Name=$Name, Value=$Value"
                            if ($Evidence.Length -gt 150) { $Evidence = $Evidence.Substring(0, 150) + "..." }

                            $Finding = New-MsiFinding -InstallerPath $MsiPath `
                                -FileType "MSI" `
                                -ProductName $ProductInfo.ProductName `
                                -ProductVersion $ProductInfo.ProductVersion `
                                -Manufacturer $ProductInfo.Manufacturer `
                                -ProductCode $ProductInfo.ProductCode `
                                -FindingCategory "ActiveSetupStubPath" `
                                -TableOrSource "Registry" `
                                -ItemName "$Name in $RegistryKey" `
                                -Evidence $Evidence `
                                -Severity "High"
                            $null = $Findings.Add($Finding)
                            Write-CMTraceLog -Message "Found Active Setup script indicator: $Name = $Indicator" -Component "MSIScan"
                            break
                        }
                    }

                    # Also flag Active Setup entries even without script indicators (for awareness)
                    if (-not $FoundIndicator -and $Name -ieq "StubPath") {
                        $Evidence = "StubPath=$Value"
                        if ($Evidence.Length -gt 150) { $Evidence = $Evidence.Substring(0, 150) + "..." }

                        $Finding = New-MsiFinding -InstallerPath $MsiPath `
                            -FileType "MSI" `
                            -ProductName $ProductInfo.ProductName `
                            -ProductVersion $ProductInfo.ProductVersion `
                            -Manufacturer $ProductInfo.Manufacturer `
                            -ProductCode $ProductInfo.ProductCode `
                            -FindingCategory "ActiveSetupStubPath" `
                            -TableOrSource "Registry" `
                            -ItemName "$Name in $RegistryKey" `
                            -Evidence $Evidence `
                            -Severity "Info"
                        $null = $Findings.Add($Finding)
                    }
                }
            }

            $Record = $View.Fetch()
        }
        $View.Close()
    }
    catch {
        Write-CMTraceLog -Message "Error querying Registry table: $($_.Exception.Message)" -Severity 2 -Component "MSIScan"
    }

    return $Findings
}

function Find-BinaryScriptContent {
    <#
    .SYNOPSIS
        Deep scans Binary table streams for VBScript content markers.
    #>
    param(
        [Parameter(Mandatory = $true)]
        $Database,
        [string]$MsiPath,
        [hashtable]$ProductInfo
    )

    $Findings = [System.Collections.ArrayList]::new()
    $VBScriptMarkers = @(
        "WScript.",
        "CreateObject(",
        "Scripting.FileSystemObject",
        "On Error Resume Next",
        "WScript.Shell",
        "WScript.Network",
        "ADODB.Connection",
        "Scripting.Dictionary"
    )

    try {
        Write-CMTraceLog -Message "Deep scanning Binary table in $MsiPath" -Component "MSIScan"
        $Query = "SELECT Name, Data FROM Binary"
        $View = $Database.OpenView($Query)
        $View.Execute()

        $TempFolder = [System.IO.Path]::GetTempPath()

        $Record = $View.Fetch()
        while ($null -ne $Record) {
            $BinaryName = $Record.StringData(1)
            $TempFile = Join-Path -Path $TempFolder -ChildPath "msi_binary_$([Guid]::NewGuid().ToString('N')).tmp"

            try {
                # Extract binary stream to temp file
                $Record.SetStream(2, $TempFile)

                # Read and scan for markers
                if (Test-Path -Path $TempFile) {
                    $Content = ""
                    try {
                        # Try to read as text (may fail for binary data)
                        $Bytes = [System.IO.File]::ReadAllBytes($TempFile)
                        if ($Bytes.Length -lt 1MB) {  # Only scan files under 1MB
                            # Try UTF8, then ASCII
                            try {
                                $Content = [System.Text.Encoding]::UTF8.GetString($Bytes)
                            }
                            catch {
                                $Content = [System.Text.Encoding]::ASCII.GetString($Bytes)
                            }

                            foreach ($Marker in $VBScriptMarkers) {
                                if ($Content -like "*$Marker*") {
                                    # Extract snippet around the marker
                                    $Index = $Content.IndexOf($Marker, [StringComparison]::OrdinalIgnoreCase)
                                    $Start = [Math]::Max(0, $Index - 20)
                                    $Length = [Math]::Min(80, $Content.Length - $Start)
                                    $Snippet = $Content.Substring($Start, $Length) -replace '[\r\n\t]', ' '
                                    if ($Snippet.Length -gt 80) { $Snippet = $Snippet.Substring(0, 80) + "..." }

                                    $Finding = New-MsiFinding -InstallerPath $MsiPath `
                                        -FileType "MSI" `
                                        -ProductName $ProductInfo.ProductName `
                                        -ProductVersion $ProductInfo.ProductVersion `
                                        -Manufacturer $ProductInfo.Manufacturer `
                                        -ProductCode $ProductInfo.ProductCode `
                                        -FindingCategory "EmbeddedScriptText" `
                                        -TableOrSource "Binary" `
                                        -ItemName $BinaryName `
                                        -Evidence "Contains '$Marker': $Snippet" `
                                        -Severity "Warning"
                                    $null = $Findings.Add($Finding)
                                    Write-CMTraceLog -Message "Found embedded script marker in Binary '$BinaryName': $Marker" -Component "MSIScan"
                                    break  # Only report first marker per binary
                                }
                            }
                        }
                    }
                    catch {
                        # Binary data that can't be decoded as text - skip silently
                    }
                }
            }
            catch {
                Write-CMTraceLog -Message "Error extracting Binary '$BinaryName': $($_.Exception.Message)" -Severity 2 -Component "MSIScan"
            }
            finally {
                if (Test-Path -Path $TempFile) {
                    Remove-Item -Path $TempFile -Force -ErrorAction SilentlyContinue
                }
            }

            $Record = $View.Fetch()
        }
        $View.Close()
    }
    catch {
        Write-CMTraceLog -Message "Error querying Binary table: $($_.Exception.Message)" -Severity 2 -Component "MSIScan"
    }

    return $Findings
}

function Scan-MsiFile {
    <#
    .SYNOPSIS
        Scans a single MSI file for VBScript indicators.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$MsiPath,
        [bool]$DeepScanBinary = $false,
        [bool]$DetectActiveSetup = $true
    )

    $Findings = [System.Collections.ArrayList]::new()

    Write-CMTraceLog -Message "Opening MSI for scanning: $MsiPath" -Component "MSIScan"

    $Installer = $null
    $Database = $null

    try {
        # Create Windows Installer COM object
        $Installer = New-Object -ComObject WindowsInstaller.Installer

        # Open database read-only (mode 0)
        $Database = $Installer.OpenDatabase($MsiPath, 0)

        # Get product information
        $ProductInfo = Get-MsiProductInfo -Database $Database -MsiPath $MsiPath
        Write-CMTraceLog -Message "MSI Product: $($ProductInfo.ProductName) v$($ProductInfo.ProductVersion)" -Component "MSIScan"

        # Find VBScript custom actions
        $CAFindings = Find-VBScriptCustomActions -Database $Database -MsiPath $MsiPath -ProductInfo $ProductInfo
        foreach ($F in $CAFindings) { $null = $Findings.Add($F) }

        # Find Active Setup indicators
        if ($DetectActiveSetup) {
            $ASFindings = Find-ActiveSetupIndicators -Database $Database -MsiPath $MsiPath -ProductInfo $ProductInfo
            foreach ($F in $ASFindings) { $null = $Findings.Add($F) }
        }

        # Deep scan Binary table
        if ($DeepScanBinary) {
            $BinaryFindings = Find-BinaryScriptContent -Database $Database -MsiPath $MsiPath -ProductInfo $ProductInfo
            foreach ($F in $BinaryFindings) { $null = $Findings.Add($F) }
        }
    }
    catch {
        Write-CMTraceLog -Message "Error scanning MSI $MsiPath - $($_.Exception.Message)" -Severity 3 -Component "MSIScan"
        $Script:MsiErrorCount++
    }
    finally {
        # Release COM objects
        if ($null -ne $Database) {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($Database) | Out-Null
        }
        if ($null -ne $Installer) {
            [System.Runtime.InteropServices.Marshal]::ReleaseComObject($Installer) | Out-Null
        }
        [System.GC]::Collect()
        [System.GC]::WaitForPendingFinalizers()
    }

    return $Findings
}

function Scan-MstFile {
    <#
    .SYNOPSIS
        Scans an MST (transform) file for VBScript indicator strings.
        MST files are binary and cannot be fully parsed without applying to an MSI,
        so we do a simple string search.
    #>
    param(
        [Parameter(Mandatory = $true)]
        [string]$MstPath
    )

    $Findings = [System.Collections.ArrayList]::new()
    $Indicators = @("cscript", "wscript", ".vbs", "Active Setup", "StubPath", "WScript.", "CreateObject", "vbscript")

    Write-CMTraceLog -Message "Scanning MST file: $MstPath" -Component "MSIScan"

    try {
        $Bytes = [System.IO.File]::ReadAllBytes($MstPath)
        if ($Bytes.Length -lt 10MB) {  # Only scan files under 10MB
            # Try to extract readable strings
            $Content = ""
            try {
                $Content = [System.Text.Encoding]::Unicode.GetString($Bytes)
            }
            catch {
                try {
                    $Content = [System.Text.Encoding]::ASCII.GetString($Bytes)
                }
                catch {
                    $Content = ""
                }
            }

            if ($Content) {
                foreach ($Indicator in $Indicators) {
                    if ($Content -like "*$Indicator*") {
                        $Finding = New-MsiFinding -InstallerPath $MstPath `
                            -FileType "MST" `
                            -ProductName "(Transform)" `
                            -ProductVersion "" `
                            -Manufacturer "" `
                            -ProductCode "" `
                            -FindingCategory "TransformStringIndicator" `
                            -TableOrSource "FileContent" `
                            -ItemName "String Match" `
                            -Evidence "Contains string: '$Indicator'" `
                            -Severity "Info"
                        $null = $Findings.Add($Finding)
                        Write-CMTraceLog -Message "Found indicator in MST: $Indicator" -Component "MSIScan"
                    }
                }
            }
        }
        else {
            Write-CMTraceLog -Message "MST file too large for string scanning: $MstPath" -Severity 2 -Component "MSIScan"
        }
    }
    catch {
        Write-CMTraceLog -Message "Error scanning MST $MstPath - $($_.Exception.Message)" -Severity 3 -Component "MSIScan"
        $Script:MsiErrorCount++
    }

    return $Findings
}

function Start-MsiMstScan {
    <#
    .SYNOPSIS
        Main MSI/MST scanning function that enumerates and scans installer files.
    #>
    param(
        [string]$ScanRoot,
        [bool]$Recurse = $true,
        [string[]]$ExcludePaths = @(),
        [bool]$ScanMsi = $true,
        [bool]$ScanMst = $true,
        [bool]$DeepScanBinary = $false,
        [bool]$DetectActiveSetup = $true,
        [string]$ExtensionFilter = ".msi;.mst",
        [System.Windows.Forms.ProgressBar]$ProgressBar,
        [System.Windows.Forms.Label]$StatusLabel,
        [System.Windows.Forms.DataGridView]$DataGrid,
        [System.Windows.Forms.Form]$ParentForm
    )

    $Script:MsiScanResults.Clear()
    $Script:MsiErrorCount = 0
    $Script:MsiFilesScanned = 0
    $Script:MsiFilesWithFindings = 0
    $Script:ScanCancelled = $false
    $DataGrid.Rows.Clear()

    $Extensions = @()
    if ($ScanMsi) { $Extensions += ".msi" }
    if ($ScanMst) { $Extensions += ".mst" }

    if ($Extensions.Count -eq 0) {
        $StatusLabel.Text = "No file types selected for scanning"
        return $false
    }

    # Validate root path
    if (-not (Test-PathAccessible -Path $ScanRoot)) {
        Write-CMTraceLog -Message "Cannot access scan root: $ScanRoot" -Severity 3 -Component "MSIScan"
        $StatusLabel.Text = "Error: Cannot access $ScanRoot"
        $StatusLabel.ForeColor = [System.Drawing.Color]::Red
        return $false
    }

    Write-CMTraceLog -Message "Starting MSI/MST scan - Root: $ScanRoot | Recurse: $Recurse | Extensions: $($Extensions -join ',')" -Component "MSIScan"
    Write-CMTraceLog -Message "Options - ScanMsi: $ScanMsi | ScanMst: $ScanMst | DeepBinary: $DeepScanBinary | ActiveSetup: $DetectActiveSetup" -Component "MSIScan"

    $ProgressBar.Style = "Marquee"
    $ProgressBar.MarqueeAnimationSpeed = 30

    $DirsToProcess = [System.Collections.Generic.Queue[string]]::new()
    $DirsToProcess.Enqueue($ScanRoot)
    $DirCount = 0
    $FileCount = 0
    $UITimer   = [System.Diagnostics.Stopwatch]::StartNew()
    $ScanTimer = [System.Diagnostics.Stopwatch]::StartNew()

    while ($DirsToProcess.Count -gt 0) {
        if ($Script:ScanCancelled) {
            Write-CMTraceLog -Message "MSI/MST scan cancelled by user" -Severity 2 -Component "MSIScan"
            $StatusLabel.Text = "Scan cancelled"
            $StatusLabel.ForeColor = [System.Drawing.Color]::Orange
            $ProgressBar.Style = "Continuous"
            return $false
        }

        $CurrentPath = $DirsToProcess.Dequeue()
        $DirCount++

        if (Test-PathExcluded -Path $CurrentPath -ExcludePaths $ExcludePaths) {
            continue
        }

        # Update UI periodically (Stopwatch avoids Get-Date COM overhead in hot loop)
        if ($UITimer.ElapsedMilliseconds -ge 400) {
            $ShortPath = if ($CurrentPath.Length -gt 50) { "..." + $CurrentPath.Substring($CurrentPath.Length - 47) } else { $CurrentPath }
            $StatusLabel.Text = "MSI: $($Script:MsiFilesScanned) | Findings: $($Script:MsiScanResults.Count) | $ShortPath"
            [System.Windows.Forms.Application]::DoEvents()
            $UITimer.Restart()
        }

        try {
            $Items = Get-ChildItem -LiteralPath $CurrentPath -Force -ErrorAction Stop

            foreach ($Item in $Items) {
                if ($Script:ScanCancelled) { break }

                if ($Item.PSIsContainer) {
                    if ($Recurse -and -not ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                        $DirsToProcess.Enqueue($Item.FullName)
                    }
                }
                else {
                    $ExtLower = $Item.Extension.ToLower()
                    if ($Extensions -contains $ExtLower) {
                        $FileCount++
                        $Script:MsiFilesScanned++

                        $Findings = @()
                        if ($ExtLower -eq ".msi") {
                            $Findings = Scan-MsiFile -MsiPath $Item.FullName -DeepScanBinary $DeepScanBinary -DetectActiveSetup $DetectActiveSetup
                        }
                        elseif ($ExtLower -eq ".mst") {
                            $Findings = Scan-MstFile -MstPath $Item.FullName
                        }

                        if ($Findings.Count -gt 0) {
                            $Script:MsiFilesWithFindings++
                            foreach ($Finding in $Findings) {
                                $null = $Script:MsiScanResults.Add($Finding)
                            }
                        }
                    }
                }
            }
        }
        catch [System.UnauthorizedAccessException] {
            $Script:MsiErrorCount++
            Write-CMTraceLog -Message "Access denied: $CurrentPath" -Severity 3 -Component "MSIScan"
        }
        catch {
            $Script:MsiErrorCount++
            Write-CMTraceLog -Message "Error scanning $CurrentPath - $($_.Exception.Message)" -Severity 3 -Component "MSIScan"
        }
    }

    # Batch-populate DataGrid after scan (avoids per-row repaint during traversal)
    $StatusLabel.Text = "Populating results grid ($($Script:MsiScanResults.Count) findings)..."
    [System.Windows.Forms.Application]::DoEvents()
    $DataGrid.SuspendLayout()
    try {
        foreach ($Finding in $Script:MsiScanResults) {
            if ([string]::IsNullOrWhiteSpace($Finding.InstallerPath)) { continue }
            $SeverityColor = switch ($Finding.Severity) {
                "High"    { [System.Drawing.Color]::Red }
                "Warning" { [System.Drawing.Color]::DarkOrange }
                default   { [System.Drawing.Color]::Black }
            }
            $RowIndex = $DataGrid.Rows.Add(
                $Finding.InstallerPath,
                $Finding.FileType,
                $Finding.ProductName,
                $Finding.ProductVersion,
                $Finding.Manufacturer,
                $Finding.FindingCategory,
                $Finding.TableOrSource,
                $Finding.ItemName,
                $Finding.Evidence,
                $Finding.Severity
            )
            $DataGrid.Rows[$RowIndex].Cells["Severity"].Style.ForeColor = $SeverityColor
        }
    }
    finally {
        $DataGrid.ResumeLayout($true)
    }

    $ScanTimer.Stop()
    $ProgressBar.Style = "Continuous"
    $ProgressBar.Value = 100

    Write-CMTraceLog -Message "MSI/MST scan complete. Scanned: $($Script:MsiFilesScanned) files, Findings: $($Script:MsiScanResults.Count), Errors: $($Script:MsiErrorCount) | Elapsed: $([Math]::Round($ScanTimer.Elapsed.TotalSeconds,2))s" -Component "MSIScan"
    return $true
}
#endregion

#region ===== HTML REPORT GENERATION =====
function New-HtmlReport {
    <#
    .SYNOPSIS
        Generates an HTML report for VBS file scan results.
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

    # Build table rows
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
        .summary-card.warning { border-left-color: var(--warning); }
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
        .severity-high { color: #d83b01; font-weight: bold; }
        .severity-warning { color: #ffb900; font-weight: bold; }
        .severity-info { color: #107c10; }
        footer { margin-top: 15px; text-align: center; color: #605e5c; font-size: 11px; }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>VBS File Scan Report $(if ($EntryType -eq 'ArchiveRoot') { '<span class="archive-badge">Archive Scan</span>' })</h1>
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
            <p><strong>Scan Mode:</strong> VBS File Scan</p>
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

function New-MsiHtmlReport {
    <#
    .SYNOPSIS
        Generates an HTML report for MSI/MST scan findings.
    #>
    param(
        [array]$Findings,
        [string]$ScanRoot,
        [datetime]$StartTime,
        [datetime]$EndTime,
        [int]$ErrorCount,
        [int]$FilesScanned,
        [int]$FilesWithFindings,
        [string]$OutputPath
    )

    $Duration = $EndTime - $StartTime
    $DurationString = "{0:hh\:mm\:ss\.fff}" -f $Duration

    # Count by category
    $CategoryCounts = $Findings | Group-Object -Property FindingCategory | Sort-Object Count -Descending

    $CategorySummaryHtml = ""
    if ($CategoryCounts.Count -gt 0) {
        $CategoryRows = ""
        foreach ($Cat in $CategoryCounts) {
            $CategoryRows += "<tr><td>$([System.Web.HttpUtility]::HtmlEncode($Cat.Name))</td><td class='size-cell'>$($Cat.Count)</td></tr>"
        }
        $CategorySummaryHtml = @"
        <div class="info-box">
            <h2>Findings by Category</h2>
            <table style="width: auto; min-width: 300px;">
                <thead><tr><th>Category</th><th>Count</th></tr></thead>
                <tbody>$CategoryRows</tbody>
            </table>
        </div>
"@
    }

    # Count by severity
    $HighCount = ($Findings | Where-Object { $_.Severity -eq "High" }).Count
    $WarningCount = ($Findings | Where-Object { $_.Severity -eq "Warning" }).Count
    $InfoCount = ($Findings | Where-Object { $_.Severity -eq "Info" }).Count

    # Build table rows
    $TableRows = ""
    $RowNumber = 0
    foreach ($Finding in $Findings) {
        $RowNumber++
        $RowClass = if ($RowNumber % 2 -eq 0) { "even" } else { "odd" }

        $SafePath = [System.Web.HttpUtility]::HtmlEncode($Finding.InstallerPath)
        $SafeProductName = [System.Web.HttpUtility]::HtmlEncode($Finding.ProductName)
        $SafeManufacturer = [System.Web.HttpUtility]::HtmlEncode($Finding.Manufacturer)
        $SafeCategory = [System.Web.HttpUtility]::HtmlEncode($Finding.FindingCategory)
        $SafeTableSource = [System.Web.HttpUtility]::HtmlEncode($Finding.TableOrSource)
        $SafeItemName = [System.Web.HttpUtility]::HtmlEncode($Finding.ItemName)
        $SafeEvidence = [System.Web.HttpUtility]::HtmlEncode($Finding.Evidence)

        $SeverityClass = switch ($Finding.Severity) {
            "High" { "severity-high" }
            "Warning" { "severity-warning" }
            default { "severity-info" }
        }

        # Create explorer link (select file, don't execute)
        $ExplorerUri = "explorer:/select/$($Finding.InstallerPath -replace '\\', '/')"

        $TableRows += @"

        <tr class="$RowClass">
            <td class="row-num">$RowNumber</td>
            <td class="path-cell"><a href="$ExplorerUri" title="Open in Explorer">$SafePath</a></td>
            <td>$($Finding.FileType)</td>
            <td>$SafeProductName</td>
            <td>$($Finding.ProductVersion)</td>
            <td>$SafeManufacturer</td>
            <td>$SafeCategory</td>
            <td>$SafeTableSource</td>
            <td>$SafeItemName</td>
            <td style="max-width:200px; word-break:break-all;">$SafeEvidence</td>
            <td class="$SeverityClass">$($Finding.Severity)</td>
        </tr>
"@
    }

    $HtmlContent = @"
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>MSI/MST VBScript Indicator Report</title>
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
        .container { max-width: 1600px; margin: 0 auto; }
        header {
            background: linear-gradient(135deg, #8b0000, #dc143c);
            color: white;
            padding: 20px;
            border-radius: 6px;
            margin-bottom: 15px;
        }
        header h1 { font-size: 22px; margin-bottom: 5px; }
        header .subtitle { opacity: 0.9; font-size: 12px; }
        .summary-grid {
            display: grid;
            grid-template-columns: repeat(auto-fit, minmax(140px, 1fr));
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
        .summary-card.warning { border-left-color: var(--warning); }
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
        table { width: 100%; border-collapse: collapse; font-size: 11px; }
        th {
            background: #8b0000;
            color: white;
            padding: 10px 6px;
            text-align: left;
            font-weight: 600;
            white-space: nowrap;
        }
        td { padding: 6px; border-bottom: 1px solid var(--border); vertical-align: top; }
        tr.odd { background: #fafafa; }
        tr.even { background: #ffffff; }
        tr:hover { background: #ffe8e8; }
        .row-num { text-align: center; color: #605e5c; width: 35px; }
        .path-cell { max-width: 250px; word-break: break-all; }
        .path-cell a { color: var(--primary); text-decoration: none; }
        .path-cell a:hover { text-decoration: underline; cursor: pointer; }
        .no-results { text-align: center; padding: 30px; color: #605e5c; font-style: italic; }
        .severity-high { color: #d83b01; font-weight: bold; }
        .severity-warning { color: #c87000; font-weight: bold; }
        .severity-info { color: #107c10; }
        .msi-badge { background: #8b0000; color: white; padding: 2px 8px; border-radius: 4px; font-size: 11px; margin-left: 8px; }
        footer { margin-top: 15px; text-align: center; color: #605e5c; font-size: 11px; }
    </style>
</head>
<body>
    <div class="container">
        <header>
            <h1>MSI/MST VBScript Indicator Report <span class="msi-badge">Installer Scan</span></h1>
            <div class="subtitle">Generated: $($EndTime.ToString("yyyy-MM-dd HH:mm:ss")) | VBS Scanner Utility v$Script:AppVersion</div>
        </header>

        <div class="summary-grid">
            <div class="summary-card">
                <div class="label">Files Scanned</div>
                <div class="value">$FilesScanned</div>
            </div>
            <div class="summary-card $(if ($FilesWithFindings -gt 0) { 'warning' } else { 'success' })">
                <div class="label">With Findings</div>
                <div class="value">$FilesWithFindings</div>
            </div>
            <div class="summary-card">
                <div class="label">Total Findings</div>
                <div class="value">$($Findings.Count)</div>
            </div>
            <div class="summary-card error">
                <div class="label">High Severity</div>
                <div class="value">$HighCount</div>
            </div>
            <div class="summary-card warning">
                <div class="label">Warnings</div>
                <div class="value">$WarningCount</div>
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
            <p><strong>Scan Mode:</strong> MSI/MST VBScript Indicator Scan</p>
            <p><strong>Scan Root:</strong> $([System.Web.HttpUtility]::HtmlEncode($ScanRoot))</p>
            <p><strong>Start Time:</strong> $($StartTime.ToString("yyyy-MM-dd HH:mm:ss"))</p>
            <p><strong>End Time:</strong> $($EndTime.ToString("yyyy-MM-dd HH:mm:ss"))</p>
        </div>

        $CategorySummaryHtml

        <div class="results-box">
            <h2>MSI/MST Findings ($($Findings.Count))</h2>
            $(if ($Findings.Count -eq 0) {
                '<div class="no-results">No VBScript indicators were found in the scanned installers.</div>'
            } else {
                @"
            <table>
                <thead>
                    <tr>
                        <th>#</th>
                        <th>Installer Path</th>
                        <th>Type</th>
                        <th>Product Name</th>
                        <th>Version</th>
                        <th>Vendor</th>
                        <th>Category</th>
                        <th>Table/Source</th>
                        <th>Item Name</th>
                        <th>Evidence</th>
                        <th>Severity</th>
                    </tr>
                </thead>
                <tbody>$TableRows
                </tbody>
            </table>
"@
            })
        </div>

        <footer>
            <p>VBS Scanner Utility v$Script:AppVersion | MSI/MST VBScript Indicator Scanner | PowerShell $($PSVersionTable.PSVersion.ToString())</p>
        </footer>
    </div>
</body>
</html>
"@

    try {
        Set-Content -Path $OutputPath -Value $HtmlContent -Encoding UTF8 -Force -ErrorAction Stop
        Write-CMTraceLog -Message "MSI HTML report created: $OutputPath" -Component "MsiHtmlReport"
        return $true
    }
    catch {
        Write-CMTraceLog -Message "Failed to create MSI HTML report: $($_.Exception.Message)" -Severity 3 -Component "MsiHtmlReport"
        return $false
    }
}
#endregion

#region ===== VBS SCAN FUNCTION =====
function Start-VbsScan {
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

    if (-not (Test-PathAccessible -Path $ScanRoot)) {
        Write-CMTraceLog -Message "Cannot access scan root: $ScanRoot" -Severity 3 -Component "Scan"
        $StatusLabel.Text = "Error: Cannot access $ScanRoot"
        $StatusLabel.ForeColor = [System.Drawing.Color]::Red
        return $false
    }

    Write-CMTraceLog -Message "Starting VBS scan - EntryType: $EntryType | Root: $ScanRoot | Recurse: $Recurse" -Component "Scan"

    $ProgressBar.Style = "Marquee"
    $ProgressBar.MarqueeAnimationSpeed = 30

    $ScanTimer = [System.Diagnostics.Stopwatch]::StartNew()
    $UITimer   = [System.Diagnostics.Stopwatch]::StartNew()

    # -----------------------------------------------------------------------
    # Phase 1: Enumerate .vbs files
    #   Fast path  (no exclusions + recurse): single Get-ChildItem -Recurse
    #     -> one network traversal for UNC instead of one round-trip per dir
    #   Exclusion path: Generic.Queue-based manual traversal to skip dirs
    # -----------------------------------------------------------------------
    $AllFiles = [System.Collections.Generic.List[System.IO.FileInfo]]::new()

    $StatusLabel.Text = "Enumerating .vbs files..."
    [System.Windows.Forms.Application]::DoEvents()

    $HasExclusions = ($null -ne $ExcludePaths -and
                      ($ExcludePaths | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }).Count -gt 0)

    if (-not $HasExclusions -and $Recurse) {
        # Fast path: single recursive call - most efficient for UNC paths
        try {
            Get-ChildItem -LiteralPath $ScanRoot -Filter "*.vbs" -Recurse -Force -File -ErrorAction SilentlyContinue |
                ForEach-Object { $AllFiles.Add($_) }
        }
        catch {
            $Script:ErrorCount++
            Write-CMTraceLog -Message "Enumeration error: $($_.Exception.Message)" -Severity 3 -Component "Scan"
        }
    }
    else {
        # Exclusion / no-recurse path: manual directory queue
        $DirQueue = [System.Collections.Generic.Queue[string]]::new()
        $DirQueue.Enqueue($ScanRoot)

        while ($DirQueue.Count -gt 0) {
            if ($Script:ScanCancelled) { break }

            $CurrentPath = $DirQueue.Dequeue()
            if ($HasExclusions -and (Test-PathExcluded -Path $CurrentPath -ExcludePaths $ExcludePaths)) { continue }

            if ($UITimer.ElapsedMilliseconds -ge 400) {
                $Short = if ($CurrentPath.Length -gt 60) { '...' + $CurrentPath.Substring($CurrentPath.Length - 57) } else { $CurrentPath }
                $StatusLabel.Text = "Enumerating... $($AllFiles.Count) found | $Short"
                [System.Windows.Forms.Application]::DoEvents()
                $UITimer.Restart()
            }

            try {
                foreach ($Item in (Get-ChildItem -LiteralPath $CurrentPath -Force -ErrorAction Stop)) {
                    if ($Script:ScanCancelled) { break }
                    if ($Item.PSIsContainer) {
                        if ($Recurse -and -not ($Item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                            $DirQueue.Enqueue($Item.FullName)
                        }
                    }
                    elseif ($Item.Extension -ieq ".vbs") {
                        $AllFiles.Add($Item)
                    }
                }
            }
            catch [System.UnauthorizedAccessException] {
                $Script:ErrorCount++
                Write-CMTraceLog -Message "Access denied: $CurrentPath" -Severity 3 -Component "Scan"
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
    }

    if ($Script:ScanCancelled) {
        Write-CMTraceLog -Message "Scan cancelled by user" -Severity 2 -Component "Scan"
        $ProgressBar.Style = "Continuous"
        $StatusLabel.Text  = "Scan cancelled"
        $StatusLabel.ForeColor = [System.Drawing.Color]::Orange
        return $false
    }

    # -----------------------------------------------------------------------
    # Phase 2: Build result objects (pure in-memory; zero disk I/O per file)
    # -----------------------------------------------------------------------
    $StatusLabel.Text = "Found $($AllFiles.Count) file(s) - building results..."
    [System.Windows.Forms.Application]::DoEvents()

    $ProgressBar.Style   = "Continuous"
    $ProgressBar.Maximum = [Math]::Max(1, $AllFiles.Count)
    $ProgressBar.Value   = 0
    $Processed = 0

    foreach ($Item in $AllFiles) {
        $PackageName = ""
        $Version     = ""
        $Build       = ""

        if ($EntryType -eq "ArchiveRoot" -and $Script:ArchiveRoot) {
            $Meta        = Get-ArchiveMetadataFromPath -ArchiveRoot $Script:ArchiveRoot -FullPath $Item.FullName
            $PackageName = $Meta.PackageName
            $Version     = $Meta.Version
            $Build       = $Meta.Build
        }

        $null = $Script:ScanResults.Add([PSCustomObject]@{
            FileName      = $Item.Name
            FullPath      = $Item.FullName
            ParentFolder  = $Item.DirectoryName
            LastWriteTime = $Item.LastWriteTime
            SizeBytes     = $Item.Length
            PackageName   = $PackageName
            Version       = $Version
            Build         = $Build
        })

        $Processed++
        if ($UITimer.ElapsedMilliseconds -ge 400) {
            $ProgressBar.Value = $Processed
            [System.Windows.Forms.Application]::DoEvents()
            $UITimer.Restart()
        }
    }

    # -----------------------------------------------------------------------
    # Phase 3: Batch-populate DataGrid (SuspendLayout prevents per-row repaint)
    # -----------------------------------------------------------------------
    $StatusLabel.Text = "Populating results grid..."
    [System.Windows.Forms.Application]::DoEvents()

    $DataGrid.SuspendLayout()
    try {
        foreach ($FileInfo in $Script:ScanResults) {
            $null = $DataGrid.Rows.Add(
                $FileInfo.FileName,
                $FileInfo.FullPath,
                $FileInfo.ParentFolder,
                $FileInfo.PackageName,
                $FileInfo.Version,
                $FileInfo.Build,
                $FileInfo.LastWriteTime.ToString("yyyy-MM-dd HH:mm:ss"),
                $FileInfo.SizeBytes
            )
        }
    }
    finally {
        $DataGrid.ResumeLayout($true)
    }

    $ProgressBar.Value = $ProgressBar.Maximum
    $ScanTimer.Stop()
    Write-CMTraceLog -Message "VBS scan complete. Found $($Script:ScanResults.Count) files | Errors: $($Script:ErrorCount) | Elapsed: $([Math]::Round($ScanTimer.Elapsed.TotalSeconds,2))s" -Component "Scan"
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
    $MainForm.Size = New-Object System.Drawing.Size(1400, 900)
    $MainForm.StartPosition = "CenterScreen"
    $MainForm.MinimumSize = New-Object System.Drawing.Size(1100, 650)
    $MainForm.Font = New-Object System.Drawing.Font("Segoe UI", 9)
    $MainForm.Icon = [System.Drawing.SystemIcons]::Application
    $MainForm.BackColor = [System.Drawing.Color]::FromArgb(240, 242, 245)
    #endregion

    # =============================================================
    # MAIN SPLIT  :  Left (controls sidebar) | Right (results)
    # =============================================================
    $MainSplit = New-Object System.Windows.Forms.SplitContainer
    $MainSplit.Dock = "Fill"
    $MainSplit.Orientation = "Vertical"
    $MainSplit.SplitterWidth = 5
    $MainSplit.BackColor = [System.Drawing.Color]::FromArgb(208, 215, 224)
    # Panel1MinSize, Panel2MinSize and SplitterDistance set in Form.Shown after the form is sized

    # =============================================================
    # LEFT PANEL  - scrollable sidebar, all controls stacked top-down
    # =============================================================
    $LeftPanel = New-Object System.Windows.Forms.Panel
    $LeftPanel.Dock = "Fill"
    $LeftPanel.AutoScroll = $true
    $LeftPanel.BackColor = [System.Drawing.Color]::White

    # Usable content width inside the left panel
    $LW  = 318    # full usable width
    $LWA = 296    # $LW - 22 : textboxes inside InputGroupBox (8px side + border)
    $LWB = 300    # $LW - 18 : controls inside option GroupBoxes
    $LWC = 224    # $LW - 94 : OutputFolder textbox width
    $LWD = 236    # $LW - 82 : BrowseFolder button X position

    # ---- App title ---------------------------------------------------
    $LblAppTitle = New-Object System.Windows.Forms.Label
    $LblAppTitle.Text = "VBS Scanner"
    $LblAppTitle.Location = New-Object System.Drawing.Point(12, 12)
    $LblAppTitle.Size = New-Object System.Drawing.Size(200, 26)
    $LblAppTitle.Font = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $LblAppTitle.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 212)

    $LblAppSubtitle = New-Object System.Windows.Forms.Label
    $LblAppSubtitle.Text = "v$Script:AppVersion"
    $LblAppSubtitle.Location = New-Object System.Drawing.Point(222, 18)
    $LblAppSubtitle.Size = New-Object System.Drawing.Size(80, 18)
    $LblAppSubtitle.ForeColor = [System.Drawing.Color]::Gray
    $LblAppSubtitle.Font = New-Object System.Drawing.Font("Segoe UI", 8)

    # ---- Scan Mode ---------------------------------------------------
    $ScanModeGroupBox = New-Object System.Windows.Forms.GroupBox
    $ScanModeGroupBox.Text = "Scan Mode"
    $ScanModeGroupBox.Location = New-Object System.Drawing.Point(10, 44)
    $ScanModeGroupBox.Size = New-Object System.Drawing.Size($LW, 56)

    $RadioVbsScan = New-Object System.Windows.Forms.RadioButton
    $RadioVbsScan.Text = "VBS File Scan"
    $RadioVbsScan.Location = New-Object System.Drawing.Point(10, 18)
    $RadioVbsScan.Size = New-Object System.Drawing.Size(135, 20)
    $RadioVbsScan.Checked = $true

    $RadioMsiScan = New-Object System.Windows.Forms.RadioButton
    $RadioMsiScan.Text = "MSI/MST Scan"
    $RadioMsiScan.Location = New-Object System.Drawing.Point(158, 18)
    $RadioMsiScan.Size = New-Object System.Drawing.Size(135, 20)

    $ScanModeGroupBox.Controls.Add($RadioVbsScan)
    $ScanModeGroupBox.Controls.Add($RadioMsiScan)

    # ---- Scan Target (vertical stack inside) -------------------------
    $InputGroupBox = New-Object System.Windows.Forms.GroupBox
    $InputGroupBox.Text = "Scan Target"
    $InputGroupBox.Location = New-Object System.Drawing.Point(10, 106)
    $InputGroupBox.Size = New-Object System.Drawing.Size($LW, 178)

    $RadioDevice = New-Object System.Windows.Forms.RadioButton
    $RadioDevice.Text = "Device / Local Path:"
    $RadioDevice.Location = New-Object System.Drawing.Point(8, 18)
    $RadioDevice.Size = New-Object System.Drawing.Size(160, 18)
    $RadioDevice.Checked = $true

    $TxtDeviceName = New-Object System.Windows.Forms.TextBox
    $TxtDeviceName.Location = New-Object System.Drawing.Point(8, 38)
    $TxtDeviceName.Size = New-Object System.Drawing.Size($LWA, 23)

    $LblDeviceHint = New-Object System.Windows.Forms.Label
    $LblDeviceHint.Text = "e.g.  C:\folder   or   PC-123  (maps to \\PC-123\C$)"
    $LblDeviceHint.Location = New-Object System.Drawing.Point(8, 63)
    $LblDeviceHint.Size = New-Object System.Drawing.Size($LWA, 14)
    $LblDeviceHint.ForeColor = [System.Drawing.Color]::Gray
    $LblDeviceHint.Font = New-Object System.Drawing.Font("Segoe UI", 7.5)

    $RadioUNC = New-Object System.Windows.Forms.RadioButton
    $RadioUNC.Text = "UNC Path:"
    $RadioUNC.Location = New-Object System.Drawing.Point(8, 82)
    $RadioUNC.Size = New-Object System.Drawing.Size(160, 18)

    $TxtUNCPath = New-Object System.Windows.Forms.TextBox
    $TxtUNCPath.Location = New-Object System.Drawing.Point(8, 102)
    $TxtUNCPath.Size = New-Object System.Drawing.Size($LWA, 23)
    $TxtUNCPath.Enabled = $false

    $RadioArchive = New-Object System.Windows.Forms.RadioButton
    $RadioArchive.Text = "Archive Root:"
    $RadioArchive.Location = New-Object System.Drawing.Point(8, 132)
    $RadioArchive.Size = New-Object System.Drawing.Size(160, 18)

    $TxtArchiveRoot = New-Object System.Windows.Forms.TextBox
    $TxtArchiveRoot.Location = New-Object System.Drawing.Point(8, 150)
    $TxtArchiveRoot.Size = New-Object System.Drawing.Size($LWA, 23)
    $TxtArchiveRoot.Enabled = $false

    $InputGroupBox.Controls.Add($RadioDevice)
    $InputGroupBox.Controls.Add($TxtDeviceName)
    $InputGroupBox.Controls.Add($LblDeviceHint)
    $InputGroupBox.Controls.Add($RadioUNC)
    $InputGroupBox.Controls.Add($TxtUNCPath)
    $InputGroupBox.Controls.Add($RadioArchive)
    $InputGroupBox.Controls.Add($TxtArchiveRoot)

    # ---- Output Folder -----------------------------------------------
    $OutFolderGroupBox = New-Object System.Windows.Forms.GroupBox
    $OutFolderGroupBox.Text = "Output Folder"
    $OutFolderGroupBox.Location = New-Object System.Drawing.Point(10, 290)
    $OutFolderGroupBox.Size = New-Object System.Drawing.Size($LW, 66)

    $TxtOutputFolder = New-Object System.Windows.Forms.TextBox
    $TxtOutputFolder.Location = New-Object System.Drawing.Point(8, 18)
    $TxtOutputFolder.Size = New-Object System.Drawing.Size($LWC, 23)
    $TxtOutputFolder.Text = $Script:DefaultOutputFolder

    $BtnBrowseFolder = New-Object System.Windows.Forms.Button
    $BtnBrowseFolder.Text = "Browse..."
    $BtnBrowseFolder.Location = New-Object System.Drawing.Point($LWD, 17)
    $BtnBrowseFolder.Size = New-Object System.Drawing.Size(74, 25)

    $OutFolderGroupBox.Controls.Add($TxtOutputFolder)
    $OutFolderGroupBox.Controls.Add($BtnBrowseFolder)

    # ---- VBS Scan Options (visible in VBS mode) ----------------------
    $VbsOptionsGroupBox = New-Object System.Windows.Forms.GroupBox
    $VbsOptionsGroupBox.Text = "VBS Scan Options"
    $VbsOptionsGroupBox.Location = New-Object System.Drawing.Point(10, 362)
    $VbsOptionsGroupBox.Size = New-Object System.Drawing.Size($LW, 100)
    $VbsOptionsGroupBox.Visible = $true

    $ChkRecurse = New-Object System.Windows.Forms.CheckBox
    $ChkRecurse.Text = "Recurse subdirectories"
    $ChkRecurse.Location = New-Object System.Drawing.Point(8, 18)
    $ChkRecurse.Size = New-Object System.Drawing.Size($LWB, 18)
    $ChkRecurse.Checked = $true

    $LblExclude = New-Object System.Windows.Forms.Label
    $LblExclude.Text = "Exclude paths (semicolon-separated):"
    $LblExclude.Location = New-Object System.Drawing.Point(8, 42)
    $LblExclude.Size = New-Object System.Drawing.Size($LWB, 16)

    $TxtExcludePaths = New-Object System.Windows.Forms.TextBox
    $TxtExcludePaths.Location = New-Object System.Drawing.Point(8, 60)
    $TxtExcludePaths.Size = New-Object System.Drawing.Size($LWB, 23)

    $VbsOptionsGroupBox.Controls.Add($ChkRecurse)
    $VbsOptionsGroupBox.Controls.Add($LblExclude)
    $VbsOptionsGroupBox.Controls.Add($TxtExcludePaths)

    # ---- MSI/MST Scan Options (visible in MSI mode) ------------------
    $MsiOptionsGroupBox = New-Object System.Windows.Forms.GroupBox
    $MsiOptionsGroupBox.Text = "MSI/MST Scan Options"
    $MsiOptionsGroupBox.Location = New-Object System.Drawing.Point(10, 362)
    $MsiOptionsGroupBox.Size = New-Object System.Drawing.Size($LW, 160)
    $MsiOptionsGroupBox.Visible = $false

    $ChkScanMsi = New-Object System.Windows.Forms.CheckBox
    $ChkScanMsi.Text = "Scan MSI files"
    $ChkScanMsi.Location = New-Object System.Drawing.Point(8, 18)
    $ChkScanMsi.Size = New-Object System.Drawing.Size(145, 18)
    $ChkScanMsi.Checked = $true

    $ChkScanMst = New-Object System.Windows.Forms.CheckBox
    $ChkScanMst.Text = "Scan MST files"
    $ChkScanMst.Location = New-Object System.Drawing.Point(8, 38)
    $ChkScanMst.Size = New-Object System.Drawing.Size(145, 18)
    $ChkScanMst.Checked = $true

    $ChkDeepBinary = New-Object System.Windows.Forms.CheckBox
    $ChkDeepBinary.Text = "Deep scan Binary streams"
    $ChkDeepBinary.Location = New-Object System.Drawing.Point(8, 58)
    $ChkDeepBinary.Size = New-Object System.Drawing.Size($LWB, 18)
    $ChkDeepBinary.Checked = $false

    $ChkActiveSetup = New-Object System.Windows.Forms.CheckBox
    $ChkActiveSetup.Text = "Detect Active Setup indicators"
    $ChkActiveSetup.Location = New-Object System.Drawing.Point(8, 78)
    $ChkActiveSetup.Size = New-Object System.Drawing.Size($LWB, 18)
    $ChkActiveSetup.Checked = $true

    $ChkMsiRecurse = New-Object System.Windows.Forms.CheckBox
    $ChkMsiRecurse.Text = "Recurse subdirectories"
    $ChkMsiRecurse.Location = New-Object System.Drawing.Point(8, 98)
    $ChkMsiRecurse.Size = New-Object System.Drawing.Size($LWB, 18)
    $ChkMsiRecurse.Checked = $true

    $LblMsiExclude = New-Object System.Windows.Forms.Label
    $LblMsiExclude.Text = "Exclude paths (semicolon-separated):"
    $LblMsiExclude.Location = New-Object System.Drawing.Point(8, 120)
    $LblMsiExclude.Size = New-Object System.Drawing.Size($LWB, 16)

    $TxtMsiExcludePaths = New-Object System.Windows.Forms.TextBox
    $TxtMsiExcludePaths.Location = New-Object System.Drawing.Point(8, 138)
    $TxtMsiExcludePaths.Size = New-Object System.Drawing.Size($LWB, 23)

    $MsiOptionsGroupBox.Controls.Add($ChkScanMsi)
    $MsiOptionsGroupBox.Controls.Add($ChkScanMst)
    $MsiOptionsGroupBox.Controls.Add($ChkDeepBinary)
    $MsiOptionsGroupBox.Controls.Add($ChkActiveSetup)
    $MsiOptionsGroupBox.Controls.Add($ChkMsiRecurse)
    $MsiOptionsGroupBox.Controls.Add($LblMsiExclude)
    $MsiOptionsGroupBox.Controls.Add($TxtMsiExcludePaths)

    # ---- Action Buttons Row 1 (Scan, Cancel, Generate Report) --------
    # Positioned below the taller MSI group (362 + 160 + 6 = 528)
    $BtnScan = New-Object System.Windows.Forms.Button
    $BtnScan.Text = "Scan"
    $BtnScan.Location = New-Object System.Drawing.Point(10, 528)
    $BtnScan.Size = New-Object System.Drawing.Size(88, 30)
    $BtnScan.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $BtnScan.ForeColor = [System.Drawing.Color]::White
    $BtnScan.FlatStyle = "Flat"
    $BtnScan.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)

    $BtnCancel = New-Object System.Windows.Forms.Button
    $BtnCancel.Text = "Cancel"
    $BtnCancel.Location = New-Object System.Drawing.Point(104, 528)
    $BtnCancel.Size = New-Object System.Drawing.Size(72, 30)
    $BtnCancel.Enabled = $false

    $BtnGenerateReport = New-Object System.Windows.Forms.Button
    $BtnGenerateReport.Text = "Generate Report"
    $BtnGenerateReport.Location = New-Object System.Drawing.Point(182, 528)
    $BtnGenerateReport.Size = New-Object System.Drawing.Size(126, 30)
    $BtnGenerateReport.Enabled = $false

    # ---- Action Buttons Row 2 (Export CSV, Open Log) -----------------
    $BtnExportCSV = New-Object System.Windows.Forms.Button
    $BtnExportCSV.Text = "Export CSV"
    $BtnExportCSV.Location = New-Object System.Drawing.Point(10, 564)
    $BtnExportCSV.Size = New-Object System.Drawing.Size(88, 28)
    $BtnExportCSV.Enabled = $false

    $BtnOpenLog = New-Object System.Windows.Forms.Button
    $BtnOpenLog.Text = "Open Log"
    $BtnOpenLog.Location = New-Object System.Drawing.Point(104, 564)
    $BtnOpenLog.Size = New-Object System.Drawing.Size(72, 28)

    # ---- Progress Bar ------------------------------------------------
    $ProgressBar = New-Object System.Windows.Forms.ProgressBar
    $ProgressBar.Location = New-Object System.Drawing.Point(10, 598)
    $ProgressBar.Size = New-Object System.Drawing.Size($LW, 18)
    $ProgressBar.Style = "Continuous"

    # ---- Status Label ------------------------------------------------
    $LblStatus = New-Object System.Windows.Forms.Label
    $LblStatus.Text = "Ready"
    $LblStatus.Location = New-Object System.Drawing.Point(10, 622)
    $LblStatus.Size = New-Object System.Drawing.Size($LW, 18)
    $LblStatus.ForeColor = [System.Drawing.Color]::DarkGreen

    # ---- Current Mode Label ------------------------------------------
    $LblCurrentMode = New-Object System.Windows.Forms.Label
    $LblCurrentMode.Text = "Mode: VBS File Scan"
    $LblCurrentMode.Location = New-Object System.Drawing.Point(10, 644)
    $LblCurrentMode.Size = New-Object System.Drawing.Size($LW, 18)
    $LblCurrentMode.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $LblCurrentMode.Font = New-Object System.Drawing.Font("Segoe UI", 8.5, [System.Drawing.FontStyle]::Bold)

    # ---- Statistics Panel (mirrors TextTrace's stats box) ------------
    $StatsGroupBox = New-Object System.Windows.Forms.GroupBox
    $StatsGroupBox.Text = "Statistics"
    $StatsGroupBox.Location = New-Object System.Drawing.Point(10, 668)
    $StatsGroupBox.Size = New-Object System.Drawing.Size($LW, 96)
    $StatsGroupBox.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 212)

    $LblStats = New-Object System.Windows.Forms.Label
    $LblStats.Text = "No scan performed yet."
    $LblStats.Location = New-Object System.Drawing.Point(8, 18)
    $LblStats.Size = New-Object System.Drawing.Size($LWB, 72)
    $LblStats.ForeColor = [System.Drawing.Color]::FromArgb(80, 80, 80)
    $LblStats.Font = New-Object System.Drawing.Font("Segoe UI", 8.5)

    $StatsGroupBox.Controls.Add($LblStats)

    # ---- Add all controls to LeftPanel -------------------------------
    $LeftPanel.Controls.Add($LblAppTitle)
    $LeftPanel.Controls.Add($LblAppSubtitle)
    $LeftPanel.Controls.Add($ScanModeGroupBox)
    $LeftPanel.Controls.Add($InputGroupBox)
    $LeftPanel.Controls.Add($OutFolderGroupBox)
    $LeftPanel.Controls.Add($VbsOptionsGroupBox)
    $LeftPanel.Controls.Add($MsiOptionsGroupBox)
    $LeftPanel.Controls.Add($BtnScan)
    $LeftPanel.Controls.Add($BtnCancel)
    $LeftPanel.Controls.Add($BtnGenerateReport)
    $LeftPanel.Controls.Add($BtnExportCSV)
    $LeftPanel.Controls.Add($BtnOpenLog)
    $LeftPanel.Controls.Add($ProgressBar)
    $LeftPanel.Controls.Add($LblStatus)
    $LeftPanel.Controls.Add($LblCurrentMode)
    $LeftPanel.Controls.Add($StatsGroupBox)

    # =============================================================
    # RIGHT SPLIT  :  Results grid (top) | HTML preview (bottom)
    # =============================================================
    $ResultsSplit = New-Object System.Windows.Forms.SplitContainer
    $ResultsSplit.Dock = "Fill"
    $ResultsSplit.Orientation = "Horizontal"
    $ResultsSplit.SplitterDistance = 420
    $ResultsSplit.Panel1MinSize = 200
    $ResultsSplit.Panel2MinSize = 150

    #region TabControl for Results (VBS vs MSI)
    $TabControl = New-Object System.Windows.Forms.TabControl
    $TabControl.Dock = "Fill"

    $TabVbsResults = New-Object System.Windows.Forms.TabPage
    $TabVbsResults.Text = "VBS File Results"

    $TabMsiResults = New-Object System.Windows.Forms.TabPage
    $TabMsiResults.Text = "MSI/MST Findings"

    $TabControl.TabPages.Add($TabVbsResults)
    $TabControl.TabPages.Add($TabMsiResults)
    # Default mode is VBS - hide MSI results tab until MSI scan mode is selected
    $TabControl.TabPages.Remove($TabMsiResults)
    #endregion

    #region VBS DataGridView
    $DataGridViewVbs = New-Object System.Windows.Forms.DataGridView
    $DataGridViewVbs.Dock = "Fill"
    $DataGridViewVbs.AllowUserToAddRows = $false
    $DataGridViewVbs.AllowUserToDeleteRows = $false
    $DataGridViewVbs.ReadOnly = $true
    $DataGridViewVbs.SelectionMode = "FullRowSelect"
    $DataGridViewVbs.MultiSelect = $false
    $DataGridViewVbs.AutoSizeColumnsMode = "Fill"
    $DataGridViewVbs.RowHeadersVisible = $false
    $DataGridViewVbs.BackgroundColor = [System.Drawing.Color]::White
    $DataGridViewVbs.BorderStyle = "None"
    $DataGridViewVbs.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
    $DataGridViewVbs.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $DataGridViewVbs.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $DataGridViewVbs.EnableHeadersVisualStyles = $false
    $DataGridViewVbs.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(245, 245, 245)
    $DataGridViewVbs.AllowUserToOrderColumns = $true

    # VBS Grid Columns
    @(
        @{Name="FileName"; Header="File Name"; Weight=15},
        @{Name="FullPath"; Header="Full Path"; Weight=25},
        @{Name="ParentFolder"; Header="Parent Folder"; Weight=18},
        @{Name="PackageName"; Header="Package"; Weight=10},
        @{Name="Version"; Header="Version"; Weight=8},
        @{Name="Build"; Header="Build"; Weight=8},
        @{Name="LastWriteTime"; Header="Last Modified"; Weight=10},
        @{Name="SizeBytes"; Header="Size (Bytes)"; Weight=6}
    ) | ForEach-Object {
        $Col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $Col.Name = $_.Name
        $Col.HeaderText = $_.Header
        $Col.FillWeight = $_.Weight
        if ($_.Name -eq "SizeBytes") { $Col.DefaultCellStyle.Alignment = "MiddleRight" }
        $null = $DataGridViewVbs.Columns.Add($Col)
    }

    # VBS Context Menu
    $VbsContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $VbsMenuOpenNotepad = New-Object System.Windows.Forms.ToolStripMenuItem
    $VbsMenuOpenNotepad.Text = "Open in Notepad"
    $VbsMenuCopyPath = New-Object System.Windows.Forms.ToolStripMenuItem
    $VbsMenuCopyPath.Text = "Copy Full Path"
    $VbsMenuOpenFolder = New-Object System.Windows.Forms.ToolStripMenuItem
    $VbsMenuOpenFolder.Text = "Open Containing Folder"
    $null = $VbsContextMenu.Items.Add($VbsMenuOpenNotepad)
    $null = $VbsContextMenu.Items.Add($VbsMenuCopyPath)
    $null = $VbsContextMenu.Items.Add($VbsMenuOpenFolder)
    $DataGridViewVbs.ContextMenuStrip = $VbsContextMenu

    $TabVbsResults.Controls.Add($DataGridViewVbs)
    #endregion

    #region MSI DataGridView (NEW)
    $DataGridViewMsi = New-Object System.Windows.Forms.DataGridView
    $DataGridViewMsi.Dock = "Fill"
    $DataGridViewMsi.AllowUserToAddRows = $false
    $DataGridViewMsi.AllowUserToDeleteRows = $false
    $DataGridViewMsi.ReadOnly = $true
    $DataGridViewMsi.SelectionMode = "FullRowSelect"
    $DataGridViewMsi.MultiSelect = $false
    $DataGridViewMsi.AutoSizeColumnsMode = "Fill"
    $DataGridViewMsi.RowHeadersVisible = $false
    $DataGridViewMsi.BackgroundColor = [System.Drawing.Color]::FromArgb(255, 245, 245)
    $DataGridViewMsi.BorderStyle = "None"
    $DataGridViewMsi.ColumnHeadersDefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(139, 0, 0)  # Dark red for MSI
    $DataGridViewMsi.ColumnHeadersDefaultCellStyle.ForeColor = [System.Drawing.Color]::White
    $DataGridViewMsi.ColumnHeadersDefaultCellStyle.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $DataGridViewMsi.EnableHeadersVisualStyles = $false
    $DataGridViewMsi.AlternatingRowsDefaultCellStyle.BackColor = [System.Drawing.Color]::White
    $DataGridViewMsi.DefaultCellStyle.BackColor = [System.Drawing.Color]::FromArgb(255, 245, 245)
    $DataGridViewMsi.AllowUserToOrderColumns = $true

    # MSI Grid Columns
    @(
        @{Name="InstallerPath"; Header="Installer Path"; Weight=18},
        @{Name="FileType"; Header="Type"; Weight=5},
        @{Name="ProductName"; Header="Product Name"; Weight=11},
        @{Name="ProductVersion"; Header="Version"; Weight=6},
        @{Name="Manufacturer"; Header="Vendor"; Weight=9},
        @{Name="FindingCategory"; Header="Category"; Weight=11},
        @{Name="TableOrSource"; Header="Table/Source"; Weight=8},
        @{Name="ItemName"; Header="Item Name"; Weight=10},
        @{Name="Evidence"; Header="Evidence"; Weight=18},
        @{Name="Severity"; Header="Severity"; Weight=6}
    ) | ForEach-Object {
        $Col = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
        $Col.Name = $_.Name
        $Col.HeaderText = $_.Header
        $Col.FillWeight = $_.Weight
        $null = $DataGridViewMsi.Columns.Add($Col)
    }

    # MSI Context Menu
    $MsiContextMenu = New-Object System.Windows.Forms.ContextMenuStrip
    $MsiMenuOpenExplorer = New-Object System.Windows.Forms.ToolStripMenuItem
    $MsiMenuOpenExplorer.Text = "Open in Explorer"
    $MsiMenuCopyPath = New-Object System.Windows.Forms.ToolStripMenuItem
    $MsiMenuCopyPath.Text = "Copy Installer Path"
    $MsiMenuCopyEvidence = New-Object System.Windows.Forms.ToolStripMenuItem
    $MsiMenuCopyEvidence.Text = "Copy Evidence"
    $null = $MsiContextMenu.Items.Add($MsiMenuOpenExplorer)
    $null = $MsiContextMenu.Items.Add($MsiMenuCopyPath)
    $null = $MsiContextMenu.Items.Add($MsiMenuCopyEvidence)
    $DataGridViewMsi.ContextMenuStrip = $MsiContextMenu

    $TabMsiResults.Controls.Add($DataGridViewMsi)
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
    # Right side: results grid on top, HTML preview on bottom
    $ResultsSplit.Panel1.Controls.Add($TabControl)
    $ResultsSplit.Panel2.Controls.Add($WebBrowser)
    $ResultsSplit.Panel2.Controls.Add($LblReportHeader)

    # Main split: left controls sidebar | right results area
    $MainSplit.Panel1.Controls.Add($LeftPanel)
    $MainSplit.Panel2.Controls.Add($ResultsSplit)

    $MainForm.Controls.Add($MainSplit)
    #endregion

    #region EVENT HANDLERS

    # Scan Mode toggle
    $RadioVbsScan.Add_CheckedChanged({
        if ($RadioVbsScan.Checked) {
            $Script:CurrentScanMode = "VBSFileScan"
            $VbsOptionsGroupBox.Visible = $true
            $MsiOptionsGroupBox.Visible = $false
            $LblCurrentMode.Text = "Mode: VBS File Scan - Searches for .vbs files"
            $LblCurrentMode.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 212)
            if (-not $TabControl.TabPages.Contains($TabVbsResults)) { $TabControl.TabPages.Insert(0, $TabVbsResults) }
            if ($TabControl.TabPages.Contains($TabMsiResults))  { $TabControl.TabPages.Remove($TabMsiResults) }
            $TabControl.SelectedTab = $TabVbsResults
        }
    })

    $RadioMsiScan.Add_CheckedChanged({
        if ($RadioMsiScan.Checked) {
            $Script:CurrentScanMode = "MSIMSTScan"
            $VbsOptionsGroupBox.Visible = $false
            $MsiOptionsGroupBox.Visible = $true
            $LblCurrentMode.Text = "Mode: MSI/MST Scan - Detects VBScript indicators in Windows Installer files"
            $LblCurrentMode.ForeColor = [System.Drawing.Color]::FromArgb(139, 0, 0)
            if (-not $TabControl.TabPages.Contains($TabMsiResults)) { $TabControl.TabPages.Insert(0, $TabMsiResults) }
            if ($TabControl.TabPages.Contains($TabVbsResults))  { $TabControl.TabPages.Remove($TabVbsResults) }
            $TabControl.SelectedTab = $TabMsiResults
        }
    })

    # Target type toggles
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
        }
    })

    # Open Log
    $BtnOpenLog.Add_Click({
        if (Test-Path -Path $Script:LogFile) {
            Start-Process -FilePath "notepad.exe" -ArgumentList "`"$Script:LogFile`""
        }
        else {
            [System.Windows.Forms.MessageBox]::Show("Log file not found: $Script:LogFile", "File Not Found", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
        }
    })

    # Export CSV
    $BtnExportCSV.Add_Click({
        $HasResults = if ($Script:CurrentScanMode -eq "VBSFileScan") { $Script:ScanResults.Count -gt 0 } else { $Script:MsiScanResults.Count -gt 0 }

        if (-not $HasResults) {
            [System.Windows.Forms.MessageBox]::Show("No results to export.", "Export CSV", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }

        $SaveDialog = New-Object System.Windows.Forms.SaveFileDialog
        $SaveDialog.Filter = "CSV Files (*.csv)|*.csv"
        $Prefix = if ($Script:CurrentScanMode -eq "VBSFileScan") { "VBS" } else { "MSI" }
        $SaveDialog.FileName = "${Prefix}Scanner_Results_$($Script:Timestamp).csv"
        $SaveDialog.InitialDirectory = $TxtOutputFolder.Text

        if ($SaveDialog.ShowDialog() -eq "OK") {
            try {
                if ($Script:CurrentScanMode -eq "VBSFileScan") {
                    $Script:ScanResults | Select-Object FileName, FullPath, ParentFolder, PackageName, Version, Build, LastWriteTime, SizeBytes | 
                        Export-Csv -Path $SaveDialog.FileName -NoTypeInformation -Encoding UTF8
                }
                else {
                    $Script:MsiScanResults | Select-Object InstallerPath, FileType, ProductName, ProductVersion, ProductCode, FindingCategory, TableOrSource, ItemName, Evidence, Severity | 
                        Export-Csv -Path $SaveDialog.FileName -NoTypeInformation -Encoding UTF8
                }
                Write-CMTraceLog -Message "Exported results to CSV: $($SaveDialog.FileName)" -Component "Export"
                [System.Windows.Forms.MessageBox]::Show("Results exported to: $($SaveDialog.FileName)", "Export Complete", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            }
            catch {
                Write-CMTraceLog -Message "Failed to export CSV: $($_.Exception.Message)" -Severity 3 -Component "Export"
                [System.Windows.Forms.MessageBox]::Show("Failed to export: $($_.Exception.Message)", "Export Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
            }
        }
    })

    # VBS Grid double-click
    $DataGridViewVbs.Add_CellDoubleClick({
        param($sender, $e)
        if ($e.RowIndex -ge 0) {
            $FilePath = $DataGridViewVbs.Rows[$e.RowIndex].Cells["FullPath"].Value
            if ($FilePath) { Open-FileInNotepad -FilePath $FilePath }
        }
    })

    # VBS Context menu actions
    $VbsMenuOpenNotepad.Add_Click({
        if ($DataGridViewVbs.SelectedRows.Count -gt 0) {
            $FilePath = $DataGridViewVbs.SelectedRows[0].Cells["FullPath"].Value
            if ($FilePath) { Open-FileInNotepad -FilePath $FilePath }
        }
    })

    $VbsMenuCopyPath.Add_Click({
        if ($DataGridViewVbs.SelectedRows.Count -gt 0) {
            $FilePath = $DataGridViewVbs.SelectedRows[0].Cells["FullPath"].Value
            if ($FilePath) {
                [System.Windows.Forms.Clipboard]::SetText($FilePath)
                $LblStatus.Text = "Path copied to clipboard"
            }
        }
    })

    $VbsMenuOpenFolder.Add_Click({
        if ($DataGridViewVbs.SelectedRows.Count -gt 0) {
            $FilePath = $DataGridViewVbs.SelectedRows[0].Cells["FullPath"].Value
            if ($FilePath) { Open-FileInExplorer -FilePath $FilePath }
        }
    })

    # MSI Grid double-click
    $DataGridViewMsi.Add_CellDoubleClick({
        param($sender, $e)
        if ($e.RowIndex -ge 0) {
            $InstallerPath = $DataGridViewMsi.Rows[$e.RowIndex].Cells["InstallerPath"].Value
            if ($InstallerPath) { Open-FileInExplorer -FilePath $InstallerPath }
        }
    })

    # MSI Context menu actions
    $MsiMenuOpenExplorer.Add_Click({
        if ($DataGridViewMsi.SelectedRows.Count -gt 0) {
            $InstallerPath = $DataGridViewMsi.SelectedRows[0].Cells["InstallerPath"].Value
            if ($InstallerPath) { Open-FileInExplorer -FilePath $InstallerPath }
        }
    })

    $MsiMenuCopyPath.Add_Click({
        if ($DataGridViewMsi.SelectedRows.Count -gt 0) {
            $InstallerPath = $DataGridViewMsi.SelectedRows[0].Cells["InstallerPath"].Value
            if ($InstallerPath) {
                [System.Windows.Forms.Clipboard]::SetText($InstallerPath)
                $LblStatus.Text = "Path copied to clipboard"
            }
        }
    })

    $MsiMenuCopyEvidence.Add_Click({
        if ($DataGridViewMsi.SelectedRows.Count -gt 0) {
            $Evidence = $DataGridViewMsi.SelectedRows[0].Cells["Evidence"].Value
            if ($Evidence) {
                [System.Windows.Forms.Clipboard]::SetText($Evidence)
                $LblStatus.Text = "Evidence copied to clipboard"
            }
        }
    })

    # WebBrowser navigation intercept for VBS files
    $WebBrowser.Add_Navigating({
        param($sender, $e)
        $Url = $e.Url.ToString()

        if ($Url -like "file:///*" -and $Url -like "*.vbs") {
            $e.Cancel = $true
            $FilePath = $Url -replace "^file:///", ""
            $FilePath = $FilePath -replace "/", "\"
            $FilePath = [System.Web.HttpUtility]::UrlDecode($FilePath)
            Write-CMTraceLog -Message "WebBrowser link clicked: $FilePath" -Component "WebBrowser"
            Open-FileInNotepad -FilePath $FilePath
        }
        elseif ($Url -like "explorer:*") {
            $e.Cancel = $true
            $FilePath = $Url -replace "^explorer:/select/", ""
            $FilePath = $FilePath -replace "/", "\"
            $FilePath = [System.Web.HttpUtility]::UrlDecode($FilePath)
            Open-FileInExplorer -FilePath $FilePath
        }
    })

    # Generate Report
    $BtnGenerateReport.Add_Click({
        $HasResults = if ($Script:CurrentScanMode -eq "VBSFileScan") { $Script:ScanResults.Count -gt 0 } else { $Script:MsiScanResults.Count -gt 0 }

        if (-not $HasResults) {
            [System.Windows.Forms.MessageBox]::Show("No results to generate report from.", "Generate Report", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Information)
            return
        }

        $EndTime = Get-Date
        $Prefix = if ($Script:CurrentScanMode -eq "VBSFileScan") { "VBS" } else { "MSI" }
        $Script:HtmlReportFile = Join-Path -Path $TxtOutputFolder.Text -ChildPath "${Prefix}Scanner_Report_$($Script:Timestamp).html"

        $EntryType = $Script:CurrentEntryType
        $ScanRoot = Get-ScanRootFromInput -InputType $EntryType -DeviceName $TxtDeviceName.Text -UncPath $TxtUNCPath.Text -ArchiveRoot $TxtArchiveRoot.Text

        $LblStatus.Text = "Generating HTML report..."
        $MainForm.Refresh()

        $Success = $false
        if ($Script:CurrentScanMode -eq "VBSFileScan") {
            $Success = New-HtmlReport -Results $Script:ScanResults -ScanRoot $ScanRoot -EntryType $EntryType -StartTime $Script:StartTime -EndTime $EndTime -ErrorCount $Script:ErrorCount -OutputPath $Script:HtmlReportFile
        }
        else {
            $Success = New-MsiHtmlReport -Findings $Script:MsiScanResults -ScanRoot $ScanRoot -StartTime $Script:StartTime -EndTime $EndTime -ErrorCount $Script:MsiErrorCount -FilesScanned $Script:MsiFilesScanned -FilesWithFindings $Script:MsiFilesWithFindings -OutputPath $Script:HtmlReportFile
        }

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

    # Scan button
    $BtnScan.Add_Click({
        $EntryType = "DeviceName"
        if ($RadioUNC.Checked) { $EntryType = "UNC" }
        if ($RadioArchive.Checked) { $EntryType = "ArchiveRoot" }
        $Script:CurrentEntryType = $EntryType

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

        if (-not (Test-Path -Path $TxtOutputFolder.Text -PathType Container)) {
            try {
                New-Item -Path $TxtOutputFolder.Text -ItemType Directory -Force | Out-Null
            }
            catch {
                [System.Windows.Forms.MessageBox]::Show("Cannot create output folder: $($TxtOutputFolder.Text)", "Error", [System.Windows.Forms.MessageBoxButtons]::OK, [System.Windows.Forms.MessageBoxIcon]::Error)
                return
            }
        }

        $Script:Timestamp = (Get-Date).ToString("yyyyMMdd_HHmmss")
        $Script:LogFile = Join-Path -Path $TxtOutputFolder.Text -ChildPath "VBSScanner_$($Script:Timestamp).log"
        $Script:StartTime = Get-Date
        $Script:ScanCancelled = $false
        $Script:IsScanning = $true
        $WebBrowser.Navigate("about:blank")

        $BtnScan.Enabled = $false
        $BtnCancel.Enabled = $true
        $BtnGenerateReport.Enabled = $false
        $BtnExportCSV.Enabled = $false
        $ProgressBar.Value = 0
        $MainForm.Refresh()

        $Success = $false

        if ($Script:CurrentScanMode -eq "VBSFileScan") {
            $ExcludePaths = @()
            if (-not [string]::IsNullOrWhiteSpace($TxtExcludePaths.Text)) {
                $ExcludePaths = $TxtExcludePaths.Text -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            }

            $LblStatus.Text = "Scanning for VBS files..."
            $LblStatus.ForeColor = [System.Drawing.Color]::DarkBlue

            Write-CMTraceLog -Message "Starting VBS scan - EntryType: $EntryType | Root: $ScanRoot | Recurse: $($ChkRecurse.Checked)" -Component "Scan"

            $TabControl.SelectedTab = $TabVbsResults
            $Success = Start-VbsScan -ScanRoot $ScanRoot -EntryType $EntryType -Recurse $ChkRecurse.Checked -ExcludePaths $ExcludePaths -ProgressBar $ProgressBar -StatusLabel $LblStatus -DataGrid $DataGridViewVbs -ParentForm $MainForm

            if ($Success -and -not $Script:ScanCancelled) {
                $Duration = (Get-Date) - $Script:StartTime
                $LblStatus.Text = "VBS Scan Complete: $($Script:ScanResults.Count) files | $($Script:ErrorCount) errors | $($Duration.ToString('hh\:mm\:ss'))"
                $LblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
                $LblStats.Text = "Files found: $($Script:ScanResults.Count)" + [Environment]::NewLine + "Errors: $($Script:ErrorCount)" + [Environment]::NewLine + "Duration: $($Duration.ToString('hh\:mm\:ss'))"
                $BtnGenerateReport.Enabled = $Script:ScanResults.Count -gt 0
                $BtnExportCSV.Enabled = $Script:ScanResults.Count -gt 0
            }
        }
        else {
            # MSI/MST Scan
            $MsiExcludePaths = @()
            if (-not [string]::IsNullOrWhiteSpace($TxtMsiExcludePaths.Text)) {
                $MsiExcludePaths = $TxtMsiExcludePaths.Text -split ";" | ForEach-Object { $_.Trim() } | Where-Object { $_ }
            }

            $LblStatus.Text = "Scanning MSI/MST files for VBScript indicators..."
            $LblStatus.ForeColor = [System.Drawing.Color]::FromArgb(139, 0, 0)

            Write-CMTraceLog -Message "Starting MSI/MST scan - Root: $ScanRoot | ScanMsi: $($ChkScanMsi.Checked) | ScanMst: $($ChkScanMst.Checked) | DeepBinary: $($ChkDeepBinary.Checked)" -Component "MSIScan"

            $TabControl.SelectedTab = $TabMsiResults
            $Success = Start-MsiMstScan -ScanRoot $ScanRoot -Recurse $ChkMsiRecurse.Checked -ExcludePaths $MsiExcludePaths -ScanMsi $ChkScanMsi.Checked -ScanMst $ChkScanMst.Checked -DeepScanBinary $ChkDeepBinary.Checked -DetectActiveSetup $ChkActiveSetup.Checked -ProgressBar $ProgressBar -StatusLabel $LblStatus -DataGrid $DataGridViewMsi -ParentForm $MainForm

            if ($Success -and -not $Script:ScanCancelled) {
                $Duration = (Get-Date) - $Script:StartTime
                $LblStatus.Text = "MSI Scan Complete: $($Script:MsiFilesScanned) files | $($Script:MsiScanResults.Count) findings | $($Script:MsiErrorCount) errors | $($Duration.ToString('hh\:mm\:ss'))"
                $LblStatus.ForeColor = [System.Drawing.Color]::DarkGreen
                $LblStats.Text = "Files scanned: $($Script:MsiFilesScanned)" + [Environment]::NewLine + "Findings: $($Script:MsiScanResults.Count)" + [Environment]::NewLine + "Errors: $($Script:MsiErrorCount)" + [Environment]::NewLine + "Duration: $($Duration.ToString('hh\:mm\:ss'))"
                $BtnGenerateReport.Enabled = $Script:MsiScanResults.Count -gt 0
                $BtnExportCSV.Enabled = $Script:MsiScanResults.Count -gt 0
            }
        }

        $Script:IsScanning = $false
        $BtnScan.Enabled = $true
        $BtnCancel.Enabled = $false
    })

    # Set all splitter constraints after the form is fully sized to avoid init constraint errors
    $MainForm.Add_Shown({
        $MainSplit.Panel1MinSize = 280
        $MainSplit.Panel2MinSize = 200
        $MainSplit.SplitterDistance = 342
        # Re-enforce no-new-row after layout pass (WinForms can re-enable it during layout)
        $DataGridViewMsi.AllowUserToAddRows = $false
        $DataGridViewVbs.AllowUserToAddRows = $false
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

    $MainForm.Add_Shown({ $MainForm.Activate() })
    [void]$MainForm.ShowDialog()
}
#endregion

#region ===== MAIN ENTRY POINT =====
Build-MainForm
#endregion

