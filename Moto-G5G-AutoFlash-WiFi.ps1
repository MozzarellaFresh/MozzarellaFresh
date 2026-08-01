#############################################
# Moto G 5G (2022) Austin - Automated Flash Script
# Device: XT2213-3 (RETUS, Unlocked)
# Bootloader: MBM-2.1-austin_g-61c726540b-250415
# Target Build: T1SAS33.73-40-0-12-20
#
# Functions:
# 1. Configure WiFi proxy (10.60.69.208:8387)
# 2. Scan RSA firmware cache for matching firmware
# 3. Extract boot.img and vbmeta.img selectively
# 4. Validate OrangeFox recovery image
# 5. Monitor ADB/Fastboot connection over WiFi
# 6. Flash OrangeFox recovery to vendor_boot
#############################################

param(
    [string]$ProxyServer = "10.60.69.208:8387",
    [string]$WorkingDir = "$env:USERPROFILE\MotoG5G_Flash",
    [string]$FirmwareSearchPattern = "*XT2213-3_AUSTIN_RETUS_13_T1SAS33.73*",
    [string]$OrangeFoxFile = "orangefox.img",
    [string]$DeviceIPAddress = "",
    [int]$ADBPort = 5555,
    [int]$FastbootTimeoutSeconds = 120,
    [int]$FastbootPollIntervalMs = 2000,
    [string]$PlatformToolsPath = "C:\MotoDev\platform-tools",
    [string]$ManualFirmwarePath = "",
    [int]$DownloadRetryCount = 3,
    [int]$DownloadTimeoutSeconds = 300,
    [switch]$SkipProxyConfig,
    [switch]$SkipFirmwareDownload,
    [switch]$SkipMagiskDownload,
    [switch]$SkipOrangeFoxDownload
)

# ============================================
# CONFIGURATION & CONSTANTS
# ============================================

$RSA_FIRMWARE_PATH = "C:\ProgramData\RSA\Download\RomFiles"
$TIMESTAMP = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LOG_FILE = "$WorkingDir\flash_log_$TIMESTAMP.txt"
$EXTRACTION_DIR = "$WorkingDir\extracted_firmware"
$DOWNLOADS_DIR = "$WorkingDir\downloads"
$BOOT_IMG = "boot.img"
$VBMETA_IMG = "vbmeta.img"

# Proxy configuration
$PROXY_SERVER = $ProxyServer
$PROXY_USERNAME = $null
$PROXY_PASSWORD = $null

# ADB / Fastboot tool paths
$ADB_EXE    = if ($PlatformToolsPath) { Join-Path $PlatformToolsPath "adb.exe" }    else { "adb" }
$FASTBOOT_EXE = if ($PlatformToolsPath) { Join-Path $PlatformToolsPath "fastboot.exe" } else { "fastboot" }

# Firmware download sources (tried in order)
$FIRMWARE_BUILD    = "T1SAS33.73-40-0-12-20"
$FIRMWARE_FILENAME = "XT2213-3_AUSTIN_RETUS_13_$($FIRMWARE_BUILD).zip"

$FIRMWARE_SOURCES = @(
    # 1 — Primary: lolinet mirror
    "https://mirrors.lolinet.com/firmware/motorola/austin/official/RETUS/$FIRMWARE_FILENAME",
    # 2 — Secondary: Motorola Software Center (direct)
    "https://softwarecenter.motorola.com/api/firmware/link/msi/$FIRMWARE_FILENAME",
    # 3 — Tertiary: Community XDA mirror placeholder (update with actual link if available)
    "https://dl.xda-cdn.com/motorola/austin/$FIRMWARE_FILENAME"
)

# GitHub API endpoints for companion downloads
$MAGISK_API_URL    = "https://api.github.com/repos/topjohnwu/Magisk/releases/latest"
$ORANGEFOX_API_URL = "https://api.github.com/repos/OrangeFox/Recovery/releases"
$ORANGEFOX_DEVICE  = "austin"

# Color codes for console output
$COLOR_INFO    = "Cyan"
$COLOR_SUCCESS = "Green"
$COLOR_WARNING = "Yellow"
$COLOR_ERROR   = "Red"

# ============================================
# LOGGING FUNCTIONS
# ============================================

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO",
        [string]$Color = $COLOR_INFO
    )
    
    $timestamp = Get-Date -Format "HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to console
    Write-Host $logMessage -ForegroundColor $Color
    
    # Write to file
    Add-Content -Path $LOG_FILE -Value $logMessage -ErrorAction SilentlyContinue
}

function Write-Section {
    param([string]$Title)
    Write-Host ""
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host $Title -ForegroundColor Cyan
    Write-Host "=" * 60 -ForegroundColor Cyan
    Write-Host ""
}

# ============================================
# PROXY CONFIGURATION
# ============================================

function Set-WifiProxy {
    param(
        [string]$ProxyAddress,
        [string]$ProxyUsername = $null,
        [string]$ProxyPassword = $null
    )
    
    Write-Section "Configuring WiFi Proxy"
    
    try {
        # Parse proxy server and port
        $proxyParts = $ProxyAddress -split ":"
        if ($proxyParts.Count -ne 2) {
            Write-Log "Invalid proxy format. Expected 'host:port', got: $ProxyAddress" "ERROR" $COLOR_ERROR
            return $false
        }
        
        $proxyHost = $proxyParts[0]
        $proxyPort = $proxyParts[1]
        
        Write-Log "Proxy Server: $proxyHost" "INFO" $COLOR_INFO
        Write-Log "Proxy Port: $proxyPort" "INFO" $COLOR_INFO
        
        # Configure system proxy using netsh
        Write-Log "Configuring WinHTTP proxy settings..." "INFO" $COLOR_INFO
        
        $cmd = "netsh winhttp set proxy proxy-server='$ProxyAddress' bypass-list='<local>'"
        Invoke-Expression $cmd | Out-Null
        
        Write-Log "WinHTTP proxy configured successfully" "SUCCESS" $COLOR_SUCCESS
        
        # Verify proxy configuration
        Write-Log "Verifying proxy configuration..." "INFO" $COLOR_INFO
        $proxyConfig = netsh winhttp show proxy
        Write-Log "Current proxy configuration:" "INFO" $COLOR_INFO
        $proxyConfig | ForEach-Object {
            Write-Log "  $_" "INFO" $COLOR_INFO
        }
        
        # Configure .NET proxy for PowerShell downloads
        $proxy = New-Object System.Net.WebProxy
        $proxy.Address = "http://$ProxyAddress"
        $proxy.BypassProxyOnLocal = $true
        
        if ($ProxyUsername -and $ProxyPassword) {
            Write-Log "Configuring proxy credentials..." "INFO" $COLOR_INFO
            $credentials = New-Object System.Net.NetworkCredential($ProxyUsername, $ProxyPassword)
            $proxy.Credentials = $credentials
            Write-Log "Proxy credentials set" "SUCCESS" $COLOR_SUCCESS
        }
        
        [System.Net.ServicePointManager]::DefaultWebProxy = $proxy
        
        Write-Log "Proxy configuration completed successfully" "SUCCESS" $COLOR_SUCCESS
        return $true
    }
    catch {
        Write-Log "Error configuring proxy: $_" "ERROR" $COLOR_ERROR
        return $false
    }
}

function Test-ProxyConnectivity {
    Write-Section "Testing Proxy Connectivity"
    
    try {
        # Test basic connectivity through proxy
        Write-Log "Testing connectivity through proxy: $PROXY_SERVER" "INFO" $COLOR_INFO
        
        $testUri = "http://www.google.com"
        Write-Log "Attempting connection to: $testUri" "INFO" $COLOR_INFO
        
        $request = [System.Net.HttpWebRequest]::Create($testUri)
        $request.Proxy = [System.Net.ServicePointManager]::DefaultWebProxy
        $request.Timeout = 10000
        
        $response = $request.GetResponse()
        if ($response.StatusCode -eq [System.Net.HttpStatusCode]::OK) {
            Write-Log "Proxy connectivity test PASSED" "SUCCESS" $COLOR_SUCCESS
            $response.Close()
            return $true
        }
    }
    catch {
        Write-Log "Proxy connectivity test FAILED: $_" "WARNING" $COLOR_WARNING
        Write-Log "Continuing anyway, but network operations may fail" "WARNING" $COLOR_WARNING
        return $false
    }
}

# ============================================
# DOWNLOAD FUNCTIONS (WITH RETRY & RESUME)
# ============================================

function Get-WebClientWithProxy {
    $wc = New-Object System.Net.WebClient
    if (-not $SkipProxyConfig -and $PROXY_SERVER) {
        $proxy = New-Object System.Net.WebProxy("http://$PROXY_SERVER")
        $proxy.BypassProxyOnLocal = $true
        $wc.Proxy = $proxy
    }
    $wc.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShell/7")
    return $wc
}

function Invoke-DownloadWithRetry {
    param(
        [string]$Url,
        [string]$Destination,
        [string]$Description = "file",
        [int]$RetryCount = $DownloadRetryCount,
        [int]$TimeoutSeconds = $DownloadTimeoutSeconds
    )

    Write-Log "Downloading $Description from: $Url" "INFO" $COLOR_INFO
    Write-Log "Destination: $Destination" "INFO" $COLOR_INFO

    $attempt = 0
    while ($attempt -lt $RetryCount) {
        $attempt++
        Write-Log "Attempt $attempt / $RetryCount ..." "INFO" $COLOR_INFO

        try {
            # Determine resume offset if a partial file exists
            $resumeOffset = 0
            if (Test-Path $Destination) {
                $resumeOffset = (Get-Item $Destination).Length
                Write-Log "Partial file detected ($([math]::Round($resumeOffset/1MB,1)) MB). Attempting resume..." "INFO" $COLOR_INFO
            }

            $req = [System.Net.HttpWebRequest]::Create($Url)
            $req.Timeout  = $TimeoutSeconds * 1000
            $req.Method   = "GET"
            $req.Headers.Add("User-Agent", "Mozilla/5.0 (Windows NT 10.0; Win64; x64) PowerShell/7")

            if (-not $SkipProxyConfig -and $PROXY_SERVER) {
                $req.Proxy = New-Object System.Net.WebProxy("http://$PROXY_SERVER")
                $req.Proxy.BypassProxyOnLocal = $true
            }

            if ($resumeOffset -gt 0) {
                $req.AddRange($resumeOffset)
            }

            $resp       = $req.GetResponse()
            $totalBytes = $resp.ContentLength
            $stream     = $resp.GetResponseStream()
            $fileMode   = if ($resumeOffset -gt 0) { [System.IO.FileMode]::Append } else { [System.IO.FileMode]::Create }
            $fileStream = [System.IO.FileStream]::new($Destination, $fileMode, [System.IO.FileAccess]::Write)

            $buffer       = New-Object byte[] 65536
            $bytesRead    = 0
            $totalWritten = $resumeOffset
            $lastReport   = 0

            while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                $fileStream.Write($buffer, 0, $bytesRead)
                $totalWritten += $bytesRead

                if ($totalBytes -gt 0) {
                    $pct = [math]::Round(($totalWritten / ($totalBytes + $resumeOffset)) * 100, 1)
                    if ($pct - $lastReport -ge 10) {
                        Write-Log "  Progress: $pct% ($([math]::Round($totalWritten/1MB,1)) / $([math]::Round(($totalBytes+$resumeOffset)/1MB,1)) MB)" "INFO" $COLOR_INFO
                        $lastReport = $pct
                    }
                }
            }

            $fileStream.Close()
            $stream.Close()
            $resp.Close()

            $finalSize = (Get-Item $Destination).Length
            Write-Log "$Description downloaded successfully ($([math]::Round($finalSize/1MB,1)) MB)" "SUCCESS" $COLOR_SUCCESS
            return $true
        }
        catch {
            Write-Log "Download attempt $attempt failed: $_" "WARNING" $COLOR_WARNING
            if ($null -ne $fileStream) { try { $fileStream.Close() } catch {} }
            if ($attempt -lt $RetryCount) {
                $wait = [math]::Pow(2, $attempt)
                Write-Log "Retrying in $wait seconds..." "INFO" $COLOR_INFO
                Start-Sleep -Seconds $wait
            }
        }
    }

    Write-Log "All $RetryCount download attempts failed for: $Url" "ERROR" $COLOR_ERROR
    return $false
}

function Download-FirmwareWithFallback {
    Write-Section "Downloading Motorola Firmware"

    if (-not (Test-Path $DOWNLOADS_DIR)) {
        New-Item -ItemType Directory -Path $DOWNLOADS_DIR -Force | Out-Null
    }

    $destPath = Join-Path $DOWNLOADS_DIR $FIRMWARE_FILENAME

    # Auto-detect: firmware already downloaded
    $existing = Find-ExistingFirmware
    if ($existing) {
        Write-Log "Firmware already present — skipping download." "SUCCESS" $COLOR_SUCCESS
        return $existing
    }

    foreach ($url in $FIRMWARE_SOURCES) {
        Write-Log "Trying source: $url" "INFO" $COLOR_INFO
        $ok = Invoke-DownloadWithRetry -Url $url -Destination $destPath -Description "Motorola firmware"
        if ($ok) { return $destPath }
        Write-Log "Source failed, trying next fallback..." "WARNING" $COLOR_WARNING
    }

    # All automated sources failed — prompt for manual path
    Write-Log "" "WARNING" $COLOR_WARNING
    Write-Log "All automated firmware sources failed." "ERROR" $COLOR_ERROR
    Write-Log "Options:" "WARNING" $COLOR_WARNING
    Write-Log "  1. Place the firmware ZIP manually in: $DOWNLOADS_DIR" "INFO" $COLOR_INFO
    Write-Log "     Expected filename: $FIRMWARE_FILENAME" "INFO" $COLOR_INFO
    Write-Log "  2. Re-run with -ManualFirmwarePath <path_to_zip>" "INFO" $COLOR_INFO
    Write-Log "  3. Re-run with -SkipFirmwareDownload to use RSA cache only" "INFO" $COLOR_INFO

    if ($ManualFirmwarePath -and (Test-Path $ManualFirmwarePath)) {
        Write-Log "Using manually specified firmware: $ManualFirmwarePath" "SUCCESS" $COLOR_SUCCESS
        return $ManualFirmwarePath
    }

    return $null
}

function Find-ExistingFirmware {
    # Check downloads dir first, then RSA cache
    $searchDirs = @($DOWNLOADS_DIR, $WorkingDir, $RSA_FIRMWARE_PATH)
    foreach ($dir in $searchDirs) {
        if (-not (Test-Path $dir)) { continue }
        $found = Get-ChildItem -Path $dir -Filter $FirmwareSearchPattern -ErrorAction SilentlyContinue |
                 Sort-Object LastWriteTime -Descending | Select-Object -First 1
        if ($found) {
            Write-Log "Found existing firmware: $($found.FullName)" "SUCCESS" $COLOR_SUCCESS
            return $found.FullName
        }
    }
    return $null
}

function Download-MagiskAPK {
    Write-Section "Downloading Magisk (Latest Release)"

    if (-not (Test-Path $DOWNLOADS_DIR)) {
        New-Item -ItemType Directory -Path $DOWNLOADS_DIR -Force | Out-Null
    }

    $destPath = Join-Path $DOWNLOADS_DIR "Magisk.apk"

    if (Test-Path $destPath) {
        Write-Log "Magisk APK already present: $destPath" "SUCCESS" $COLOR_SUCCESS
        return $destPath
    }

    try {
        Write-Log "Querying GitHub for latest Magisk release..." "INFO" $COLOR_INFO
        $wc = Get-WebClientWithProxy
        $releaseJson = $wc.DownloadString($MAGISK_API_URL) | ConvertFrom-Json

        $apkAsset = $releaseJson.assets | Where-Object { $_.name -match "Magisk-v.*\.apk$" } | Select-Object -First 1
        if (-not $apkAsset) {
            Write-Log "Could not locate Magisk APK asset in release." "ERROR" $COLOR_ERROR
            return $null
        }

        Write-Log "Magisk version: $($releaseJson.tag_name) — $($apkAsset.name)" "INFO" $COLOR_INFO
        $ok = Invoke-DownloadWithRetry -Url $apkAsset.browser_download_url -Destination $destPath -Description "Magisk APK"
        return if ($ok) { $destPath } else { $null }
    }
    catch {
        Write-Log "Error downloading Magisk: $_" "ERROR" $COLOR_ERROR
        return $null
    }
}

function Download-OrangeFoxRecovery {
    Write-Section "Downloading OrangeFox Recovery (austin)"

    if (-not (Test-Path $DOWNLOADS_DIR)) {
        New-Item -ItemType Directory -Path $DOWNLOADS_DIR -Force | Out-Null
    }

    $destPath = Join-Path $WorkingDir $OrangeFoxFile

    if (Test-Path $destPath) {
        Write-Log "OrangeFox image already present: $destPath" "SUCCESS" $COLOR_SUCCESS
        return $destPath
    }

    try {
        Write-Log "Querying OrangeFox releases API for device: $ORANGEFOX_DEVICE ..." "INFO" $COLOR_INFO
        $wc = Get-WebClientWithProxy
        $releasesJson = $wc.DownloadString($ORANGEFOX_API_URL) | ConvertFrom-Json

        # Find a release that contains an asset for our device
        $imgAsset = $null
        foreach ($release in $releasesJson) {
            $imgAsset = $release.assets | Where-Object {
                $_.name -match "OrangeFox.*$ORANGEFOX_DEVICE.*\.(img|zip)$"
            } | Select-Object -First 1
            if ($imgAsset) {
                Write-Log "Found OrangeFox release: $($release.tag_name) — $($imgAsset.name)" "INFO" $COLOR_INFO
                break
            }
        }

        if (-not $imgAsset) {
            Write-Log "No OrangeFox asset found for device '$ORANGEFOX_DEVICE' via GitHub API." "WARNING" $COLOR_WARNING
            Write-Log "Trying OrangeFox download portal fallback..." "INFO" $COLOR_INFO

            # Fallback: OrangeFox direct download page (unofficial mirror pattern)
            $fallbackUrl = "https://orangefox.download/api/v1/releases/get?codename=$ORANGEFOX_DEVICE&type=stable"
            try {
                $ofData = $wc.DownloadString($fallbackUrl) | ConvertFrom-Json
                $dlUrl  = $ofData.data.downloads.full.url
                if ($dlUrl) {
                    Write-Log "OrangeFox portal URL: $dlUrl" "INFO" $COLOR_INFO
                    $tempPath = Join-Path $DOWNLOADS_DIR "OrangeFox_austin.zip"
                    $ok = Invoke-DownloadWithRetry -Url $dlUrl -Destination $tempPath -Description "OrangeFox recovery (zip)"
                    if ($ok) {
                        # Extract .img from ZIP if needed
                        if ($tempPath -match "\.zip$") {
                            Write-Log "Extracting OrangeFox image from ZIP..." "INFO" $COLOR_INFO
                            Add-Type -AssemblyName System.IO.Compression.FileSystem
                            $zip = [System.IO.Compression.ZipFile]::OpenRead($tempPath)
                            $imgEntry = $zip.Entries | Where-Object { $_.Name -match "\.img$" } | Select-Object -First 1
                            if ($imgEntry) {
                                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($imgEntry, $destPath, $true)
                                Write-Log "OrangeFox image extracted to: $destPath" "SUCCESS" $COLOR_SUCCESS
                            }
                            $zip.Dispose()
                            return if (Test-Path $destPath) { $destPath } else { $null }
                        }
                    }
                }
            }
            catch {
                Write-Log "OrangeFox portal fallback also failed: $_" "ERROR" $COLOR_ERROR
            }

            Write-Log "Please download OrangeFox manually for '$ORANGEFOX_DEVICE' and place as: $destPath" "WARNING" $COLOR_WARNING
            return $null
        }

        $ok = Invoke-DownloadWithRetry -Url $imgAsset.browser_download_url -Destination $destPath -Description "OrangeFox recovery image"
        return if ($ok) { $destPath } else { $null }
    }
    catch {
        Write-Log "Error downloading OrangeFox: $_" "ERROR" $COLOR_ERROR
        return $null
    }
}

# ============================================
# VALIDATION FUNCTIONS
# ============================================

function Test-PathExists {
    param([string]$Path, [string]$Description)
    
    if (Test-Path -Path $Path) {
        Write-Log "$Description found: $Path" "SUCCESS" $COLOR_SUCCESS
        return $true
    }
    else {
        Write-Log "$Description NOT found: $Path" "ERROR" $COLOR_ERROR
        return $false
    }
}

function Test-AdminPrivileges {
    $currentUser = [Security.Principal.WindowsIdentity]::GetCurrent()
    $principal = New-Object Security.Principal.WindowsPrincipal $currentUser
    
    if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        Write-Log "Running with administrator privileges" "SUCCESS" $COLOR_SUCCESS
        return $true
    }
    else {
        Write-Log "WARNING: Not running as administrator. Some operations may fail." "WARNING" $COLOR_WARNING
        return $false
    }
}

# ============================================
# INITIALIZATION
# ============================================

function Initialize-Environment {
    Write-Section "Initializing Environment"
    
    # Create working directory
    if (-not (Test-Path -Path $WorkingDir)) {
        Write-Log "Creating working directory: $WorkingDir" "INFO" $COLOR_INFO
        New-Item -ItemType Directory -Path $WorkingDir -Force | Out-Null
    }
    else {
        Write-Log "Working directory already exists: $WorkingDir" "INFO" $COLOR_INFO
    }
    
    # Create extraction directory
    if (-not (Test-Path -Path $EXTRACTION_DIR)) {
        Write-Log "Creating extraction directory: $EXTRACTION_DIR" "INFO" $COLOR_INFO
        New-Item -ItemType Directory -Path $EXTRACTION_DIR -Force | Out-Null
    }
    
    # Create downloads directory
    if (-not (Test-Path -Path $DOWNLOADS_DIR)) {
        Write-Log "Creating downloads directory: $DOWNLOADS_DIR" "INFO" $COLOR_INFO
        New-Item -ItemType Directory -Path $DOWNLOADS_DIR -Force | Out-Null
    }
    
    # Initialize log file
    Write-Log "=" * 60 "INFO" $COLOR_INFO
    Write-Log "MOTO G 5G (2022) AUTOMATED FLASH SESSION" "INFO" $COLOR_INFO
    Write-Log "Timestamp: $TIMESTAMP" "INFO" $COLOR_INFO
    Write-Log "Proxy: $PROXY_SERVER" "INFO" $COLOR_INFO
    Write-Log "=" * 60 "INFO" $COLOR_INFO
    
    # Check admin privileges
    Test-AdminPrivileges | Out-Null
}

# ============================================
# FIRMWARE SEARCH & VALIDATION
# ============================================

function Find-FirmwareZip {
    Write-Section "Searching for Firmware"

    # 1. Check ManualFirmwarePath override
    if ($ManualFirmwarePath -and (Test-Path $ManualFirmwarePath)) {
        Write-Log "Using manually specified firmware: $ManualFirmwarePath" "SUCCESS" $COLOR_SUCCESS
        return $ManualFirmwarePath
    }

    # 2. Auto-detect in all known directories (downloads dir, working dir, RSA cache)
    $autoFound = Find-ExistingFirmware
    if ($autoFound) {
        return $autoFound
    }

    # 3. Legacy: search RSA path explicitly with verbose listing
    if (-not (Test-PathExists -Path $RSA_FIRMWARE_PATH -Description "RSA Firmware Directory")) {
        Write-Log "RSA firmware directory not found; no cached firmware available." "WARNING" $COLOR_WARNING
        return $null
    }
    
    # Search for firmware matching pattern
    Write-Log "Searching for firmware pattern: $FirmwareSearchPattern" "INFO" $COLOR_INFO
    
    try {
        $firmwareFiles = Get-ChildItem -Path $RSA_FIRMWARE_PATH -Filter $FirmwareSearchPattern -ErrorAction Stop
        
        if ($firmwareFiles.Count -eq 0) {
            Write-Log "No firmware files found matching pattern: $FirmwareSearchPattern" "ERROR" $COLOR_ERROR
            Write-Log "Available files in $RSA_FIRMWARE_PATH :" "INFO" $COLOR_INFO
            Get-ChildItem -Path $RSA_FIRMWARE_PATH | ForEach-Object {
                Write-Log "  - $($_.Name)" "INFO" $COLOR_INFO
            }
            return $null
        }
        
        # If multiple files, use the latest (by modification time)
        $selectedFirmware = $firmwareFiles | Sort-Object -Property LastWriteTime -Descending | Select-Object -First 1
        
        Write-Log "Found firmware: $($selectedFirmware.Name)" "SUCCESS" $COLOR_SUCCESS
        Write-Log "Full path: $($selectedFirmware.FullName)" "INFO" $COLOR_INFO
        Write-Log "Size: $([math]::Round($selectedFirmware.Length / 1GB, 2)) GB" "INFO" $COLOR_INFO
        
        return $selectedFirmware.FullName
    }
    catch {
        Write-Log "Error searching for firmware: $_" "ERROR" $COLOR_ERROR
        return $null
    }
}

# ============================================
# FIRMWARE EXTRACTION
# ============================================

function Extract-FirmwareImages {
    param([string]$FirmwareZipPath)
    
    Write-Section "Extracting Firmware Images"
    
    if (-not (Test-PathExists -Path $FirmwareZipPath -Description "Firmware ZIP")) {
        Write-Log "Firmware ZIP not accessible" "ERROR" $COLOR_ERROR
        return $false
    }
    
    try {
        # Load .NET compression library
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        
        # Open the firmware ZIP
        Write-Log "Opening firmware archive: $FirmwareZipPath" "INFO" $COLOR_INFO
        $firmwareZip = [System.IO.Compression.ZipFile]::OpenRead($FirmwareZipPath)
        
        Write-Log "Listing archive contents (first 20 entries)..." "INFO" $COLOR_INFO
        $entries = $firmwareZip.Entries | Select-Object -First 20
        $entries | ForEach-Object {
            Write-Log "  - $($_.FullName) ($([math]::Round($_.Length / 1MB, 2)) MB)" "INFO" $COLOR_INFO
        }
        
        # Extract boot.img
        Write-Log "Extracting $BOOT_IMG..." "INFO" $COLOR_INFO
        $bootEntry = $firmwareZip.Entries | Where-Object { $_.Name -eq $BOOT_IMG }
        
        if ($bootEntry) {
            $bootDestination = Join-Path -Path $EXTRACTION_DIR -ChildPath $BOOT_IMG
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($bootEntry, $bootDestination, $true)
            Write-Log "$BOOT_IMG extracted successfully: $bootDestination" "SUCCESS" $COLOR_SUCCESS
            Write-Log "Size: $([math]::Round($bootEntry.Length / 1MB, 2)) MB" "INFO" $COLOR_INFO
        }
        else {
            Write-Log "$BOOT_IMG not found in archive" "ERROR" $COLOR_ERROR
            $firmwareZip.Dispose()
            return $false
        }
        
        # Extract vbmeta.img
        Write-Log "Extracting $VBMETA_IMG..." "INFO" $COLOR_INFO
        $vbmetaEntry = $firmwareZip.Entries | Where-Object { $_.Name -eq $VBMETA_IMG }
        
        if ($vbmetaEntry) {
            $vbmetaDestination = Join-Path -Path $EXTRACTION_DIR -ChildPath $VBMETA_IMG
            [System.IO.Compression.ZipFileExtensions]::ExtractToFile($vbmetaEntry, $vbmetaDestination, $true)
            Write-Log "$VBMETA_IMG extracted successfully: $vbmetaDestination" "SUCCESS" $COLOR_SUCCESS
            Write-Log "Size: $([math]::Round($vbmetaEntry.Length / 1MB, 2)) MB" "INFO" $COLOR_INFO
        }
        else {
            Write-Log "$VBMETA_IMG not found in archive" "ERROR" $COLOR_ERROR
            $firmwareZip.Dispose()
            return $false
        }
        
        $firmwareZip.Dispose()
        Write-Log "Firmware extraction completed successfully" "SUCCESS" $COLOR_SUCCESS
        return $true
    }
    catch {
        Write-Log "Error extracting firmware: $_" "ERROR" $COLOR_ERROR
        return $false
    }
}

# ============================================
# ORANGEFOX VALIDATION
# ============================================

function Validate-OrangeFoxImage {
    Write-Section "Validating OrangeFox Recovery Image"
    
    $orangeFoxPath = Join-Path -Path $WorkingDir -ChildPath $OrangeFoxFile
    
    if (Test-PathExists -Path $orangeFoxPath -Description "OrangeFox Image") {
        $fileSize = (Get-Item -Path $orangeFoxPath).Length
        Write-Log "OrangeFox image size: $([math]::Round($fileSize / 1MB, 2)) MB" "INFO" $COLOR_INFO
        
        if ($fileSize -lt 10MB) {
            Write-Log "Warning: OrangeFox image appears unusually small (< 10 MB)" "WARNING" $COLOR_WARNING
            return $false
        }
        
        Write-Log "OrangeFox image validation passed" "SUCCESS" $COLOR_SUCCESS
        return $true
    }
    else {
        Write-Log "OrangeFox image not found at: $orangeFoxPath" "ERROR" $COLOR_ERROR
        Write-Log "Please place '$OrangeFoxFile' in: $WorkingDir" "WARNING" $COLOR_WARNING
        return $false
    }
}

# ============================================
# WiFi ADB/FASTBOOT CONNECTION
# ============================================

function Test-ADBAvailable {
    Write-Section "Checking ADB Availability"
    
    try {
        $adbVersion = & $ADB_EXE version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "ADB is available: $($adbVersion[0])" "SUCCESS" $COLOR_SUCCESS
            return $true
        }
        else {
            Write-Log "ADB command failed: $adbVersion" "ERROR" $COLOR_ERROR
            return $false
        }
    }
    catch {
        Write-Log "ADB not found at: $ADB_EXE" "ERROR" $COLOR_ERROR
        Write-Log "Download from: https://developer.android.com/tools/releases/platform-tools" "INFO" $COLOR_INFO
        return $false
    }
}

function Test-FastbootAvailable {
    Write-Section "Checking Fastboot Availability"
    
    try {
        $fastbootVersion = & $FASTBOOT_EXE --version 2>&1
        if ($LASTEXITCODE -eq 0) {
            Write-Log "Fastboot is available: $fastbootVersion" "SUCCESS" $COLOR_SUCCESS
            return $true
        }
        else {
            Write-Log "Fastboot command failed: $fastbootVersion" "ERROR" $COLOR_ERROR
            return $false
        }
    }
    catch {
        Write-Log "Fastboot not found at: $FASTBOOT_EXE" "ERROR" $COLOR_ERROR
        Write-Log "Download from: https://developer.android.com/tools/releases/platform-tools" "INFO" $COLOR_INFO
        return $false
    }
}

function Connect-ADBWiFi {
    param([string]$IPAddress, [int]$Port = $ADBPort)
    
    Write-Section "Establishing WiFi ADB Connection"
    
    Write-Log "Connecting to device at $IPAddress:$Port" "INFO" $COLOR_INFO
    
    try {
        # Connect via TCP/IP
        $connectOutput = & $ADB_EXE connect "$IPAddress`:$Port" 2>&1
        $exitCode = $LASTEXITCODE
        
        Write-Log "Connection output: $connectOutput" "INFO" $COLOR_INFO
        
        if ($exitCode -eq 0 -and $connectOutput -match "connected") {
            Write-Log "Successfully connected to device via WiFi" "SUCCESS" $COLOR_SUCCESS
            return $true
        }
        else {
            Write-Log "Failed to connect to device. Exit code: $exitCode" "ERROR" $COLOR_ERROR
            return $false
        }
    }
    catch {
        Write-Log "Exception during ADB connection: $_" "ERROR" $COLOR_ERROR
        return $false
    }
}

function Disconnect-ADBWiFi {
    param([string]$IPAddress, [int]$Port = $ADBPort)
    
    Write-Log "Disconnecting from device at $IPAddress:$Port" "INFO" $COLOR_INFO
    
    try {
        & $ADB_EXE disconnect "$IPAddress`:$Port" 2>&1 | Out-Null
        Write-Log "Disconnected from WiFi ADB" "SUCCESS" $COLOR_SUCCESS
    }
    catch {
        Write-Log "Warning: Error disconnecting ADB: $_" "WARNING" $COLOR_WARNING
    }
}

function Get-FastbootDevices {
    try {
        $devices = & $FASTBOOT_EXE devices 2>&1
        $deviceList = $devices | Where-Object { $_ -ne "" } | ConvertFrom-String -PropertyNames "SerialNumber", "Status"
        return $deviceList
    }
    catch {
        Write-Log "Error querying fastboot devices: $_" "ERROR" $COLOR_ERROR
        return @()
    }
}

function Get-ADBDevices {
    try {
        $devices = & $ADB_EXE devices 2>&1
        # Skip first line (header) and empty lines
        $deviceList = $devices | Select-Object -Skip 1 | Where-Object { $_ -ne "" } | ConvertFrom-String -PropertyNames "SerialNumber", "Status"
        return $deviceList
    }
    catch {
        Write-Log "Error querying ADB devices: $_" "ERROR" $COLOR_ERROR
        return @()
    }
}

function Wait-ForFastbootDevice {
    param(
        [string]$IPAddress = $null,
        [int]$TimeoutSeconds = $FastbootTimeoutSeconds,
        [int]$PollIntervalMs = $FastbootPollIntervalMs
    )
    
    Write-Section "Waiting for Device in Fastboot Mode"
    
    if ($IPAddress) {
        Write-Log "Waiting for WiFi Fastboot connection to: $IPAddress" "INFO" $COLOR_INFO
    }
    else {
        Write-Log "Waiting for USB Fastboot connection" "INFO" $COLOR_INFO
    }
    
    Write-Log "Ensure device is in Fastboot mode:" "WARNING" $COLOR_WARNING
    Write-Log "  1. Power off the device completely" "INFO" $COLOR_INFO
    Write-Log "  2. Press and hold Volume Down + Power until Fastboot mode appears" "INFO" $COLOR_INFO
    Write-Log "  3. Device will display 'FASTBOOT' on screen" "INFO" $COLOR_INFO
    Write-Host ""
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollCount = 0
    
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $pollCount++
        $devices = Get-FastbootDevices
        
        if ($devices.Count -gt 0) {
            Write-Log "Device detected in Fastboot mode!" "SUCCESS" $COLOR_SUCCESS
            Write-Log "Devices found:" "INFO" $COLOR_INFO
            $devices | ForEach-Object {
                Write-Log "  Serial: $($_.SerialNumber), Status: $($_.Status)" "INFO" $COLOR_INFO
            }
            $stopwatch.Stop()
            return $true
        }
        
        if ($pollCount % 5 -eq 0) {
            $elapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
            Write-Log "No device detected. Waiting... ($elapsedSeconds / $TimeoutSeconds seconds)" "WARNING" $COLOR_WARNING
        }
        
        Start-Sleep -Milliseconds $PollIntervalMs
    }
    
    $stopwatch.Stop()
    Write-Log "Timeout reached. No Fastboot device detected within $TimeoutSeconds seconds." "ERROR" $COLOR_ERROR
    return $false
}

function Wait-ForADBDevice {
    param(
        [string]$IPAddress,
        [int]$Port = $ADBPort,
        [int]$TimeoutSeconds = 60
    )
    
    Write-Section "Waiting for WiFi ADB Device"
    
    Write-Log "Waiting for device at $IPAddress:$Port" "INFO" $COLOR_INFO
    Write-Log "Ensure device has USB debugging enabled in Developer Options" "WARNING" $COLOR_WARNING
    Write-Host ""
    
    $stopwatch = [System.Diagnostics.Stopwatch]::StartNew()
    $pollCount = 0
    
    while ($stopwatch.Elapsed.TotalSeconds -lt $TimeoutSeconds) {
        $pollCount++
        $devices = Get-ADBDevices
        
        if ($devices.Count -gt 0) {
            Write-Log "Device detected via ADB!" "SUCCESS" $COLOR_SUCCESS
            Write-Log "Devices found:" "INFO" $COLOR_INFO
            $devices | ForEach-Object {
                Write-Log "  Serial: $($_.SerialNumber), Status: $($_.Status)" "INFO" $COLOR_INFO
            }
            $stopwatch.Stop()
            return $true
        }
        
        if ($pollCount % 5 -eq 0) {
            $elapsedSeconds = [math]::Round($stopwatch.Elapsed.TotalSeconds, 1)
            Write-Log "No device detected. Waiting... ($elapsedSeconds / $TimeoutSeconds seconds)" "WARNING" $COLOR_WARNING
        }
        
        Start-Sleep -Milliseconds 2000
    }
    
    $stopwatch.Stop()
    Write-Log "Timeout reached. No ADB device detected within $TimeoutSeconds seconds." "ERROR" $COLOR_ERROR
    return $false
}

function Enable-ADBWiFiMode {
    param([string]$IPAddress)
    
    Write-Section "Enabling WiFi ADB Mode on Device"
    
    Write-Log "Attempting to enable WiFi ADB mode via USB connection..." "INFO" $COLOR_INFO
    Write-Log "This requires the device to be connected via USB with ADB enabled" "WARNING" $COLOR_WARNING
    
    try {
        # Check if device is connected via USB
        $usbDevices = Get-ADBDevices
        if ($usbDevices.Count -eq 0) {
            Write-Log "No device connected via USB. Cannot enable WiFi mode." "ERROR" $COLOR_ERROR
            return $false
        }
        
        Write-Log "Connected device(s) found via USB:" "INFO" $COLOR_INFO
        $usbDevices | ForEach-Object {
            Write-Log "  $_" "INFO" $COLOR_INFO
        }
        
        # Enable TCP/IP ADB on port 5555
        Write-Log "Enabling TCP/IP ADB on port $ADBPort..." "INFO" $COLOR_INFO
        $output = & $ADB_EXE tcpip $ADBPort 2>&1
        $exitCode = $LASTEXITCODE
        
        Write-Log "Command output: $output" "INFO" $COLOR_INFO
        
        if ($exitCode -eq 0) {
            Write-Log "WiFi ADB mode enabled successfully" "SUCCESS" $COLOR_SUCCESS
            Start-Sleep -Seconds 2
            return $true
        }
        else {
            Write-Log "Failed to enable WiFi ADB mode. Exit code: $exitCode" "ERROR" $COLOR_ERROR
            return $false
        }
    }
    catch {
        Write-Log "Exception enabling WiFi ADB mode: $_" "ERROR" $COLOR_ERROR
        return $false
    }
}

# ============================================
# FASTBOOT FLASHING
# ============================================

function Flash-OrangeFoxRecovery {
    param([string]$ImagePath)
    
    Write-Section "Flashing OrangeFox Recovery to vendor_boot"
    
    if (-not (Test-PathExists -Path $ImagePath -Description "OrangeFox Image")) {
        Write-Log "Cannot proceed without OrangeFox image" "ERROR" $COLOR_ERROR
        return $false
    }
    
    try {
        Write-Log "Flashing: fastboot flash vendor_boot $ImagePath" "INFO" $COLOR_INFO
        Write-Log "This may take 30-60 seconds..." "INFO" $COLOR_INFO
        Write-Host ""
        
        # Execute fastboot flash command
        $output = & $FASTBOOT_EXE flash vendor_boot $ImagePath 2>&1
        $exitCode = $LASTEXITCODE
        
        Write-Host $output
        Write-Log "Fastboot exit code: $exitCode" "INFO" $COLOR_INFO
        
        if ($exitCode -eq 0) {
            Write-Log "OrangeFox recovery flashed successfully!" "SUCCESS" $COLOR_SUCCESS
            Write-Log "Output: $output" "INFO" $COLOR_INFO
            return $true
        }
        else {
            Write-Log "Fastboot flash command failed with exit code: $exitCode" "ERROR" $COLOR_ERROR
            Write-Log "Output: $output" "INFO" $COLOR_INFO
            return $false
        }
    }
    catch {
        Write-Log "Exception during fastboot flash: $_" "ERROR" $COLOR_ERROR
        return $false
    }
}

# ============================================
# DEVICE VERIFICATION (POST-FLASH)
# ============================================

function Verify-PostFlashState {
    Write-Section "Verifying Post-Flash State"
    
    Write-Log "Checking device connection..." "INFO" $COLOR_INFO
    
    try {
        $devices = Get-FastbootDevices
        if ($devices.Count -gt 0) {
            Write-Log "Device still in Fastboot mode:" "INFO" $COLOR_INFO
            $devices | ForEach-Object {
                Write-Log "  Serial: $($_.SerialNumber)" "INFO" $COLOR_INFO
            }
            Write-Log "Next steps:" "WARNING" $COLOR_WARNING
            Write-Log "  1. Restart device: fastboot reboot" "INFO" $COLOR_INFO
            Write-Log "  2. Device will boot into OrangeFox recovery" "INFO" $COLOR_INFO
        }
        else {
            Write-Log "No devices detected. Device may have rebooted." "INFO" $COLOR_INFO
        }
    }
    catch {
        Write-Log "Error during verification: $_" "ERROR" $COLOR_ERROR
    }
}

# ============================================
# SUMMARY & CLEANUP
# ============================================

function Write-ExecutionSummary {
    param(
        [hashtable]$Results
    )
    
    Write-Section "Execution Summary"
    
    Write-Log "Proxy Configuration:    $($Results.ProxyConfigured)"    "INFO" $COLOR_INFO
    Write-Log "Proxy Connectivity:     $($Results.ProxyConnectivity)"  "INFO" $COLOR_INFO
    Write-Log "Firmware Downloaded:    $($Results.FirmwareDownloaded)" "INFO" $COLOR_INFO
    Write-Log "Firmware Found:         $($Results.FirmwareFound)"      "INFO" $COLOR_INFO
    Write-Log "Extraction Successful:  $($Results.ExtractionSuccess)"  "INFO" $COLOR_INFO
    Write-Log "Magisk Downloaded:      $($Results.MagiskDownloaded)"   "INFO" $COLOR_INFO
    Write-Log "OrangeFox Downloaded:   $($Results.OrangeFoxDownloaded)" "INFO" $COLOR_INFO
    Write-Log "OrangeFox Validated:    $($Results.OrangeFoxValid)"     "INFO" $COLOR_INFO
    Write-Log "WiFi ADB Connected:     $($Results.WiFiADBConnected)"   "INFO" $COLOR_INFO
    Write-Log "Device Detected:        $($Results.DeviceDetected)"     "INFO" $COLOR_INFO
    Write-Log "Flash Successful:       $($Results.FlashSuccess)"       "INFO" $COLOR_INFO
    
    Write-Host ""
    Write-Log "Log file:             $LOG_FILE"         "INFO" $COLOR_INFO
    Write-Log "Working directory:    $WorkingDir"       "INFO" $COLOR_INFO
    Write-Log "Downloads directory:  $DOWNLOADS_DIR"   "INFO" $COLOR_INFO
    Write-Log "Extraction directory: $EXTRACTION_DIR"  "INFO" $COLOR_INFO
    
    if ($Results.FlashSuccess) {
        Write-Host ""
        Write-Log "OPERATION COMPLETED SUCCESSFULLY!" "SUCCESS" $COLOR_SUCCESS
    }
    else {
        Write-Host ""
        Write-Log "OPERATION COMPLETED WITH ERRORS. See log file for details." "WARNING" $COLOR_WARNING
    }
}

# ============================================
# MAIN EXECUTION FLOW
# ============================================

function Invoke-MainWorkflow {
    try {
        # Initialize
        Initialize-Environment
        
        # Track results
        $results = @{
            ProxyConfigured    = $false
            ProxyConnectivity  = $false
            FirmwareDownloaded = $false
            FirmwareFound      = $false
            ExtractionSuccess  = $false
            MagiskDownloaded   = $false
            OrangeFoxDownloaded = $false
            OrangeFoxValid     = $false
            WiFiADBConnected   = $false
            DeviceDetected     = $false
            FlashSuccess       = $false
        }
        
        # Step 0: Configure Proxy
        if (-not $SkipProxyConfig) {
            $proxyConfigured = Set-WifiProxy -ProxyAddress $PROXY_SERVER
            if ($proxyConfigured) {
                $results.ProxyConfigured = $true
                
                # Test proxy connectivity
                $proxyConnectivity = Test-ProxyConnectivity
                $results.ProxyConnectivity = $proxyConnectivity
            }
            else {
                Write-Log "Failed to configure proxy. Continuing with local network only." "WARNING" $COLOR_WARNING
            }
        }
        else {
            Write-Log "Proxy configuration skipped by user" "INFO" $COLOR_INFO
        }

        # Step 1a: Download Magisk
        if (-not $SkipMagiskDownload) {
            $magiskPath = Download-MagiskAPK
            if ($magiskPath) {
                $results.MagiskDownloaded = $true
            }
            else {
                Write-Log "Magisk download failed — continuing without it." "WARNING" $COLOR_WARNING
            }
        }
        else {
            Write-Log "Magisk download skipped." "INFO" $COLOR_INFO
        }

        # Step 1b: Download OrangeFox (if not already present)
        if (-not $SkipOrangeFoxDownload) {
            $ofPath = Download-OrangeFoxRecovery
            if ($ofPath) {
                $results.OrangeFoxDownloaded = $true
            }
            else {
                Write-Log "OrangeFox download failed — will check for manually placed file." "WARNING" $COLOR_WARNING
            }
        }
        else {
            Write-Log "OrangeFox download skipped." "INFO" $COLOR_INFO
        }

        # Step 1c: Download firmware with fallback (unless skipped)
        $firmwarePath = $null
        if (-not $SkipFirmwareDownload) {
            $downloadedPath = Download-FirmwareWithFallback
            if ($downloadedPath) {
                $results.FirmwareDownloaded = $true
                $firmwarePath = $downloadedPath
            }
            else {
                Write-Log "Automated firmware download failed. Falling back to local search..." "WARNING" $COLOR_WARNING
            }
        }
        else {
            Write-Log "Firmware download skipped — searching local cache." "INFO" $COLOR_INFO
        }

        # Step 2: Find firmware (local/RSA cache fallback if download failed)
        if (-not $firmwarePath) {
            $firmwarePath = Find-FirmwareZip
        }

        if ($firmwarePath) {
            $results.FirmwareFound = $true
        }
        else {
            Write-Log "" "WARNING" $COLOR_WARNING
            Write-Log "Firmware not found via download or local cache." "ERROR" $COLOR_ERROR
            Write-Log "You can still proceed with flashing if OrangeFox is present." "WARNING" $COLOR_WARNING
            Write-Log "To continue without firmware extraction, ensure boot.img & vbmeta.img" "WARNING" $COLOR_WARNING
            Write-Log "are already present in: $EXTRACTION_DIR" "INFO" $COLOR_INFO

            # Check if extracted images already exist from a previous run
            $bootExists   = Test-Path (Join-Path $EXTRACTION_DIR $BOOT_IMG)
            $vbmetaExists = Test-Path (Join-Path $EXTRACTION_DIR $VBMETA_IMG)
            if ($bootExists -and $vbmetaExists) {
                Write-Log "Previously extracted images found — skipping extraction step." "SUCCESS" $COLOR_SUCCESS
                $results.ExtractionSuccess = $true
            }
            else {
                Write-Log "No pre-extracted images found. Firmware is required to continue." "ERROR" $COLOR_ERROR
                Write-ExecutionSummary -Results $results
                return
            }
        }
        
        # Step 3: Extract firmware images (only if we have a firmware path and haven't already extracted)
        if ($firmwarePath -and -not $results.ExtractionSuccess) {
            $extractionSuccess = Extract-FirmwareImages -FirmwareZipPath $firmwarePath
            if ($extractionSuccess) {
                $results.ExtractionSuccess = $true
            }
            else {
                Write-Log "Firmware extraction failed. Aborting." "ERROR" $COLOR_ERROR
                Write-ExecutionSummary -Results $results
                return
            }
        }
        
        # Step 4: Validate OrangeFox
        $orangeFoxValid = Validate-OrangeFoxImage
        if ($orangeFoxValid) {
            $results.OrangeFoxValid = $true
        }
        else {
            Write-Log "OrangeFox validation failed. Aborting." "ERROR" $COLOR_ERROR
            Write-ExecutionSummary -Results $results
            return
        }
        
        # Step 5: Check ADB & Fastboot
        $adbAvailable      = Test-ADBAvailable
        $fastbootAvailable = Test-FastbootAvailable
        
        if (-not ($adbAvailable -and $fastbootAvailable)) {
            Write-Log "ADB or Fastboot not available. Aborting." "ERROR" $COLOR_ERROR
            Write-ExecutionSummary -Results $results
            return
        }
        
        # Step 6: WiFi Connection Setup
        if ($DeviceIPAddress) {
            Write-Section "WiFi Connection Mode Selected"
            
            # First, enable WiFi ADB mode (requires USB)
            Write-Log "First, connect device via USB and enable WiFi ADB mode..." "WARNING" $COLOR_WARNING
            $enableWiFiMode = Enable-ADBWiFiMode -IPAddress $DeviceIPAddress
            
            if ($enableWiFiMode) {
                # Connect via WiFi
                $wifiConnected = Connect-ADBWiFi -IPAddress $DeviceIPAddress -Port $ADBPort
                if ($wifiConnected) {
                    $results.WiFiADBConnected = $true
                    
                    # Wait for device via ADB
                    $deviceDetected = Wait-ForADBDevice -IPAddress $DeviceIPAddress -Port $ADBPort
                    if ($deviceDetected) {
                        $results.DeviceDetected = $true
                    }
                    else {
                        Write-Log "Device not detected via WiFi ADB. Aborting." "ERROR" $COLOR_ERROR
                        Disconnect-ADBWiFi -IPAddress $DeviceIPAddress
                        Write-ExecutionSummary -Results $results
                        return
                    }
                }
                else {
                    Write-Log "Failed to connect via WiFi. Aborting." "ERROR" $COLOR_ERROR
                    Write-ExecutionSummary -Results $results
                    return
                }
            }
            else {
                Write-Log "Failed to enable WiFi ADB mode. Aborting." "ERROR" $COLOR_ERROR
                Write-ExecutionSummary -Results $results
                return
            }
        }
        else {
            # Step 6: Wait for device in Fastboot mode (USB)
            $deviceDetected = Wait-ForFastbootDevice -TimeoutSeconds $FastbootTimeoutSeconds
            if ($deviceDetected) {
                $results.DeviceDetected = $true
            }
            else {
                Write-Log "No device detected in Fastboot mode. Aborting." "ERROR" $COLOR_ERROR
                Write-ExecutionSummary -Results $results
                return
            }
        }
        
        # Step 7: Flash OrangeFox recovery
        $orangeFoxPath = Join-Path -Path $WorkingDir -ChildPath $OrangeFoxFile
        $flashSuccess = Flash-OrangeFoxRecovery -ImagePath $orangeFoxPath
        if ($flashSuccess) {
            $results.FlashSuccess = $true
        }
        
        # Step 8: Cleanup WiFi if needed
        if ($DeviceIPAddress) {
            Disconnect-ADBWiFi -IPAddress $DeviceIPAddress
        }
        
        # Step 9: Post-flash verification
        Verify-PostFlashState
        
        # Summary
        Write-ExecutionSummary -Results $results
    }
    catch {
        Write-Log "Unexpected error in main workflow: $_" "ERROR" $COLOR_ERROR
        Write-Log "Stack trace: $($_.ScriptStackTrace)" "ERROR" $COLOR_ERROR
    }
}

# ============================================
# ENTRY POINT
# ============================================

Write-Host ""
Write-Host "╔════════════════════════════════════════════════════════════╗" -ForegroundColor Cyan
Write-Host "║   MOTO G 5G (2022) AUTOMATED FLASH AUTOMATION SCRIPT      ║" -ForegroundColor Cyan
Write-Host "║   Device: XT2213-3 AUSTIN (RETUS, Unlocked)               ║" -ForegroundColor Cyan
Write-Host "║   Target: OrangeFox Recovery via vendor_boot              ║" -ForegroundColor Cyan
Write-Host "║   Connection: WiFi + Proxy Support                        ║" -ForegroundColor Cyan
Write-Host "╚════════════════════════════════════════════════════════════╝" -ForegroundColor Cyan
Write-Host ""
Write-Host "Parameters:" -ForegroundColor Yellow
Write-Host "  Proxy Server:          $ProxyServer"                                                                    -ForegroundColor Yellow
Write-Host "  Platform Tools:        $PlatformToolsPath"                                                              -ForegroundColor Yellow
Write-Host "  Working Directory:     $WorkingDir"                                                                      -ForegroundColor Yellow
Write-Host "  Downloads Directory:   $WorkingDir\downloads"                                                           -ForegroundColor Yellow
Write-Host "  Firmware Pattern:      $FirmwareSearchPattern"                                                           -ForegroundColor Yellow
Write-Host "  Manual Firmware Path:  $(if ($ManualFirmwarePath) { $ManualFirmwarePath } else { 'Not specified' })"   -ForegroundColor Yellow
Write-Host "  OrangeFox File:        $OrangeFoxFile"                                                                   -ForegroundColor Yellow
Write-Host "  Device IP (WiFi):      $(if ($DeviceIPAddress) { $DeviceIPAddress } else { 'Not specified (USB mode)' })" -ForegroundColor Yellow
Write-Host "  ADB Port:              $ADBPort"                                                                         -ForegroundColor Yellow
Write-Host "  Fastboot Timeout:      $FastbootTimeoutSeconds seconds"                                                  -ForegroundColor Yellow
Write-Host "  Download Retry Count:  $DownloadRetryCount"                                                              -ForegroundColor Yellow
Write-Host "  Download Timeout:      $DownloadTimeoutSeconds seconds"                                                  -ForegroundColor Yellow
Write-Host "  Skip Firmware DL:      $SkipFirmwareDownload"                                                            -ForegroundColor Yellow
Write-Host "  Skip Magisk DL:        $SkipMagiskDownload"                                                              -ForegroundColor Yellow
Write-Host "  Skip OrangeFox DL:     $SkipOrangeFoxDownload"                                                          -ForegroundColor Yellow
Write-Host ""

$userConfirm = Read-Host "Continue with flash operation? (yes/no)"
if ($userConfirm -ne "yes") {
    Write-Log "User cancelled operation" "WARNING" $COLOR_WARNING
    exit 0
}

Write-Host ""
Invoke-MainWorkflow
