# VBS Scanner Utility - Working Notes

## Development & Operations Reference

---

## Project Overview

| Item | Details |
|------|---------|
| **Project Name** | VBS Scanner Utility |
| **Version** | 2.0.0 |
| **Language** | PowerShell 5.1 |
| **UI Framework** | WinForms (.NET) |
| **Primary Script** | VBSScannerGUI.ps1 |
| **Development Date** | March 2026 |

---

## File Inventory

| File | Purpose |
|------|---------|
| `VBSScannerGUI.ps1` | Main application script (GUI + engine) |
| `VBSScanner.ps1` | Command-line version (standalone) |
| `VBSScanner_Documentation.md` | Product documentation |
| `VBSScanner_WorkingNotes.md` | This file - development notes |
| `ConvertTo-Exe.bat` | Batch file to compile PS1 to EXE |

---

## Architecture Overview

```
┌─────────────────────────────────────────────────────────────────┐
│                        VBSScannerGUI.ps1                        │
├─────────────────────────────────────────────────────────────────┤
│  ┌─────────────┐  ┌─────────────┐  ┌─────────────────────────┐ │
│  │   GUI       │  │   Scan      │  │   Reporting             │ │
│  │   Layer     │  │   Engine    │  │   Engine                │ │
│  ├─────────────┤  ├─────────────┤  ├─────────────────────────┤ │
│  │ Build-      │  │ Start-      │  │ New-HtmlReport          │ │
│  │ MainForm    │  │ VbsScan     │  │ Export-Csv              │ │
│  │             │  │             │  │                         │ │
│  │ WinForms    │  │ Get-        │  │ CMTRACE Logging         │ │
│  │ Controls    │  │ ChildItem   │  │ Write-CMTraceLog        │ │
│  └─────────────┘  └─────────────┘  └─────────────────────────┘ │
│  ┌─────────────────────────────────────────────────────────────┐│
│  │                    Helper Functions                         ││
│  │  Get-ScanRootFromInput | Get-ArchiveMetadataFromPath       ││
│  │  Test-PathAccessible   | Test-PathExcluded                 ││
│  │  Open-FileInNotepad                                         ││
│  └─────────────────────────────────────────────────────────────┘│
└─────────────────────────────────────────────────────────────────┘
```

---

## Key Functions Reference

### Core Functions

| Function | Purpose | Parameters |
|----------|---------|------------|
| `Build-MainForm` | Constructs and displays the WinForms GUI | None |
| `Start-VbsScan` | Main scanning engine | ScanRoot, EntryType, Recurse, ExcludePaths, UI controls |
| `New-HtmlReport` | Generates HTML report | Results, ScanRoot, EntryType, StartTime, EndTime, ErrorCount, OutputPath |
| `Write-CMTraceLog` | CMTRACE-compatible logging | Message, Component, Severity, LogFile |

### Helper Functions

| Function | Purpose | Returns |
|----------|---------|---------|
| `Get-ScanRootFromInput` | Resolves scan path from input type | String (path) |
| `Get-ArchiveMetadataFromPath` | Extracts Package/Version/Build | PSCustomObject |
| `Test-PathAccessible` | Checks if path is accessible | Boolean |
| `Test-PathExcluded` | Checks if path should be skipped | Boolean |
| `Open-FileInNotepad` | Opens file in notepad.exe | Void |

---

## Data Model

### Result Object Structure

```powershell
[PSCustomObject]@{
    FileName      = [string]   # File name with extension
    FullPath      = [string]   # Complete file path
    ParentFolder  = [string]   # Parent directory path
    LastWriteTime = [datetime] # Last modified timestamp
    SizeBytes     = [long]     # File size in bytes
    PackageName   = [string]   # Extracted package name (Archive only)
    Version       = [string]   # Extracted version (Archive only)
    Build         = [string]   # Extracted build (Archive only)
}
```

### Script-Level Variables

```powershell
$Script:AppName            # Application display name
$Script:AppVersion         # Current version string
$Script:StartTime          # Scan start timestamp
$Script:Timestamp          # Formatted timestamp for file naming
$Script:DefaultOutputFolder# Default output location
$Script:LogFile            # Current log file path
$Script:HtmlReportFile     # Current report file path
$Script:ScanResults        # ArrayList of result objects
$Script:ErrorCount         # Count of errors during scan
$Script:ScanCancelled      # Cancellation flag
$Script:IsScanning         # Scan in progress flag
$Script:CurrentEntryType   # Selected entry type
$Script:ArchiveRoot        # Archive root for metadata extraction
```

---

## Archive Path Parsing Logic

### Expected Structure
```
\\Server\Archive\Vendor\PackageName\Version\Type\Build\[subfolders]\file.vbs
     └──────┬──────┘└─┬──┘└────┬────┘└──┬───┘└─┬─┘└─┬──┘
         Archive    [0]     [1]      [2]   [3]  [4]
          Root
```

### Parsing Algorithm

```powershell
# 1. Normalize paths (lowercase, consistent separators)
$NormalizedRoot = $ArchiveRoot.TrimEnd('\', '/').ToLower()
$NormalizedPath = $FullPath.ToLower()

# 2. Get relative path after archive root
$RelativePath = $FullPath.Substring($ArchiveRoot.Length).TrimStart('\', '/')

# 3. Split into segments
$Segments = $RelativePath -split '[\\/]' | Where-Object { $_ -ne '' }

# 4. Extract metadata (requires minimum 5 segments)
if ($Segments.Count -ge 5) {
    PackageName = $Segments[1]  # Index 1
    Version     = $Segments[2]  # Index 2
    Build       = $Segments[4]  # Index 4
}
```

---

## UI Responsiveness Strategy

### Problem
- Large directory scans can freeze the UI
- BackgroundWorker doesn't work with PowerShell functions (no runspace)

### Solution
- Use synchronous scanning with `[System.Windows.Forms.Application]::DoEvents()`
- Update UI every 100ms during scan loop
- User can click Cancel to set `$Script:ScanCancelled = $true`

```powershell
# UI Update Pattern
$Now = Get-Date
if (($Now - $LastUIUpdate).TotalMilliseconds -ge 100) {
    $StatusLabel.Text = "Files: $FileCount | Dirs: $DirCount"
    [System.Windows.Forms.Application]::DoEvents()
    $LastUIUpdate = $Now
}
```

---

## WebBrowser Integration

### Opening Files in Notepad from HTML Links

The WebBrowser control intercepts navigation to file:// URLs:

```powershell
$WebBrowser.Add_Navigating({
    param($sender, $e)
    $Url = $e.Url.ToString()
    
    if ($Url -like "file:///*" -and $Url -like "*.vbs") {
        $e.Cancel = $true  # Prevent navigation
        
        # Convert URI to path
        $FilePath = $Url -replace "^file:///", ""
        $FilePath = $FilePath -replace "/", "\"
        $FilePath = [System.Web.HttpUtility]::UrlDecode($FilePath)
        
        # Open in Notepad
        Start-Process "notepad.exe" -ArgumentList "`"$FilePath`""
    }
})
```

---

## CMTRACE Log Format Details

### Entry Structure
```xml
<![LOG[Message]LOG]!><time="HH:mm:ss.fff+TZOffset" date="MM-DD-YYYY" component="Component" context="" type="Severity" thread="ThreadID" file="FileName">
```

### Timezone Calculation
```powershell
$UtcOffset = [System.TimeZoneInfo]::Local.GetUtcOffset($Now)
$OffsetMinutes = $UtcOffset.TotalMinutes
$OffsetSign = if ($OffsetMinutes -ge 0) { "+" } else { "-" }
$OffsetString = "{0}{1}" -f $OffsetSign, [Math]::Abs($OffsetMinutes)
# Result: "+330" for IST, "-300" for EST
```

---

## Testing Checklist

### Functional Tests

- [ ] Scan local path (C:\folder)
- [ ] Scan device by name (PC-NAME → \\PC-NAME\C$)
- [ ] Scan UNC path (\\server\share)
- [ ] Scan Archive Root with metadata extraction
- [ ] Cancel running scan
- [ ] Exclude paths functionality
- [ ] Non-recursive scan
- [ ] Generate HTML report
- [ ] Export CSV
- [ ] Open file in Notepad (double-click)
- [ ] Open file from HTML link
- [ ] Context menu actions
- [ ] Open log file

### Error Handling Tests

- [ ] Access denied paths (continues, logs error)
- [ ] Non-existent path (shows error message)
- [ ] Network path offline (handles gracefully)
- [ ] Invalid archive structure (logs warning, empty metadata)
- [ ] Cancel during scan (clean termination)

### UI Tests

- [ ] Form resizes properly
- [ ] Progress bar animates during scan
- [ ] Status label updates
- [ ] Grid columns sortable
- [ ] Splitter between grid and report works

---

## Performance Considerations

| Scenario | Expected Behavior |
|----------|-------------------|
| <1,000 files | Instant completion |
| 1,000-10,000 files | 5-30 seconds |
| 10,000-100,000 files | 1-10 minutes |
| >100,000 files | Consider exclusion paths |

### Memory Usage
- Each result object: ~500 bytes
- 100,000 files ≈ 50 MB memory
- ArrayList grows dynamically

### Optimization Tips
1. Use exclusion paths for known non-target directories
2. Disable recursion if not needed
3. Scan specific subdirectories rather than entire drives
4. Close and reopen between large scans to clear memory

---

## Deployment Notes

### Prerequisites Check
```powershell
# Verify PowerShell version
$PSVersionTable.PSVersion  # Should be 5.1.x

# Verify .NET Framework
(Get-ItemProperty "HKLM:\SOFTWARE\Microsoft\NET Framework Setup\NDP\v4\Full").Release
# Should be >= 378389 (4.5)
```

### Execution Policy
```powershell
# Check current policy
Get-ExecutionPolicy

# Set for current user (no admin required)
Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser

# Or bypass for single execution
powershell -ExecutionPolicy Bypass -File .\VBSScannerGUI.ps1
```

### Network Considerations
- Ensure firewall allows SMB (ports 445, 139) for UNC access
- For cross-domain access, use explicit credentials or mapped drives
- VPN may be required for remote site access

---

## Common Modifications

### Change Target Extension
```powershell
# In Start-VbsScan function, modify:
if ($Item.Extension -ieq ".vbs")
# To:
if ($Item.Extension -ieq ".ps1")  # or other extension
```

### Add Additional Metadata Fields
```powershell
# 1. Extend result object in Start-VbsScan
$FileInfo = [PSCustomObject]@{
    # ... existing fields ...
    NewField = $SomeValue
}

# 2. Add column in Build-MainForm
$ColNewField = New-Object System.Windows.Forms.DataGridViewTextBoxColumn
$ColNewField.Name = "NewField"
$ColNewField.HeaderText = "New Field"
$null = $DataGridView.Columns.Add($ColNewField)

# 3. Update grid row addition
$null = $DataGrid.Rows.Add(..., $NewValue, ...)

# 4. Update HTML table headers and rows in New-HtmlReport
```

### Modify Archive Structure Parsing
```powershell
# In Get-ArchiveMetadataFromPath, adjust segment indices:
$Result.PackageName = $Segments[1]  # Change index as needed
$Result.Version = $Segments[2]
$Result.Build = $Segments[4]
```

---

## Troubleshooting Development Issues

| Issue | Cause | Fix |
|-------|-------|-----|
| "Cannot convert to DataGridViewColumn" | Using AddRange with array | Add columns individually with .Add() |
| "There is no Runspace" | BackgroundWorker with PS functions | Use DoEvents() pattern instead |
| Form not responding | Long operation in UI thread | Add DoEvents() calls in loops |
| Log file locked | Multiple access attempts | Retry logic with delays |
| HTML links not working | Navigation not intercepted | Check Navigating event handler |

---

## Contact & Support

For questions about this implementation:
- Review the CMTRACE log for detailed operation history
- Check the HTML report for scan results
- Refer to the documentation for user guidance

---

*Working Notes Version: 2.0.0 | Last Updated: March 23, 2026*
