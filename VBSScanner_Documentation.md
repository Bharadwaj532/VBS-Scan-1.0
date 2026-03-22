# VBS Scanner Utility v2.0.0

## Product Documentation

---

## Table of Contents

1. [Overview](#overview)
2. [System Requirements](#system-requirements)
3. [Installation](#installation)
4. [Features](#features)
5. [User Interface Guide](#user-interface-guide)
6. [Scan Entry Types](#scan-entry-types)
7. [Archive Root Structure](#archive-root-structure)
8. [Output Files](#output-files)
9. [CMTRACE Log Format](#cmtrace-log-format)
10. [Troubleshooting](#troubleshooting)
11. [Known Limitations](#known-limitations)
12. [Version History](#version-history)

---

## Overview

The **VBS Scanner Utility** is an enterprise-grade PowerShell WinForms application designed to scan local devices, network shares, and structured archive repositories for VBScript (.vbs) files. It provides real-time scanning progress, detailed metadata extraction, comprehensive HTML reporting, and CMTRACE-compatible logging for enterprise environments.

### Key Capabilities

- Scan local paths, remote devices, UNC shares, and structured archives
- Extract package metadata from archive-structured paths
- Generate professional HTML reports with interactive features
- Export results to CSV for further analysis
- CMTRACE-compatible logging for SCCM/ConfigMgr integration
- Responsive GUI that remains interactive during scans
- Open files directly in Notepad from results grid or HTML report

---

## System Requirements

| Component | Requirement |
|-----------|-------------|
| Operating System | Windows 10/11, Windows Server 2016+ |
| PowerShell | Version 5.1 (included with Windows) |
| .NET Framework | 4.5 or higher |
| Memory | 4 GB RAM minimum (8 GB recommended for large scans) |
| Disk Space | 50 MB for application + space for logs/reports |
| Network | Required for UNC/Archive scans |
| Permissions | Read access to scan targets; Admin share access for device scans |

---

## Installation

### Standard Installation

1. Copy `VBSScannerGUI.ps1` to a local folder (e.g., `C:\Tools\VBSScanner\`)
2. Ensure PowerShell execution policy allows script execution:
   ```powershell
   Set-ExecutionPolicy -ExecutionPolicy RemoteSigned -Scope CurrentUser
   ```
3. Run the script:
   ```powershell
   .\VBSScannerGUI.ps1
   ```

### EXE Deployment

Use the provided `ConvertTo-Exe.bat` to create a standalone executable for deployment without requiring direct PowerShell access.

---

## Features

### Core Features

| Feature | Description |
|---------|-------------|
| Multi-Source Scanning | Scan local paths, device admin shares, UNC paths, or structured archives |
| Recursive Scanning | Traverse all subdirectories (configurable) |
| Exclusion Paths | Skip specified directories during scan |
| Real-Time Progress | Live file/directory counts with responsive UI |
| Cancel Support | Abort running scans gracefully |
| Archive Metadata | Extract PackageName, Version, Build from structured paths |

### Reporting Features

| Feature | Description |
|---------|-------------|
| HTML Reports | Professional, styled reports with summary statistics |
| CSV Export | Export all results with full metadata for Excel analysis |
| Interactive Links | Click file paths in HTML to open in Notepad |
| Package Summary | Grouped file counts by package (Archive scans) |

### Enterprise Features

| Feature | Description |
|---------|-------------|
| CMTRACE Logging | Full compatibility with Configuration Manager log viewer |
| Error Handling | Graceful handling of access denied and offline paths |
| Column Sorting | Reorder and sort results in the grid |
| Context Menu | Right-click actions for files |

---

## User Interface Guide

### Main Window Layout

```
┌─────────────────────────────────────────────────────────────────────┐
│ VBS Scanner Utility v2.0.0                                    [_][□][X] │
├─────────────────────────────────────────────────────────────────────┤
│ ┌─ Scan Target ──────────────────┐ ┌─ Options ─────────────────────┐ │
│ │ ○ Device/Path: [____________]  │ │ ☑ Recurse subdirectories      │ │
│ │ ○ UNC Path:    [____________]  │ │ Exclude paths: [___________]  │ │
│ │ ○ Archive Root:[____________]  │ │ Archive structure: \\...      │ │
│ └────────────────────────────────┘ └────────────────────────────────┘ │
│ Output Folder: [_________________________________] [Browse...]        │
│ [Scan] [Cancel] [Generate Report] [Open Log] [Export CSV] [===] Ready │
├─────────────────────────────────────────────────────────────────────┤
│ File Name │ Full Path │ Parent │ Package │ Version │ Build │ Date │ Size │
│───────────┼───────────┼────────┼─────────┼─────────┼───────┼──────┼──────│
│ script.vbs│ C:\...    │ C:\... │ Office  │ 16.0    │ 2024.1│ ...  │ 1024 │
├─────────────────────────────────────────────────────────────────────┤
│ HTML Report Preview:                                                 │
│ ┌─────────────────────────────────────────────────────────────────┐ │
│ │                    [Embedded HTML Report]                        │ │
│ └─────────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────────────┘
```

### Control Descriptions

| Control | Description |
|---------|-------------|
| **Device/Path** | Enter local path (C:\folder) or device name (PC-123 → scans \\PC-123\C$) |
| **UNC Path** | Enter full UNC path (\\server\share\folder) |
| **Archive Root** | Enter archive base path for metadata extraction |
| **Recurse** | When checked, scans all subdirectories |
| **Exclude Paths** | Semicolon-separated paths to skip |
| **Output Folder** | Location for log files and HTML reports |
| **Scan** | Start the scanning operation |
| **Cancel** | Stop a running scan |
| **Generate Report** | Create HTML report from current results |
| **Open Log** | Open the CMTRACE log file in Notepad |
| **Export CSV** | Save results to CSV file |

---

## Scan Entry Types

### 1. Device/Local Path

**Use Case:** Scanning local folders or remote device admin shares

**Input Examples:**
- `C:\Scripts` - Scans local folder
- `D:\Automation\VBS` - Scans specific local path
- `PC-WORKSTATION01` - Converts to `\\PC-WORKSTATION01\C$`

**Requirements:** 
- Local paths: Read access
- Device names: Administrative share access (admin rights)

### 2. UNC Path

**Use Case:** Scanning network shares without metadata extraction

**Input Examples:**
- `\\fileserver\shared\scripts`
- `\\nas01\archive\legacy`

**Requirements:** Read access to the network share

### 3. Archive Root (Structured)

**Use Case:** Scanning software packaging archives with automatic metadata extraction

**Input Example:** `\\pkgserver\packages`

**Requirements:** 
- Read access to archive
- Files must follow the expected folder structure

---

## Archive Root Structure

When using Archive Root scanning, the tool extracts metadata from the folder structure:

```
\\Server\Archive\
    └── Vendor\
        └── PackageName\
            └── Version\
                └── Type\
                    └── Build\
                        └── files.vbs
```

### Path Segment Mapping

| Position | Segment | Example |
|----------|---------|---------|
| 0 | Vendor | Microsoft |
| 1 | **PackageName** | Office |
| 2 | **Version** | 16.0.14326 |
| 3 | Type | MSI |
| 4 | **Build** | 2024.01.15 |
| 5+ | Subfolders/Files | Scripts\install.vbs |

### Example Path Parsing

**Full Path:** `\\pkgserver\packages\Microsoft\Office\16.0.14326\MSI\2024.01.15\Scripts\install.vbs`

**Extracted Metadata:**
- PackageName: `Office`
- Version: `16.0.14326`
- Build: `2024.01.15`

### Non-Matching Paths

If a file path doesn't match the expected structure (fewer than 5 segments after archive root):
- Metadata fields are left empty
- A warning is logged for investigation
- The file is still included in results

---

## Output Files

### Log File

**Naming:** `VBSScanner_YYYYMMDD_HHMMSS.log`

**Location:** Selected output folder

**Format:** CMTRACE-compatible XML-style entries

### HTML Report

**Naming:** `VBSScanner_Report_YYYYMMDD_HHMMSS.html`

**Contents:**
- Summary cards (files found, total size, errors, duration)
- Scan configuration details
- Package summary table (Archive scans only)
- Detailed file listing with all metadata
- Clickable file paths (opens in Notepad within application)

### CSV Export

**Naming:** User-specified (default: `VBSScanner_Results_YYYYMMDD_HHMMSS.csv`)

**Columns:**
- FileName
- FullPath
- ParentFolder
- PackageName
- Version
- Build
- LastWriteTime
- SizeBytes

---

## CMTRACE Log Format

Log entries are formatted for compatibility with CMTRACE.exe / CMLogViewer:

```xml
<![LOG[Message text here]LOG]!><time="HH:mm:ss.fff+TZOffset" date="MM-DD-YYYY" component="ComponentName" context="" type="Severity" thread="ThreadID" file="VBSScanner">
```

### Severity Levels

| Level | Type | Description |
|-------|------|-------------|
| 1 | Information | Normal operational messages |
| 2 | Warning | Non-critical issues (access denied, structure mismatch) |
| 3 | Error | Critical failures requiring attention |

### Logged Events

- Application start/stop
- Scan parameters and entry type
- Each discovered .vbs file with metadata
- Access denied errors
- Path structure warnings
- Report generation
- Export operations

---

## Troubleshooting

### Common Issues

| Issue | Cause | Solution |
|-------|-------|----------|
| "Cannot access scan root" | Permission denied or path doesn't exist | Verify path and ensure read access |
| Empty Package/Version/Build | Path doesn't match archive structure | Check folder structure matches expected format |
| Scan runs slowly | Large directory with many files | Use exclusion paths to skip unnecessary folders |
| "Access denied" in log | Insufficient permissions | Run with appropriate credentials or exclude protected paths |
| UI freezes briefly | Very large single directory | Expected behavior during folder enumeration |

### Diagnostic Steps

1. **Check the log file** - Open Log button shows detailed operation history
2. **Verify network connectivity** - Test UNC path access in File Explorer
3. **Confirm permissions** - Ensure account has read access to scan targets
4. **Review exclusions** - Ensure important paths aren't being skipped

---

## Known Limitations

1. **Single Scan Root:** Only one root path can be scanned per operation
2. **No Wildcard Patterns:** Extension filter is fixed to .vbs
3. **Reparse Points Skipped:** Junction points and symlinks are not followed
4. **Metadata Extraction:** Only available for Archive Root entry type
5. **HTML Links:** File links only work within the embedded WebBrowser control
6. **Large Scans:** Memory usage increases with number of results

---

## Version History

### Version 2.0.0 (March 2026)
- **NEW:** Archive Root entry type with metadata extraction
- **NEW:** PackageName, Version, Build columns in results
- **NEW:** Package summary in HTML reports
- **NEW:** Archive structure parsing with warning for non-matching paths
- **IMPROVED:** Expanded form layout for additional columns
- **IMPROVED:** CSV export includes all metadata fields

### Version 1.0.0 (March 2026)
- Initial release
- Device/Path and UNC scanning
- HTML report generation
- CMTRACE-compatible logging
- CSV export
- Responsive WinForms GUI

---

## Support

For issues or enhancement requests, contact the Enterprise Endpoint Engineering team.

**Log files and screenshots of issues greatly assist troubleshooting.**

---

*Document Version: 2.0.0 | Last Updated: March 23, 2026*
