# Wireguard Server Setup For Ubuntu 19.04, With Local DNS Resolution
#
# Instructions:
#    Run this script as root. Use -h to see input arguments
#
#    I would recommend testing the script/installation before deploying onto a 
#    server with actual data. Changing the DNS configuration (which this script does)
#    is an easy way to bork your system (you might be able to fix it, but it's just easier to 
#    start fresh from a new image). Everything in the script works now, but who knows
#    what will change in the future.
#
# Sources:
#    1) https://www.ckn.io/blog/2017/11/14/wireguard-vpn-typical-setup
#    2) https://grh.am/2018/wireguard-setup-guide-for-ios/
#

setup_wireguard_server() {
    # Wireguard isn't part of the Ubuntu packages, so we have to add it.
    add-apt-repository -y ppa:wireguard/wireguard 
    apt-get -y update 
    # Wireguard requries headers for the linux kernel, so we need to install them too.
    apt-get install -y wireguard-dkms wireguard-tools linux-headers-$(uname -r)
    # Install a QR code generator, used for rendering client connection config as qr code.
    apt install -y qrencode 

    # Generate server keys
    umask 077
    wg genkey | tee /etc/wireguard/server-privatekey | wg pubkey > /etc/wireguard/server-publickey

    # Set server config
    server_private_key=$(cat /etc/wireguard/server-privatekey)
    cat > /etc/wireguard/$wg_name.conf <<- EOF
		[Interface]
		Address = 10.0.0.1/24
		SaveConfig = true
		PostUp = iptables -A FORWARD -i $wg_name -j ACCEPT; iptables -t nat -A POSTROUTING -o eth0 -j MASQUERADE; iptables -A INPUT -s 10.0.0.0/24 -p tcp -m tcp --dport 53 -m conntrack --ctstate NEW -j ACCEPT; iptables -A INPUT -s 10.0.0.0/24 -p udp -m udp --dport 53 -m conntrack --ctstate NEW -j ACCEPT
		PostDown = iptables -D FORWARD -i $wg_name -j ACCEPT; iptables -t nat -D POSTROUTING -o eth0 -j MASQUERADE;
		ListenPort = $listen_port
		PrivateKey = $server_private_key
	EOF

    # Set up local DNS Server
    apt-get install -y unbound unbound-host
    curl -o /var/lib/unbound/root.hints https://www.internic.net/domain/named.cache

    # Set unbound dns config
    cat > /etc/unbound/unbound.conf <<- EOF
		server:
		    num-threads: 4

		    #Enable logs
		    verbosity: 1

		    #list of Root DNS Server
		    root-hints: "/var/lib/unbound/root.hints"

		    #Use the root servers key for DNSSEC
		    auto-trust-anchor-file: "/var/lib/unbound/root.key"

		    #Respond to DNS requests on all interfaces
		    interface: 0.0.0.0
		    max-udp-size: 3072

		    #Authorized IPs to access the DNS Server
		    access-control: 0.0.0.0/0                 refuse
		    access-control: 127.0.0.1                 allow
		    access-control: 10.0.0.0/24         allow

		    #not allowed to be returned for public internet  names
		    private-address: 10.0.0.0/24

		    # Hide DNS Server info
		    hide-identity: yes
		    hide-version: yes

		    #Limit DNS Fraud and use DNSSEC
		    harden-glue: yes
		    harden-dnssec-stripped: yes
		    harden-referral-path: yes

		    #Add an unwanted reply threshold to clean the cache and avoid when possible a DNS Poisoning
		    unwanted-reply-threshold: 10000000

		    #Have the validator print validation failures to the log.
		    val-log-level: 1

		    #Minimum lifetime of cache entries in seconds
		    cache-min-ttl: 1800

		    #Maximum lifetime of cached entries
		    cache-max-ttl: 14400
		    prefetch: yes
		    prefetch-key: yes
	EOF

    # Stop Ubuntu's built in dns tool: systemd-resolved
    systemctl disable --now systemd-resolved.service
    rm /etc/resolv.conf
    echo "nameserver 127.0.0.1" > /etc/resolv.conf

    # Allow unbound to read its stuff
    chown -R unbound:unbound /var/lib/unbound
    systemctl enable unbound

    # Enable IPV4 Forwarding: uncomment 'net.ipv4.ip_forward=1' in the config
    sed -i '/net.ipv4.ip_forward/c\net.ipv4.ip_forward=1' /etc/sysctl.conf
    sysctl -p
    echo 1 > /proc/sys/net/ipv4/ip_forward

    systemctl enable wg-quick@$wg_name  # Enable to start at boot-up
    systemctl start wg-quick@$wg_name  # Start Wireguard

    # Configure the wireguard folder to require admin privileges (only root can read)
    chmod 600 /etc/wireguard
}

setup_client() {
    # Shutdown the wireguard server
    wg-quick down $wg_name > /dev/null

	# Generate client keys
	umask 077
    wg genkey | tee /etc/wireguard/$client_name-privatekey | wg pubkey > /etc/wireguard/$client_name-publickey	

    # Generate client IP Address, only support less than 254 peers for now
    let ip_lsb8=$(grep "Peer" /etc/wireguard/$wg_name.conf | wc -l)+2
    client_ip="10.0.0.$ip_lsb8/32"

	# Add client to wirguard config
    client_public_key=$(cat /etc/wireguard/$client_name-publickey)
    cat >> /etc/wireguard/$wg_name.conf <<- EOF
		
		[Peer]
		# $client_name
		PublicKey = $client_public_key
		AllowedIPs = $client_ip
	EOF

    # Create client config
    client_private_key=$(cat /etc/wireguard/$client_name-privatekey)
    server_public_key=$(cat /etc/wireguard/server-publickey)
    server_port=$(grep "ListenPort" /etc/wireguard/$wg_name.conf | cut -d " " -f3)
    cat > /etc/wireguard/$client_name.conf <<- EOF
		[Interface]
		PrivateKey = $client_private_key
		Address = $client_ip
		DNS = 10.0.0.1

		[Peer]
		PublicKey = $server_public_key
		Endpoint = $server_ip_address:$server_port
		AllowedIPs = 0.0.0.0/0
	EOF
    
    # Start up the wireguard server
    wg-quick up $wg_name > /dev/null

    # Check if qrencode package is installed, if not, install it.
    dpkg -s qrencode 1>/dev/null 2>/dev/null || apt-get install qrencode -y
    qrencode -t ansiutf8 < /etc/wireguard/$client_name.conf
}


print_usage() {
  printf "Usage: wireguard-setup.sh [options...]
  [-s], set up and run wireguard with local dns resolution.
  [-c client_name], create a wireguard client with given name, no spaces.
  [-a public_ip], set the public IP for your Wireguard server (only used for server or client setup). 
  [-p port], set listening port, overrides default of 443 (only used for server or client setup).
  [-w interface_name], name the wireguard interface, no spaces (used during server setup).
"
}

try_to_find_server_ip() {
    # Finding the ip address is pretty fragile
    if [ -z "$server_ip_address" ]; then
        hostname -I >/dev/null 2>/dev/null
        if [ $? -ne 0 ]; then 
            printf "Finding server IP address failed. You must pass this in manually.\n\n"
            print_usage
            exit 1
        fi
        server_ip_address=$(hostname -I | cut -d " " -f1)
    fi
}

prompt_for_restart() {
    # Prompt for restart
    read -r -p "A restart is required (or else DNS won't work). Would you like to restart now? [y/N] " response
    if [[ "$response" =~ ^([yY][eE][sS]|[yY])+$ ]]
    then
        shutdown -r -h now
    fi
}

client_name=''
server_ip_address=''
listen_port='443'
wg_name='wg0'

# Before handling the arguments, check to see if both the -s and -c flags are
# passed. This will impact when the prompt to restart is displayed.
x=0
while getopts 'sc' flag; do
    case "${flag}" in
    s) x=$((x+1)) ;;
    c) x=$((x+1)) ;;
    esac
done
OPTIND=1 # reset OPTIND to it's intial value so that we can read the options again, below

# Actually handling the arguments
while getopts 'a:c:hp:sw:' flag; do
    case "${flag}" in
    a) server_ip_address="${OPTARG}" ;;
    p) listen_port="${OPTARG}" ;;
    w) wg_name="${OPTARG}" ;;
    s) try_to_find_server_ip
        # If a command fails, stop running the script
        set -o errexit
        setup_wireguard_server
        if [ $x -ne 2 ]; then prompt_for_restart; fi ;; # prompt for restart later, after client created
    c) client_name="${OPTARG}"
        try_to_find_server_ip
        # If a command fails, stop running the script
        set -o errexit
        setup_client
        if [ $x -eq 2 ]; then prompt_for_restart; fi ;; # earlier we had skipped the restart, now is time to ask.
    *) print_usage
        exit 1 ;;
    esac
done
if [ $OPTIND -eq 1 ]; then echo "No options were passed"; print_usage; fi
