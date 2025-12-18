# Simple test script to verify Azure VM extension execution
# This script creates multiple test files to confirm it's running

Write-Host "TEST SCRIPT STARTING..." -ForegroundColor Green
Write-Host "Current time: $(Get-Date)" -ForegroundColor Yellow

# Create multiple test locations to ensure we can write somewhere
$testLocations = @(
    "C:\temp\extension-test.txt",
    "C:\Windows\Temp\extension-test.txt",
    "C:\extension-test.txt"
)

foreach ($location in $testLocations) {
    try {
        # Create directory if needed
        $dir = Split-Path $location -Parent
        if (!(Test-Path $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }

        # Write test content
        "Azure VM Extension Test - $(Get-Date)" | Out-File -FilePath $location -Force
        Write-Host "SUCCESS: Created test file at $location" -ForegroundColor Green

        # Verify file exists and has content
        if (Test-Path $location) {
            $content = Get-Content $location
            Write-Host "VERIFIED: File has content: $content" -ForegroundColor Green
        }
    } catch {
        Write-Host "FAILED: Could not create $location - $_" -ForegroundColor Red
    }
}

Write-Host "TEST SCRIPT COMPLETED" -ForegroundColor Green