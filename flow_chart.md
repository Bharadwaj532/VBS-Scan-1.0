1. Severity Levels - Definition Basis

   1. Severity Levels - Definition Basis
Severity	Assigned When	Rationale
High	VBScript CustomAction types (6, 22, 38, 54) detected in MSI	These are native VBScript execution points that Windows Installer runs directly - highest remediation priority
High	Active Setup StubPath contains cscript/wscript/.vbs	Active Setup runs per-user at logon with script host invocation - security concern
Warning	CustomAction Target field contains script indicators	CA executes external script via command line - indirect VBS usage
Warning	Binary stream contains VBScript markers (WScript., CreateObject)	Embedded script content that may execute - needs review
Info	Active Setup StubPath exists (without script indicators)	Awareness only - may not involve VBScript
Info	MST contains VBS-related strings	String presence doesn't confirm execution - informational

2. Error Identification

VBS File Scanning Errors
Errors are caught in the Start-VbsScan function:



catch [System.UnauthorizedAccessException] {
    $Script:ErrorCount++
    Write-CMTraceLog -Message "Access denied: $CurrentPath" -Severity 3
}
catch [System.IO.DirectoryNotFoundException] {
    $Script:ErrorCount++
    Write-CMTraceLog -Message "Directory not found: $CurrentPath" -Severity 3
}
catch {
    $Script:ErrorCount++
    Write-CMTraceLog -Message "Error scanning $CurrentPath - $($_.Exception.Message)" -Severity 3
}


MSI/MST Scanning Errors
Errors tracked via $Script:MsiErrorCount:

Error Type	Where Caught
Cannot open MSI database	Scan-MsiFile - COM exception when OpenDatabase() fails
Table query failures	Find-VBScriptCustomActions, Find-ActiveSetupIndicators - SQL view exceptions
Binary extraction failures	Find-BinaryScriptContent - stream read errors
File read failures	Scan-MstFile - ReadAllBytes exceptions
Directory access denied	Start-MsiMstScan - UnauthorizedAccessException

All errors are:

Incremented in the appropriate counter ($Script:ErrorCount or $Script:MsiErrorCount)
Logged to CMTRACE with Severity 3 (Error)
Displayed in final status bar count
Included in HTML report summary
===================================================================




Here are the flowchart diagrams for both scanning processes:

1. VBS File Scanning Flow

2. MSI/MST Scanning Flow

   
flowchart TD
    subgraph INIT["Initialization"]
        A[Start MSI/MST Scan] --> B[Clear MsiScanResults]
        B --> C[Set Counters to 0<br/>MsiErrorCount, MsiFilesScanned,<br/>MsiFilesWithFindings]
        C --> D[Clear DataGridView rows]
        D --> E{Build Extension List}
        E --> F{ScanMsi checked?}
        F -->|Yes| G[Add .msi to list]
        F -->|No| H{ScanMst checked?}
        G --> H
        H -->|Yes| I[Add .mst to list]
        H -->|No| J{Extensions<br/>empty?}
        I --> J
        J -->|Yes| K[Status: No file types selected]
        K --> L[Return FALSE]
    end

    subgraph VALIDATE["Path Validation"]
        J -->|No| M{Test-PathAccessible<br/>ScanRoot}
        M -->|No| N[Log Error]
        N --> O[StatusLabel = Error]
        O --> P[Return FALSE]
        M -->|Yes| Q[Log scan parameters]
    end

    subgraph DIRSCAN["Directory Traversal"]
        Q --> R[Set ProgressBar = Marquee]
        R --> S[Create Directory Queue]
        S --> T[Add ScanRoot to Queue]
        T --> U{Queue has items?}
        U -->|No| COMPLETE
        U -->|Yes| V{ScanCancelled?}
        V -->|Yes| CANCEL
        V -->|No| W[Dequeue CurrentPath]
        W --> X{Path Excluded?}
        X -->|Yes| U
        X -->|No| Y{UI Update needed?}
        Y -->|Yes| Z[Update StatusLabel with counts]
        Z --> AA[DoEvents]
        Y -->|No| AB[Get-ChildItem]
        AA --> AB
    end

    subgraph PROCESS["Process Directory Items"]
        AB --> AC{Success?}
        AC -->|No - Access Denied| AD[MsiErrorCount++<br/>Log error]
        AC -->|No - Other| AE[MsiErrorCount++<br/>Log error]
        AD --> U
        AE --> U
        AC -->|Yes| AF[Loop Items]
    end

    subgraph ITEMS["File Processing"]
        AF --> AG{More items?}
        AG -->|No| U
        AG -->|Yes| AH{ScanCancelled?}
        AH -->|Yes| CANCEL
        AH -->|No| AI{Is Directory?}
        AI -->|Yes| AJ{Recurse AND<br/>not ReparsePoint?}
        AJ -->|Yes| AK[Add to Queue]
        AJ -->|No| AG
        AK --> AG
        AI -->|No| AL{Extension in<br/>scan list?}
        AL -->|No| AG
        AL -->|Yes| AM[MsiFilesScanned++]
        AM --> AN{Extension type?}
    end

    subgraph MSISCAN["Scan MSI File"]
        AN -->|.msi| AO[Call Scan-MsiFile]
        AO --> AP[Create COM:<br/>WindowsInstaller.Installer]
        AP --> AQ[OpenDatabase readonly]
        AQ --> AR{Success?}
        AR -->|No| AS[MsiErrorCount++<br/>Log error]
        AS --> BA
        AR -->|Yes| AT[Get-MsiProductInfo<br/>Query Property table]
        AT --> AU[Extract ProductName,<br/>ProductVersion, ProductCode]
    end

    subgraph CADETECT["CustomAction Detection"]
        AU --> AV[Find-VBScriptCustomActions]
        AV --> AW[Query CustomAction table]
        AW --> AX{For each CA record}
        AX --> AY{Type in<br/>6,22,38,54?}
        AY -->|Yes| AZ[Create Finding:<br/>VBScriptCustomAction<br/>Severity: HIGH]
        AY -->|No| AAA{Target contains<br/>script indicators?}
        AAA -->|Yes| AAB[Create Finding:<br/>ScriptHostInvocation<br/>Severity: WARNING]
        AAA -->|No| AX
        AZ --> AX
        AAB --> AX
    end

    subgraph ASDETECT["Active Setup Detection"]
        AX -->|Done| AAC{DetectActiveSetup<br/>enabled?}
        AAC -->|No| AAD
        AAC -->|Yes| AAE[Find-ActiveSetupIndicators]
        AAE --> AAF[Query Registry table]
        AAF --> AAG{Key matches<br/>Active Setup pattern?}
        AAG -->|Yes| AAH{StubPath contains<br/>script indicators?}
        AAH -->|Yes| AAI[Create Finding:<br/>ActiveSetupStubPath<br/>Severity: HIGH]
        AAH -->|No| AAJ[Create Finding:<br/>Severity: INFO]
        AAG -->|No| AAD
        AAI --> AAD
        AAJ --> AAD
    end

    subgraph BINARYDEEP["Deep Binary Scan"]
        AAD{DeepScanBinary<br/>enabled?}
        AAD -->|No| BA
        AAD -->|Yes| AAK[Find-BinaryScriptContent]
        AAK --> AAL[Query Binary table]
        AAL --> AAM{For each Binary}
        AAM --> AAN[Extract to temp file]
        AAN --> AAO[Read as UTF8/ASCII]
        AAO --> AAP{Contains markers?<br/>WScript. CreateObject<br/>Scripting.FSO etc}
        AAP -->|Yes| AAQ[Create Finding:<br/>EmbeddedScriptText<br/>Severity: WARNING]
        AAP -->|No| AAM
        AAQ --> AAM
        AAM -->|Done| AAR[Delete temp files]
        AAR --> BA
    end

    subgraph MSTSCAN["Scan MST File"]
        AN -->|.mst| AAS[Call Scan-MstFile]
        AAS --> AAT[ReadAllBytes]
        AAT --> AAU{File < 10MB?}
        AAU -->|No| AAV[Log: Too large]
        AAV --> BA
        AAU -->|Yes| AAW[Decode as Unicode/ASCII]
        AAW --> AAX{Contains indicators?<br/>cscript wscript .vbs<br/>Active Setup StubPath}
        AAX -->|Yes| AAY[Create Finding:<br/>TransformStringIndicator<br/>Severity: INFO]
        AAX -->|No| BA
        AAY --> BA
    end

    subgraph ADDRESULTS["Add Results"]
        BA[Release COM objects] --> BB{Findings count > 0?}
        BB -->|Yes| BC[MsiFilesWithFindings++]
        BC --> BD[Add findings to MsiScanResults]
        BD --> BE[Add rows to DataGridView<br/>with severity colors]
        BE --> AG
        BB -->|No| AG
    end

    subgraph CANCEL["Cancellation"]
        CANCEL[Log: Cancelled] --> BF[StatusLabel = Cancelled]
        BF --> BG[ProgressBar = Continuous]
        BG --> BH[Return FALSE]
    end

    subgraph COMPLETE["Completion"]
        COMPLETE[ProgressBar = Continuous] --> BI[ProgressBar.Value = 100]
        BI --> BJ[Log: Scan complete<br/>Files, Findings, Errors]
        BJ --> BK[Return TRUE]
    end

    style INIT fill:#e1f5fe
    style VALIDATE fill:#fff3e0
    style DIRSCAN fill:#f3e5f5
    style PROCESS fill:#ffebee
    style ITEMS fill:#e8f5e9
    style MSISCAN fill:#e3f2fd
    style CADETECT fill:#fce4ec
    style ASDETECT fill:#f3e5f5
    style BINARYDEEP fill:#fff8e1
    style MSTSCAN fill:#e0f2f1
    style ADDRESULTS fill:#f1f8e9
    style CANCEL fill:#ffcdd2
    style COMPLETE fill:#c8e6c9

Summary Legend
Color	Stage Type
Light Blue	Initialization
Light Orange	Validation
Light Purple	Main Loop
Light Red	Error Handling
Light Green	Item Processing
Light Yellow	Detection Logic
Light Teal	MST Processing
Green	Completion
Red	Cancellation

    
