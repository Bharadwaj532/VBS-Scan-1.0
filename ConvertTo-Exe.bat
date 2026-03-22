@echo off
REM ============================================================================
REM VBS Scanner Utility - PS1 to EXE Converter
REM ============================================================================
REM This batch file converts the VBSScannerGUI.ps1 script into a standalone
REM executable (.exe) file using the PS2EXE module.
REM
REM Prerequisites:
REM   - PowerShell 5.1 or higher
REM   - Internet connection (for first-time PS2EXE installation)
REM   - Administrator rights may be needed for module installation
REM
REM Author: Enterprise Endpoint Engineering
REM Version: 1.0.0
REM Date: March 2026
REM ============================================================================

title VBS Scanner Utility - EXE Compiler
color 0A

echo.
echo ============================================================================
echo   VBS Scanner Utility - PS1 to EXE Converter
echo ============================================================================
echo.

REM Set variables
set "SCRIPT_DIR=%~dp0"
set "PS1_FILE=%SCRIPT_DIR%VBSScannerGUI.ps1"
set "EXE_FILE=%SCRIPT_DIR%VBSScannerGUI.exe"
set "ICON_FILE=%SCRIPT_DIR%VBSScanner.ico"

REM Check if source PS1 exists
if not exist "%PS1_FILE%" (
    echo [ERROR] Source file not found: %PS1_FILE%
    echo.
    echo Please ensure VBSScannerGUI.ps1 is in the same folder as this batch file.
    goto :ERROR
)

echo [INFO] Source file: %PS1_FILE%
echo [INFO] Output file: %EXE_FILE%
echo.

REM Check if PS2EXE module is installed
echo [STEP 1/4] Checking for PS2EXE module...
powershell -NoProfile -ExecutionPolicy Bypass -Command "if (Get-Module -ListAvailable -Name ps2exe) { exit 0 } else { exit 1 }"

if %ERRORLEVEL% NEQ 0 (
    echo [INFO] PS2EXE module not found. Installing...
    echo.
    
    REM Try to install PS2EXE
    powershell -NoProfile -ExecutionPolicy Bypass -Command "Install-Module -Name ps2exe -Scope CurrentUser -Force -AllowClobber"
    
    if %ERRORLEVEL% NEQ 0 (
        echo [ERROR] Failed to install PS2EXE module.
        echo.
        echo Please run the following command manually in PowerShell as Administrator:
        echo   Install-Module -Name ps2exe -Scope CurrentUser -Force
        echo.
        goto :ERROR
    )
    echo [SUCCESS] PS2EXE module installed successfully.
) else (
    echo [SUCCESS] PS2EXE module is already installed.
)

echo.
echo [STEP 2/4] Preparing compilation parameters...

REM Build the PS2EXE command
set "PS2EXE_CMD=Invoke-PS2EXE"
set "PS2EXE_PARAMS=-InputFile '%PS1_FILE%' -OutputFile '%EXE_FILE%'"
set "PS2EXE_PARAMS=%PS2EXE_PARAMS% -NoConsole"
set "PS2EXE_PARAMS=%PS2EXE_PARAMS% -Title 'VBS Scanner Utility'"
set "PS2EXE_PARAMS=%PS2EXE_PARAMS% -Description 'Enterprise VBS File Scanner with GUI'"
set "PS2EXE_PARAMS=%PS2EXE_PARAMS% -Company 'Enterprise Endpoint Engineering'"
set "PS2EXE_PARAMS=%PS2EXE_PARAMS% -Product 'VBS Scanner Utility'"
set "PS2EXE_PARAMS=%PS2EXE_PARAMS% -Version '2.0.0.0'"
set "PS2EXE_PARAMS=%PS2EXE_PARAMS% -Copyright 'Copyright 2026'"
set "PS2EXE_PARAMS=%PS2EXE_PARAMS% -RequireAdmin:$false"
set "PS2EXE_PARAMS=%PS2EXE_PARAMS% -STA"

REM Add icon if it exists
if exist "%ICON_FILE%" (
    echo [INFO] Icon file found: %ICON_FILE%
    set "PS2EXE_PARAMS=%PS2EXE_PARAMS% -IconFile '%ICON_FILE%'"
) else (
    echo [INFO] No custom icon file found. Using default icon.
)

echo.
echo [STEP 3/4] Compiling PowerShell script to EXE...
echo.

REM Run the compilation
powershell -NoProfile -ExecutionPolicy Bypass -Command "%PS2EXE_CMD% %PS2EXE_PARAMS%"

if %ERRORLEVEL% NEQ 0 (
    echo.
    echo [ERROR] Compilation failed with error code: %ERRORLEVEL%
    goto :ERROR
)

echo.
echo [STEP 4/4] Verifying output...

if exist "%EXE_FILE%" (
    echo.
    echo ============================================================================
    echo   COMPILATION SUCCESSFUL!
    echo ============================================================================
    echo.
    echo   Output file: %EXE_FILE%
    echo.
    for %%A in ("%EXE_FILE%") do echo   File size: %%~zA bytes
    echo.
    echo   You can now distribute the EXE file without requiring PowerShell
    echo   script execution policies on target machines.
    echo.
    echo ============================================================================
    echo.
    
    REM Ask if user wants to run the EXE
    set /p RUNEXE="Do you want to run the compiled EXE now? (Y/N): "
    if /i "%RUNEXE%"=="Y" (
        echo.
        echo [INFO] Starting VBSScannerGUI.exe...
        start "" "%EXE_FILE%"
    )
) else (
    echo [ERROR] Output file was not created.
    goto :ERROR
)

goto :END

:ERROR
echo.
echo ============================================================================
echo   COMPILATION FAILED
echo ============================================================================
echo.
echo   Please check the error messages above and try again.
echo.
echo   Common solutions:
echo   1. Run this batch file as Administrator
echo   2. Ensure you have internet access for module installation
echo   3. Check that antivirus is not blocking the operation
echo   4. Try running: Install-Module ps2exe -Force -Scope CurrentUser
echo.
echo ============================================================================
pause
exit /b 1

:END
echo.
echo Press any key to exit...
pause >nul
exit /b 0
