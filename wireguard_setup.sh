# Wireguard Server Setup For Ubuntu 19.04
#
# Instructions:
#    Run this script as root. Use -h to see input arguments
#
#    There are two installation modes:
#      1) (Default) Install with basic DNS settings: DNS requests from the client are tunneled to 
#         the server and then forwarded on to the configured DNS server (e.g. Cloudflare's 1.1.1.1).
#      2) Hosted DNS: Advanced installation, installs the 'unbound' DNS cache / resolver onto the 
#         server. This modifies the default DNS settings of the server (typically, the default 
#         configuration is for the server to send DNS requests to some external server to handle. 
#         By selecting this install mode, your server will perform DNS resolution and caching on 
#         its own). DNS requests from the client are sent to the server, and the server resolves the
#         DNS query.
#
#    Note On The Advanced Installation:
#        I would recommend testing the script/installation before deploying onto a server with 
#        actual data. Changing the DNS configuration (which this script does) is an easy way to 
#        bork your system (you might be able to fix it, but it's just easier to start fresh from a 
#        new image). Everything in the script works now, but who knows what will change in the 
#        future.
#
#   Understanding the .conf [Peer] DNS
#        Due to Wireguard's minimal documentation, it's unclear whether the client will directly 
#        contact the DNS resolver, or if its DNS requests will first be tunneled through the 
#        Wireguard server and then onto the DNS resolver.
# 
#        To figure out how this configuration parameter works I ran two tests. For the first, I
#        turned off the VPN on my client and configured its operating system to use my server as a 
#        DNS resolver. For the second, I turned on the VPN client and set the Wireguard client's 
#        DNS configuration parameter to use the same server as a DNS resolver.
#        For both tests, I ran netcat on the server to listen for the incoming DNS UDP packets.
#            Sidenote: you need the GNU version of netcat (nc).
#                apt-get install netcat
#                update-alternatives --config nc 
#                choose netcat.traditional
#        By running `nc -u -l 0.0.0.0 -p 53 -k -vv -n` I could listen for DNS requests and see the 
#        sender's IP addresses.
#        For the first test, I saw the DNS request coming from my client device's public IP. This is
#        the control case and was expected.
#        For the second test, I saw the DNS request coming from a LAN IP (e.g. 10.0.0.2). The 
#        client's public IP address is not shown in the DNS request, proving that the DNS requests
#        are being tunneled through the server.
#        
#
# Sources:
#    1) https://www.ckn.io/blog/2017/11/14/wireguard-vpn-typical-setup
#    2) https://grh.am/2018/wireguard-setup-guide-for-ios/
#

setup_unbound_dns() {
    # Note: After running this you need to restart in order for the DNS changes to be applied.

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
}

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
    client_dns=$dns_ip
    if [ "$hosted_dns" = true ]; then client_dns='10.0.0.1'; fi
    cat > /etc/wireguard/$client_name.conf <<- EOF
		[Interface]
		PrivateKey = $client_private_key
		Address = $client_ip
		DNS = $client_dns

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
          See other flags below for default configuration.
  [-c client_name [-a] | [-d ip_addr] | [-w wg_name]], create a wireguard client with given name, no spaces.
          Specifying the '[-d ip_addr]' flag will configure the client to use the provided IP 
          as its DNS resolver.
          Specifying the '-a' flag will configure the client to use the server as a DNS resolver.
          '-a' Takes precedence over '-d'.
          If neither '-a' or '-d' are given, then the client will be configured to use 1.1.1.1 for
          DNS resolution.
          If '-w' is not supplied, by default the client will be created on wg0
  [-i ip_addr], set the public IP for the Wireguard server (only used for server or client setup). 
  [-p port], set listening port, (only used for server or client setup. Cannot re-configure the 
          server).
          Default is port 443.
  [-w interface_name], name the wireguard interface, no spaces (used during server setup).
          Default is 'wg0'.
  [-a], enable advanced DNS mode. DNS will be resolved by the server. Takes precedence over '-d'.
          Disabled by default.
  [-d ip_addr], set the basic installation's DNS server IP (used for clients). 
          Default is 1.1.1.1
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
create_wg_interface='false'
create_client='false'
hosted_dns='false'
dns_ip='1.1.1.1'

# Actually handling the arguments
while getopts 'ac:d:i:hp:sw:' flag; do
    case "${flag}" in
    a) hosted_dns='true' ;;
    c) create_client='true'; client_name="${OPTARG}"; x=$((x+1)) ;;
    d) dns_ip="${OPTARG}" ;;
    i) server_ip_address="${OPTARG}" ;;
    p) listen_port="${OPTARG}" ;;
    s) create_wg_interface='true'; x=$((x+1)) ;;
    w) wg_name="${OPTARG}" ;;
    *) print_usage; exit 1 ;;
    esac
done
if [ $OPTIND -eq 1 ]; then echo "No options were passed"; print_usage; fi

if [ "$create_wg_interface" = true ]; then
    try_to_find_server_ip
        # If a command fails, stop running the script
        set -o errexit
        setup_wireguard_server
        if [ "$hosted_dns" = true ]; then setup_unbound_dns; fi
        if [ $x -ne 2 ]; then prompt_for_restart; fi # if flase, prompt for restart later, after client created
fi

if [ "$create_client" = true ]; then
    try_to_find_server_ip
    # If a command fails, stop running the script
    set -o errexit
    setup_client
    if [ $x -eq 2 ]; then prompt_for_restart; fi # earlier we had skipped the restart, now is time to ask.
fi

