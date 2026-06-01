$errors = $null
$null = [System.Management.Automation.Language.Parser]::ParseFile(
    'c:\Users\skothalanka\Documents\bharat\3.0\VBSScannerGUI.ps1',
    [ref]$null,
    [ref]$errors
)
if ($errors.Count -eq 0) {
    Write-Host 'PARSE OK'
} else {
    foreach ($e in $errors) {
        Write-Host "ERROR line $($e.Extent.StartLineNumber): $($e.Message)"
    }
}
