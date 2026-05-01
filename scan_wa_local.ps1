param (
    [string]$SupabaseUrl = "",
    [string]$SupabaseKey = ""
)

if ($SupabaseUrl -eq "" -or $SupabaseKey -eq "") {
    Write-Host "WARNING: Harap masukkan Supabase URL dan Key!" -ForegroundColor Yellow
    exit
}

Write-Host "Menyiapkan Local WhatsApp Scanner..." -ForegroundColor Cyan

Set-Location $PSScriptRoot

if (Test-Path "venv\Scripts\activate.ps1") {
    . ".\venv\Scripts\activate.ps1"
    Write-Host "Python VENV diaktifkan." -ForegroundColor Green
}

Write-Host "Menginstal dependensi Python (termasuk supabase)..." -ForegroundColor Cyan
pip install -e .

$env:SUPABASE_URL = $SupabaseUrl
$env:SUPABASE_SERVICE_ROLE_KEY = $SupabaseKey
$env:BRIDGE_TOKEN = "local-scan-only"

Set-Location "$PSScriptRoot\bridge"
Write-Host "Build WhatsApp Bridge..." -ForegroundColor Cyan
npm install
npm run build

Write-Host "MULAI SCANNER WHATSAPP..." -ForegroundColor Green
Write-Host "Tunggu sampai muncul QR code/link. Scan pakai HP."
Write-Host "Jika sudah 'Connected to WhatsApp', tekan CTRL+C untuk stop." -ForegroundColor Yellow

node dist/index.js

Set-Location $PSScriptRoot
Write-Host "MENGUNGGAH SESSION KE SUPABASE..." -ForegroundColor Cyan
python -m nanobot.supabase_sync backup

Write-Host "SELESAI! Session tersimpan di Supabase." -ForegroundColor Green
