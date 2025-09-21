NetGame Tunnel - Troubleshooting & FAQ
Product Name: NetGame Tunnel
Created by: Mozzarella Fresh
Version: 1.0
Date: July 15, 2025
1. Common Issues & Solutions
Issue: "Error installing python" or "Error installing proot-distro" during setup.
 * Cause: Termux's package repositories might be temporarily down, or your internet connection is unstable.
 * Solution:
   * Ensure you have a stable and strong internet connection.
   * Try running pkg update && pkg upgrade -y again in Termux.
   * Then, re-run the installer script: ./install_netgametunnel.sh.
   * If it persists, try changing Termux's package mirrors: termux-change-repo and select a different mirror.
Issue: "curl: (23) Failure writing output to destination" when installing distributions (if you tried to install them all).
 * Cause: Insufficient free internal storage on your Android phone. This is a critical error.
 * Solution:
   * Go to your Android phone's Settings > Storage (or Device Care > Storage).
   * Free up at least 2-3 GB of internal storage. Delete large files, old videos, unnecessary apps, or clear cached data.
   * Once storage is clear, you can try installing any specific proot-distro distribution again (e.g., proot-distro install ubuntu). NetGame Tunnel itself doesn't require all distributions, but this error indicates a general storage problem.
Issue: NetGame Tunnel "Failed to start" or "Is not running" (when checking status).
 * Cause 1: Port already in use. Another app or service on your phone might be using port 8888.
 * Solution 1:
   * Try changing the PROXY_PORT in the net_game_tunnel.py script to something else (e.g., 8080, 8000, 9000).
     * In Termux: nano net_game_tunnel.py
     * Find PROXY_PORT = 8888 and change 8888 to a different number.
     * Save (Ctrl+S) and exit (Ctrl+X).
     * Then, try to start NetGame Tunnel again from the menu. Remember to update the port on your Nintendo Switch as well.
 * Cause 2: Python script error. There might be an issue within the Python script itself.
 * Solution 2: Check the log file for errors. From the NetGame Tunnel menu, select option 3 ("Check NetGame Tunnel Status") to see recent log entries. If you see Python tracebacks, copy them and seek further assistance.
Issue: Nintendo Switch connects to hotspot but gets "Unable to connect to the Internet" or "DNS error" or "Proxy error."
 * Cause 1: NetGame Tunnel is not running.
 * Solution 1: In Termux, run install_netgametunnel.sh and select option 3 ("Check NetGame Tunnel Status"). If it's not running, select option 1 ("Start NetGame Tunnel").
 * Cause 2: Incorrect Proxy Settings on Switch.
 * Solution 2: Double-check the Host (your phone's hotspot IP address) and Port (8888, or your custom port) entered on your Nintendo Switch. Ensure there are no typos.
 * Cause 3: Incorrect Hotspot IP. Your phone's hotspot IP might have changed.
 * Solution 3: Re-verify your phone's hotspot IP address in your Android settings and update it on your Switch if necessary.
 * Cause 4: Firewall/Security on phone blocking connections to proxy.
 * Solution 4: While rare for Termux, some aggressive Android security apps might interfere. Temporarily disable any third-party firewall or security apps on your Android phone to test.
Issue: Nintendo Switch connects, but online games/multiplayer don't work (e.g., "NAT Type" issues).
 * Cause: This is often related to the non-root Android hotspot limitation. While NetGame Tunnel correctly proxies, Android's native hotspot might not fully bridge all client traffic (especially UDP for P2P gaming) in a way that satisfies strict NAT requirements.
 * Solution:
   * Consider alternative hardware solutions (if this is a critical need):
     * USB Tethering to a Computer + Computer Hotspot: Connect your phone to a Windows/Mac computer via USB tethering. Then, create a Wi-Fi hotspot from your computer and connect your Switch to that. This is often more reliable for NAT types.
     * Portable Travel Router: Use a dedicated travel router that can connect to your phone's hotspot. This provides the most robust and compatible solution for gaming.
2. Frequently Asked Questions (FAQ)
Q: Do I need to root my phone to use NetGame Tunnel?
A: No! NetGame Tunnel is specifically designed to work on non-rooted Android devices using the Termux environment.
Q: Can I close Termux after starting NetGame Tunnel?
A: Yes! The install_netgametunnel.sh script starts NetGame Tunnel in the background using nohup and keeps your phone awake with termux-wake-lock. You can close Termux, and NetGame Tunnel will continue running. To stop it, simply open Termux and use the install_netgametunnel.sh menu (Option 2).
Q: Why is my internet still slow or getting throttled?
A: Carrier throttling is complex. If your carrier heavily monitors traffic or has strict data caps, you might still experience some throttling. The non-root Android hotspot limitation can also play a role.
Q: My phone's IP address changes. What do I do?
A: If your phone's local IP address on the hotspot network changes, you will need to update the "Host" setting in your Nintendo Switch's proxy configuration to the new IP address.
Q: I'm getting "Connection timed out" errors on my Switch.
A: This often means the Switch couldn't reach the proxy server.
 * Verify NetGame Tunnel is running (check status in Termux).
 * Ensure your phone's hotspot is active.
 * Double-check the Host IP and Port on your Switch's proxy settings.
 * Temporarily disable any other security apps on your phone that might block local connections.
