NetGame Tunnel - User Guide
Product Name: NetGame Tunnel
Created by: Mozzarella Fresh
Version: 1.0
Date: July 15, 2025
1. Welcome to NetGame Tunnel!
Congratulations on purchasing NetGame Tunnel! This powerful, non-root proxy solution is designed to enhance your Nintendo Switch online gaming experience on mobile data. It helps overcome common issues like SSL/TLS handshake failures and provides a more stable connection by routing your Switch's traffic through a robust proxy.
What NetGame Tunnel Does:
 * Provides a reliable HTTP/HTTPS proxy server directly on your Android phone via Termux.
 * Correctly handles secure (HTTPS) connections, resolving authentication and handshake errors.
What NetGame Tunnel Does NOT Do (Important Limitations):
 * Does NOT require root access. This is a key benefit for your phone's security and warranty.
 * Does NOT magically bypass Android's native hotspot-to-VPN routing limitation. Android's built-in hotspot typically does not route connected client traffic through a device-wide VPN without root. NetGame Tunnel works within this limitation by providing a proper proxy, but carrier detection or NAT type issues may still arise depending on your specific phone/carrier.
 * Does NOT guarantee a specific NAT type. While it improves proxy handling, NAT type is complex and influenced by your carrier.
2. What You Need Before You Start
Before you begin, please ensure you have the following:
 * Android Smartphone: With an active mobile data plan and a Wi-Fi Hotspot feature.
 * Nintendo Switch Console: Ready to connect to a Wi-Fi network.
 * Sufficient Storage Space: Your phone needs at least 2-3 GB of free internal storage for Termux and the necessary files.
 * Reliable Internet Connection: For downloading Termux and program files.
 * Basic Familiarity with Android Settings: You'll need to navigate your phone's Wi-Fi Hotspot settings.
3. Installing Termux (Crucial Step for New Users!)
WARNING: DO NOT INSTALL TERMUX FROM THE GOOGLE PLAY STORE! The version on the Play Store is severely outdated and and will not work correctly.
You MUST install the official, up-to-date Termux app from either F-Droid or GitHub.
Option A: Install from F-Droid (Recommended & Easiest)
 * Download F-Droid: Open your phone's web browser and go to https://f-droid.org/.
 * Tap on "Download F-Droid App."
 * Once downloaded, open the F-Droid.apk file and install it. You might need to allow installation from "unknown sources" in your phone's settings.
 * Open F-Droid: Once F-Droid is installed, open the F-Droid app.
 * Search for Termux: Use the search icon (magnifying glass) and type "Termux".
 * Install Termux: Tap on the "Termux" app in the search results and then tap "Install."
Option B: Install from GitHub Releases
 * Open your phone's web browser and go to the official Termux GitHub releases page: https://github.com/termux/termux-app/releases
 * Scroll down to the "Assets" section of the latest stable release (e.g., v0.118.0 or higher).
 * Download the termux-app_vX.YY.Z+github.apk file (choose the one without -debug or -universal unless you know why you need it).
 * Once downloaded, open the APK file and install it. You might need to allow installation from "unknown sources."
4. Initial Termux Setup
After installing the official Termux app:
 * Open Termux: Launch the Termux app on your phone. It will perform an initial setup.
 * Update Packages: It's vital to update Termux's package list and upgrade any installed packages. Type the following commands and press Enter after each:
   pkg update -y
pkg upgrade -y

   * If prompted with a question (e.g., "Do you want to keep your local version or install the maintainer's version?"), always press Y or N (depending on the question, usually N to keep your current version, or Y to install the maintainer's if you're unsure) and then Enter.
 * Grant Storage Permissions: This allows Termux to access your phone's shared storage (like your Downloads folder). Type:
   termux-setup-storage

   * When prompted by Android, GRANT the storage permission.
5. Installing NetGame Tunnel
Now, let's get NetGame Tunnel set up.
 * Download the Installer Script:
   * You should have received install_netgametunnel.sh as part of your purchase.
   * Make sure this file is placed in your phone's "Downloads" folder.
   * In Termux, navigate to your Downloads folder:
     cd ~/storage/downloads

     (If cd ~/storage/downloads doesn't work, try cd /sdcard/Download or cd /storage/emulated/0/Download)
 * Make the Script Executable:
   chmod +x install_netgametunnel.sh

 * Run the Installer Script:
   ./install_netgametunnel.sh

   * The script will display the NetGame Tunnel ASCII art and a welcome message.
   * It will automatically check for and install any missing Python or proot-distro dependencies. Follow any prompts (type y and Enter).
   * It will then deploy the core net_game_tunnel.py proxy script to your Termux home directory (~/).
   * Finally, it will present you with the NetGame Tunnel Main Menu.
6. Using the NetGame Tunnel Main Menu
After running install_netgametunnel.sh, you will see a menu:
----------------------------------------------------------------------
[INFO] NetGame Tunnel Main Menu
----------------------------------------------------------------------
1. Start NetGame Tunnel
2. Stop NetGame Tunnel
3. Check NetGame Tunnel Status
4. Exit
----------------------------------------------------------------------
Enter your choice (1-4):

 * 1. Start NetGame Tunnel:
   * This will launch the proxy server in the background.
   * You'll see a message like [INFO] NetGame Tunnel is now active....
   * The proxy will continue running even if you close Termux (thanks to nohup and termux-wake-lock).
 * 2. Stop NetGame Tunnel:
   * This will gracefully stop the running proxy server.
   * You'll see a message like [INFO] NetGame Tunnel has stopped. Goodbye!.
 * 3. Check NetGame Tunnel Status:
   * This will tell you if the proxy server is currently running or not.
   * It will also show you the last few lines of the proxy's log file (net_game_tunnel.log), which can be helpful for troubleshooting.
 * 4. Exit:
   * Exits the menu script. The proxy will continue running if you started it.
7. Configuring Your Android Hotspot & Nintendo Switch
This is where you connect your Switch to NetGame Tunnel.
7.1. Turn On Your Phone's Wi-Fi Hotspot
 * Go to your Android phone's Settings.
 * Navigate to "Network & internet" > "Hotspot & tethering" > "Wi-Fi hotspot" (the exact path may vary by phone model).
 * Turn on your Wi-Fi hotspot.
 * Note down your Hotspot's Name (SSID) and Password.
 * Find your Phone's IP Address on the Hotspot Network: This is the most critical piece of information. Look for an option like "Hotspot IP address," "Gateway," or "Device IP" within your phone's Wi-Fi hotspot settings. Common examples are 192.168.43.1 or 192.168.42.1. If you can't find it there, you might need to connect another device (like a laptop) to the hotspot and check its network gateway.
7.2. Configure Your Nintendo Switch
 * On your Nintendo Switch, go to the HOME Menu.
 * Select "System Settings" (the gear icon).
 * Scroll down the left-hand menu and select "Internet."
 * On the right, select "Internet Settings."
 * The Switch will search for Wi-Fi networks. Find and select the Name (SSID) of your phone's Wi-Fi hotspot.
 * If prompted, enter your hotspot's Password.
 * After the initial connection attempt, select "Change Settings."
 * Scroll down to "Proxy Settings."
 * Set "Proxy Settings" to "On."
 * For "Host," enter your phone's IP address on the hotspot network (e.g., 192.168.43.1).
 * For "Port," enter 8888 (this is NetGame Tunnel's default listening port).
 * Select "Save."
 * Select "Connect to This Network" to test the connection.
If the test is successful, your Nintendo Switch should now be routing its internet traffic through NetGame Tunnel!
8. Troubleshooting & FAQ
Refer to the separate "NetGame Tunnel - Troubleshooting & FAQ.md" document for solutions to common issues.
