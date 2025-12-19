# Debug the certificate signing issue

Run this on Windows as Administrator:

PowerShell -ExecutionPolicy Bypass -File host/driver/winApiRemoting/debug_cert_signing.ps1

This script will:
1. Check existing certificates or create a new one
2. Verify certificate installation in both My and Root stores  
3. Show detailed signtool output (no error hiding)
4. Test certificate accessibility
5. Create catalog file if missing
6. Attempt signing with full error messages

The script will reveal the exact reason why catalog signing is failing.
