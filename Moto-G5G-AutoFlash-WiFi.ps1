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
    [switch]$SkipProxyConfig
)

# ============================================
# CONFIGURATION & CONSTANTS
# ============================================

$RSA_FIRMWARE_PATH = "C:\ProgramData\RSA\Download\RomFiles"
$TIMESTAMP = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$LOG_FILE = "$WorkingDir\flash_log_$TIMESTAMP.txt"
$EXTRACTION_DIR = "$WorkingDir\extracted_firmware"
$BOOT_IMG = "boot.img"
$VBMETA_IMG = "vbmeta.img"

# Proxy configuration
$PROXY_SERVER = $ProxyServer
$PROXY_USERNAME = $null
$PROXY_PASSWORD = $null

# Color codes for console output
$COLOR_INFO = "Cyan"
$COLOR_SUCCESS = "Green"
$COLOR_WARNING = "Yellow"
$COLOR_ERROR = "Red"

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
    
    # Validate RSA path exists
    if (-not (Test-PathExists -Path $RSA_FIRMWARE_PATH -Description "RSA Firmware Directory")) {
        Write-Log "Attempting alternative firmware location..." "WARNING" $COLOR_WARNING
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
        $adbVersion = & adb version 2>&1
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
        Write-Log "ADB not found in PATH. Please install Android SDK Platform Tools." "ERROR" $COLOR_ERROR
        Write-Log "Download from: https://developer.android.com/tools/releases/platform-tools" "INFO" $COLOR_INFO
        return $false
    }
}

function Test-FastbootAvailable {
    Write-Section "Checking Fastboot Availability"
    
    try {
        $fastbootVersion = & fastboot --version 2>&1
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
        Write-Log "Fastboot not found in PATH. Please install Android SDK Platform Tools." "ERROR" $COLOR_ERROR
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
        $connectOutput = & adb connect "$IPAddress`:$Port" 2>&1
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
        & adb disconnect "$IPAddress`:$Port" 2>&1 | Out-Null
        Write-Log "Disconnected from WiFi ADB" "SUCCESS" $COLOR_SUCCESS
    }
    catch {
        Write-Log "Warning: Error disconnecting ADB: $_" "WARNING" $COLOR_WARNING
    }
}

function Get-FastbootDevices {
    try {
        $devices = & fastboot devices 2>&1
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
        $devices = & adb devices 2>&1
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
        $output = & adb tcpip $ADBPort 2>&1
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
        $output = & fastboot flash vendor_boot $ImagePath 2>&1
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
    
    Write-Log "Proxy Configuration: $($Results.ProxyConfigured)" "INFO" $COLOR_INFO
    Write-Log "Proxy Connectivity: $($Results.ProxyConnectivity)" "INFO" $COLOR_INFO
    Write-Log "Firmware Found: $($Results.FirmwareFound)" "INFO" $COLOR_INFO
    Write-Log "Extraction Successful: $($Results.ExtractionSuccess)" "INFO" $COLOR_INFO
    Write-Log "OrangeFox Validated: $($Results.OrangeFoxValid)" "INFO" $COLOR_INFO
    Write-Log "WiFi ADB Connected: $($Results.WiFiADBConnected)" "INFO" $COLOR_INFO
    Write-Log "Device Detected: $($Results.DeviceDetected)" "INFO" $COLOR_INFO
    Write-Log "Flash Successful: $($Results.FlashSuccess)" "INFO" $COLOR_INFO
    
    Write-Host ""
    Write-Log "Log file: $LOG_FILE" "INFO" $COLOR_INFO
    Write-Log "Working directory: $WorkingDir" "INFO" $COLOR_INFO
    Write-Log "Extraction directory: $EXTRACTION_DIR" "INFO" $COLOR_INFO
    
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
            ProxyConfigured = $false
            ProxyConnectivity = $false
            FirmwareFound = $false
            ExtractionSuccess = $false
            OrangeFoxValid = $false
            WiFiADBConnected = $false
            DeviceDetected = $false
            FlashSuccess = $false
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
        
        # Step 1: Find firmware
        $firmwarePath = Find-FirmwareZip
        if ($firmwarePath) {
            $results.FirmwareFound = $true
        }
        else {
            Write-Log "Firmware search failed. Aborting." "ERROR" $COLOR_ERROR
            Write-ExecutionSummary -Results $results
            return
        }
        
        # Step 2: Extract firmware images
        $extractionSuccess = Extract-FirmwareImages -FirmwareZipPath $firmwarePath
        if ($extractionSuccess) {
            $results.ExtractionSuccess = $true
        }
        else {
            Write-Log "Firmware extraction failed. Aborting." "ERROR" $COLOR_ERROR
            Write-ExecutionSummary -Results $results
            return
        }
        
        # Step 3: Validate OrangeFox
        $orangeFoxValid = Validate-OrangeFoxImage
        if ($orangeFoxValid) {
            $results.OrangeFoxValid = $true
        }
        else {
            Write-Log "OrangeFox validation failed. Aborting." "ERROR" $COLOR_ERROR
            Write-ExecutionSummary -Results $results
            return
        }
        
        # Step 4: Check ADB & Fastboot
        $adbAvailable = Test-ADBAvailable
        $fastbootAvailable = Test-FastbootAvailable
        
        if (-not ($adbAvailable -and $fastbootAvailable)) {
            Write-Log "ADB or Fastboot not available. Aborting." "ERROR" $COLOR_ERROR
            Write-ExecutionSummary -Results $results
            return
        }
        
        # Step 5: WiFi Connection Setup
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
            # Step 5: Wait for device in Fastboot mode (USB)
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
        
        # Step 6: Flash OrangeFox recovery
        $orangeFoxPath = Join-Path -Path $WorkingDir -ChildPath $OrangeFoxFile
        $flashSuccess = Flash-OrangeFoxRecovery -ImagePath $orangeFoxPath
        if ($flashSuccess) {
            $results.FlashSuccess = $true
        }
        
        # Step 7: Cleanup WiFi if needed
        if ($DeviceIPAddress) {
            Disconnect-ADBWiFi -IPAddress $DeviceIPAddress
        }
        
        # Step 8: Post-flash verification
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
Write-Host "  Proxy Server:         $ProxyServer" -ForegroundColor Yellow
Write-Host "  Working Directory:    $WorkingDir" -ForegroundColor Yellow
Write-Host "  Firmware Pattern:     $FirmwareSearchPattern" -ForegroundColor Yellow
Write-Host "  OrangeFox File:       $OrangeFoxFile" -ForegroundColor Yellow
Write-Host "  Device IP (WiFi):     $(if ($DeviceIPAddress) { $DeviceIPAddress } else { "Not specified (USB mode)" })" -ForegroundColor Yellow
Write-Host "  ADB Port:             $ADBPort" -ForegroundColor Yellow
Write-Host "  Fastboot Timeout:     $FastbootTimeoutSeconds seconds" -ForegroundColor Yellow
Write-Host ""

$userConfirm = Read-Host "Continue with flash operation? (yes/no)"
if ($userConfirm -ne "yes") {
    Write-Log "User cancelled operation" "WARNING" $COLOR_WARNING
    exit 0
}

Write-Host ""
Invoke-MainWorkflow
