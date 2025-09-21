!/data/data/com.termux/files/usr/bin/bash

# --- NetGame Tunnel Installer & User Interface ---
# Created by Mozzarella Fresh
# This script sets up and manages the NetGame Tunnel proxy service.

# --- Configuration ---
PROXY_SCRIPT_NAME="net_game_tunnel.py"
PID_FILE="/data/data/com.termux/files/usr/tmp/net_game_tunnel.pid"
LOG_FILE="/data/data/com.termux/files/usr/tmp/net_game_tunnel.log"

# --- ASCII Art for Branding (Using very basic characters for maximum compatibility) ---
read -r -d '' ASCII_ART << 'EOF_ASCII'
N E T G A M E
-------------
N N N N N N N
E E E E E E E
T T T T T T T
G G G G G G G
A A A A A A A
M M M M M M M
E E E E E E E
-------------
                                  by Mozzarella Fresh
EOF_ASCII

# --- Helper Functions ---

# Function to print messages with colors
print_info() {
    echo -e "\e[1;34m[INFO]\e[0m $1"
}
print_success() {
    echo -e "\e[1;32m[SUCCESS]\e[0m $1"
}
print_warning() {
    echo -e "\e[1;33m[WARNING]\e[0m $1"
}
print_error() {
    echo -e "\e[1;31m[ERROR]\e[0m $1"
}
print_question() {
    echo -e "\e[1;36m[QUESTION]\e[0m $1"
}

# Function to check for required Termux packages
check_dependencies() {
    print_info "Checking for required Termux packages..."
    local missing_packages=()
    for pkg in python; do # proot-distro is not strictly needed for the proxy itself
        if ! pkg list-installed | grep -q "^${pkg}/"; then
            missing_packages+=("$pkg")
        fi
    done

    if [ ${#missing_packages[@]} -gt 0 ]; then
        print_warning "The following packages are missing: ${missing_packages[*]}"
        print_question "Attempt to install them now? (y/N)"
        read -r install_choice
        if [[ "$install_choice" =~ ^[Yy]$ ]]; then
            pkg update -y
            pkg upgrade -y
            for pkg in "${missing_packages[@]}"; do
                print_info "Installing $pkg..."
                pkg install "$pkg" -y
                if [ $? -ne 0 ]; then
                    print_error "Failed to install $pkg. Please try again or manually install it."
                    exit 1
                fi
            done
            print_success "All required packages installed."
        else
            print_error "Cannot proceed without required packages. Exiting."
            exit 1
        fi
    else
        print_success "All required Termux packages are installed."
    fi
}

# Function to deploy the main Python proxy script
deploy_proxy_script() {
    print_info "Deploying NetGame Tunnel core script..."
    # The 'EOF_PYTHON_SCRIPT' marker must be on a line by itself, no leading/trailing spaces.
    cat << 'EOF_PYTHON_SCRIPT' > "$HOME/$PROXY_SCRIPT_NAME"
import socket
import threading
import sys
import os
import time

# --- NetGame Tunnel Configuration ---
# The port the proxy server will listen on.
# You will configure your Nintendo Switch to use your phone's IP and this port.
PROXY_PORT = 8888 

# Maximum number of simultaneous connections the proxy can handle.
MAX_CONNECTIONS = 50

# Buffer size for data transfer (in bytes).
BUFFER_SIZE = 4096

# Enable/Disable detailed debug logging. Set to False for less verbose output.
DEBUG_LOGGING = True

# --- Logging Function ---
def log_message(level, message, client_address=None):
    """
    Prints log messages with a specified level (INFO, ERROR, DEBUG, WARNING).
    Includes client address if provided.
    If NETGAMETUNNEL_BACKGROUND environment variable is set, also logs to a file.
    """
    timestamp = time.strftime("%Y-%m-%d %H:%M:%S")
    prefix = f"[{timestamp} NetGame Tunnel {level}]"
    log_output = f"{prefix} ({client_address[0]}:{client_address[1]}) {message}" if client_address else f"{prefix} {message}"
    
    print(log_output) # Always print to console for foreground use

    # Log to file if running in background
    if os.getenv('NETGAMETUNNEL_BACKGROUND') == 'true' and os.getenv('NETGAMETUNNEL_LOG_FILE'):
        try:
            with open(os.getenv('NETGAMETUNNEL_LOG_FILE'), 'a') as f:
                f.write(log_output + "\n")
        except Exception as e:
            # Fallback print if log file cannot be written to
            print(f"[ERROR] Failed to write to log file: {e}")


# --- Data Tunneling Function ---
def tunnel_data(source_socket, destination_socket, client_address, tunnel_id):
    """
    Continuously relays raw data between two sockets in a single direction.
    Robustly handles socket errors and ensures graceful termination of the tunnel.
    """
    try:
        while True:
            data = source_socket.recv(BUFFER_SIZE)
            if not data:
                log_message("DEBUG", f"Tunnel {tunnel_id}: Source socket closed.", client_address)
                break # Source socket closed gracefully
            destination_socket.sendall(data)
    except socket.timeout:
        log_message("WARNING", f"Tunnel {tunnel_id}: Socket timeout during data transfer.", client_address)
    except socket.error as e:
        log_message("ERROR", f"Tunnel {tunnel_id}: Socket error during data transfer: {e}", client_address)
    except Exception as e:
        log_message("ERROR", f"Tunnel {tunnel_id}: Unexpected error during data transfer: {e}", client_address)
    finally:
        log_message("DEBUG", f"Tunnel {tunnel_id}: Data relay finished.", client_address)

# --- Proxy Handler for each Client Connection ---
class ProxyHandler(threading.Thread):
    """
    Handles a single client connection, determining if it's HTTP or HTTPS
    and directing traffic accordingly. Provides robust error handling for each session.
    """
    def __init__(self, client_socket, client_address):
        super().__init__()
        self.client_socket = client_socket
        self.client_address = client_address
        # Set a timeout for reading initial request to prevent hanging connections
        self.client_socket.settimeout(15) # Increased timeout for initial request

    def run(self):
        try:
            # Read the initial request data
            initial_data = self.client_socket.recv(BUFFER_SIZE)
            if not initial_data:
                log_message("WARNING", "Received empty initial request.", self.client_address)
                return # Empty request

            request_line = initial_data.decode('latin-1').split('\n')[0]
            log_message("INFO", f"Incoming request: {request_line}", self.client_address)

            parts = request_line.split(' ')

            if len(parts) < 3:
                log_message("ERROR", f"Invalid request format: {request_line}", self.client_address)
                self.client_socket.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
                return

            method = parts[0].upper() # Convert method to uppercase for consistency
            target_url = parts[1]

            if method == "CONNECT":
                self.handle_connect_method(target_url)
            else:
                self.handle_http_method(initial_data)

        except socket.timeout:
            log_message("ERROR", "Client connection timed out during initial request.", self.client_address)
        except socket.error as e:
            log_message("ERROR", f"Socket error during client handling: {e}", self.client_address)
        except Exception as e:
            log_message("ERROR", f"Unexpected error in proxy handler: {e}", self.client_address)
        finally:
            try:
                self.client_socket.shutdown(socket.SHUT_RDWR) # Attempt graceful shutdown
                self.client_socket.close()
                log_message("DEBUG", "Client socket closed.", self.client_address)
            except OSError as e:
                log_message("DEBUG", f"Error during client socket shutdown/close (might be already closed): {e}", self.client_address)
            except Exception as e:
                log_message("ERROR", f"Error during final client socket cleanup: {e}", self.client_address)

    def handle_connect_method(self, target_url):
        """
        Handles HTTPS (SSL/TLS) tunneling requests using the CONNECT method.
        This simply relays raw encrypted data between client and remote server.
        """
        try:
            host, port_str = target_url.split(':')
            port = int(port_str)
        except ValueError:
            log_message("ERROR", f"Invalid CONNECT target URL format: {target_url}", self.client_address)
            self.client_socket.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            return

        remote_socket = None
        try:
            log_message("INFO", f"Establishing secure tunnel (CONNECT) to {host}:{port}", self.client_address)
            remote_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            remote_socket.settimeout(15) # Timeout for remote connection establishment
            remote_socket.connect((host, port))
            remote_socket.settimeout(None) # Remove timeout for tunneling phase

            # Inform the client (Switch) that the tunnel is established
            self.client_socket.sendall(b"HTTP/1.1 200 Connection established\r\nProxy-Agent: NetGame Tunnel\r\n\r\n")
            log_message("INFO", f"Tunnel established to {host}:{port}. Relaying data...", self.client_address)

            # Create two threads for bidirectional data tunneling
            # Assign unique IDs for better logging
            tunnel_id_client_to_remote = f"CR-{threading.get_ident()}"
            tunnel_id_remote_to_client = f"RC-{threading.get_ident()}"

            client_to_remote_thread = threading.Thread(target=tunnel_data, 
                                                       args=(self.client_socket, remote_socket, self.client_address, tunnel_id_client_to_remote))
            remote_to_client_thread = threading.Thread(target=tunnel_data, 
                                                       args=(remote_socket, self.client_socket, self.client_address, tunnel_id_remote_to_client))

            client_to_remote_thread.start()
            remote_to_client_thread.start()

            # Wait for both tunneling threads to finish (i.e., connections close)
            client_to_remote_thread.join()
            remote_to_client_thread.join()

        except socket.timeout:
            log_message("ERROR", f"Timeout connecting to remote server {host}:{port} for CONNECT.", self.client_address)
            self.client_socket.sendall(b"HTTP/1.1 504 Gateway Timeout\r\n\r\n")
        except socket.gaierror as e: # Hostname resolution error
            log_message("ERROR", f"DNS resolution failed for {host}:{port} (CONNECT): {e}", self.client_address)
            self.client_socket.sendall(b"HTTP/1.1 503 Service Unavailable\r\n\r\n")
        except socket.error as e:
            log_message("ERROR", f"Failed CONNECT tunnel to {host}:{port}: {e}", self.client_address)
            self.client_socket.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        except Exception as e:
            log_message("ERROR", f"Unexpected error in CONNECT method for {host}:{port}: {e}", self.client_address)
            self.client_socket.sendall(b"HTTP/1.1 500 Internal Server Error\r\n\r\n")
        finally:
            if remote_socket:
                try:
                    remote_socket.shutdown(socket.SHUT_RDWR)
                    remote_socket.close()
                    log_message("DEBUG", "Remote socket closed for CONNECT.", self.client_address)
                except OSError as e:
                    log_message("DEBUG", f"Error during remote socket shutdown/close (CONNECT): {e}", self.client_address)
                except Exception as e:
                    log_message("ERROR", f"Error during final remote socket cleanup (CONNECT): {e}", self.client_address)


    def handle_http_method(self, initial_data):
        """
        Handles standard HTTP (GET, POST, etc.) requests by parsing the URL
        and forwarding the request to the remote server.
        """
        full_request_str = initial_data.decode('latin-1')
        request_lines = full_request_str.split('\n')
        first_line = request_lines[0]
        
        parts = first_line.split(' ')
        method = parts[0]
        target_url = parts[1]
        http_version = parts[2]

        if not target_url.lower().startswith('http://'):
            log_message("ERROR", f"Non-HTTP URL format in HTTP method: {target_url}", self.client_address)
            self.client_socket.sendall(b"HTTP/1.1 400 Bad Request\r\n\r\n")
            return

        # Extract host and path from the absolute URL
        url_path = target_url[7:] # Remove http://
        host_end = url_path.find('/')
        if host_end == -1:
            host_port = url_path
            path = '/'
        else:
            host_port = url_path[:host_end]
            path = url_path[host_end:]

        host_parts = host_port.split(':')
        host = host_parts[0]
        port = 80 if len(host_parts) == 1 else int(host_parts[1])

        remote_socket = None
        try:
            log_message("INFO", f"Proxying HTTP request to {host}:{port}{path}", self.client_address)
            remote_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            remote_socket.settimeout(15) # Timeout for remote connection establishment
            remote_socket.connect((host, port))
            remote_socket.settimeout(None) # Remove timeout for tunneling phase

            # Reconstruct the request for the remote server (relative path)
            # Remove Proxy-Connection header if present and add Proxy-Agent
            modified_request_lines = []
            for line in request_lines:
                if line.lower().startswith('proxy-connection:'):
                    continue # Skip proxy-specific header
                if line.strip() == '': # End of headers
                    modified_request_lines.append(f"Proxy-Agent: NetGame Tunnel\r") # Add our agent
                modified_request_lines.append(line)
            
            # Replace the absolute URL with relative path for the remote server
            modified_request_lines[0] = f"{method} {path} {http_version}"
            
            modified_request_str = "\n".join(modified_request_lines)
            
            remote_socket.sendall(modified_request_str.encode('latin-1'))
            log_message("DEBUG", f"Forwarded HTTP request to {host}:{port}", self.client_address)

            # Relay the response from the remote server back to the client
            tunnel_id_remote_to_client = f"RC-{threading.get_ident()}"
            tunnel_data(remote_socket, self.client_socket, self.client_address, tunnel_id_remote_to_client)

        except socket.timeout:
            log_message("ERROR", f"Timeout connecting to remote server {host}:{port} for HTTP.", self.client_address)
            self.client_socket.sendall(b"HTTP/1.1 504 Gateway Timeout\r\n\r\n")
        except socket.gaierror as e: # Hostname resolution error
            log_message("ERROR", f"DNS resolution failed for {host}:{port} (HTTP): {e}", self.client_address)
            self.client_socket.sendall(b"HTTP/1.1 503 Service Unavailable\r\n\r\n")
        except socket.error as e:
            log_message("ERROR", f"Failed to proxy HTTP request to {host}:{port}: {e}", self.client_address)
            self.client_socket.sendall(b"HTTP/1.1 502 Bad Gateway\r\n\r\n")
        except Exception as e:
            log_message("ERROR", f"Unexpected error in HTTP method for {host}:{port}: {e}", self.client_address)
            self.client_socket.sendall(b"HTTP/1.1 500 Internal Server Error\r\n\r\n")
        finally:
            if remote_socket:
                try:
                    remote_socket.shutdown(socket.SHUT_RDWR)
                    remote_socket.close()
                    log_message("DEBUG", "Remote socket closed for HTTP.", self.client_address)
                except OSError as e:
                    log_message("DEBUG", f"Error during remote socket shutdown/close (HTTP): {e}", self.client_address)
                except Exception as e:
                    log_message("ERROR", f"Error during final remote socket cleanup (HTTP): {e}", self.client_address)

# --- Main Server Loop ---
def start_net_game_tunnel():
    """
    Initializes and starts the NetGame Tunnel proxy server.
    Handles graceful shutdown and ensures the server is always listening for new connections.
    """
    # Print initial startup messages and ASCII art
    # ASCII art is handled by the wrapper script for better display control
    log_message("INFO", "Welcome to NetGame Tunnel! Initiating proxy service...")
    log_message("INFO", f"Proxy server will listen for connections on port {PROXY_PORT}.")
    log_message("INFO", "----------------------------------------------------------------------")
    log_message("INFO", "NetGame Tunnel provides a robust proxy for your Nintendo Switch.")
    log_message("INFO", "It correctly handles secure (HTTPS) connections, resolving authentication issues.")
    log_message("INFO", "----------------------------------------------------------------------")
    log_message("INFO", "NON-ROOT LIMITATION: Android's native hotspot does NOT route client")
    log_message("INFO", "                     traffic through a device-wide VPN. This tool provides")
    log_message("INFO", "                     a robust proxy for your Switch's traffic directly.")
    log_message("INFO", "----------------------------------------------------------------------")
    log_message("INFO", "Configure your Nintendo Switch to use your phone's hotspot IP and this proxy port.")
    log_message("INFO", "To stop NetGame Tunnel gracefully, use the 'install_netgametunnel.sh' menu (Option 2).")
    log_message("INFO", "----------------------------------------------------------------------")

    server_socket = None
    try:
        server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1) # Allow reusing address
        server_socket.bind(('', PROXY_PORT)) # Bind to all available network interfaces
        server_socket.listen(MAX_CONNECTIONS)
        log_message("INFO", f"NetGame Tunnel is now active and listening on port {PROXY_PORT}...")

        while True:
            client_socket, client_address = server_socket.accept()
            log_message("INFO", f"Accepted new connection from: {client_address}")
            # Handle each client connection in a new thread
            handler = ProxyHandler(client_socket, client_address)
            handler.start()

    except KeyboardInterrupt:
        log_message("INFO", "NetGame Tunnel received Ctrl+C. Initiating graceful shutdown...")
    except Exception as e:
        log_message("ERROR", f"Fatal error starting NetGame Tunnel: {e}")
    finally:
        if server_socket:
            try:
                server_socket.shutdown(socket.SHUT_RDWR) # Attempt graceful shutdown
                server_socket.close()
                log_message("INFO", "Server socket closed gracefully.")
            except OSError as e:
                log_message("ERROR", f"Error during server socket shutdown/close: {e}")
        # Termux wake lock will be handled by the calling script (install_netgametunnel.sh)
        log_message("INFO", "NetGame Tunnel has stopped.")

if __name__ == "__main__":
    start_net_game_tunnel()
EOF_PYTHON_SCRIPT
    print_success "NetGame Tunnel core script deployed to $HOME/$PROXY_SCRIPT_NAME."
    chmod +x "$HOME/$PROXY_SCRIPT_NAME" # Ensure it's executable, though python runs it
}

# Function to start the proxy
start_proxy() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null; then
            print_warning "NetGame Tunnel is already running (PID: $PID)."
            return
        else
            print_warning "Stale PID file found. Cleaning up."
            rm "$PID_FILE"
        fi
    fi

    print_info "Starting NetGame Tunnel..."
    # Acquire Termux wake lock before starting
    termux-wake-lock
    
    # Run the Python script in the background, redirecting output to log file
    # Set environment variables for the Python script to know it's in background
    NETGAMETUNNEL_BACKGROUND='true' NETGAMETUNNEL_LOG_FILE="$LOG_FILE" nohup python "$HOME/$PROXY_SCRIPT_NAME" > "$LOG_FILE" 2>&1 &
    
    PID=$! # Get the PID of the last background command
    echo "$PID" > "$PID_FILE"
    print_success "NetGame Tunnel started in the background (PID: $PID). Check logs with option 3."
    print_info "You can now safely close Termux. NetGame Tunnel will continue running."
}

# Function to stop the proxy
stop_proxy() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null; then
            print_info "Stopping NetGame Tunnel (PID: $PID)..."
            kill "$PID"
            # Give it a moment to shut down gracefully
            sleep 2
            if ! ps -p "$PID" > /dev/null; then
                print_success "NetGame Tunnel stopped successfully."
                rm "$PID_FILE"
            else
                print_error "Failed to stop NetGame Tunnel. You might need to kill it manually: kill -9 $PID"
            fi
        else
            print_warning "NetGame Tunnel is not running, or PID file is stale. Cleaning up."
            rm "$PID_FILE"
        fi
    else
        print_info "NetGame Tunnel is not running (no PID file found)."
    fi
    # Release Termux wake lock after stopping
    termux-wake-unlock
}

# Function to check proxy status
check_status() {
    if [ -f "$PID_FILE" ]; then
        PID=$(cat "$PID_FILE")
        if ps -p "$PID" > /dev/null; then
            print_success "NetGame Tunnel is RUNNING (PID: $PID)."
            print_info "Last 10 lines of log file ($LOG_FILE):"
            if [ -f "$LOG_FILE" ]; then
                tail -n 10 "$LOG_FILE"
            else
                print_warning "Log file not found. Proxy might have just started or encountered an error."
            fi
        else
            print_warning "NetGame Tunnel is NOT RUNNING, but a stale PID file was found. Cleaning up."
            rm "$PID_FILE"
            print_info "No active NetGame Tunnel process found."
        fi
    else
        print_info "NetGame Tunnel is NOT RUNNING (no PID file found)."
    fi
}

# --- Main Logic ---

# Display ASCII art only once at the very beginning of the script execution
echo "$ASCII_ART"

# Initial setup: check dependencies and deploy script
check_dependencies
deploy_proxy_script

# Main menu loop
while true; do
    echo -e "\n----------------------------------------------------------------------"
    print_info "NetGame Tunnel Main Menu"
    echo "----------------------------------------------------------------------"
    echo "1. Start NetGame Tunnel"
    echo "2. Stop NetGame Tunnel"
    echo "3. Check NetGame Tunnel Status"
    echo "4. Exit"
    echo "----------------------------------------------------------------------"
    print_question "Enter your choice (1-4):"
    read -r choice

    case "$choice" in
        1) start_proxy ;;
        2) stop_proxy ;;
        3) check_status ;;
        4) print_info "Exiting NetGame Tunnel menu. Goodbye!"; break ;;
        *) print_error "Invalid choice. Please enter a number between 1 and 4." ;;
    esac # Fixed: Changed 'es_ac' to 'esac'
done

exit 0

