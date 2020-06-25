#!/bin/bash

# original script posted by tpretz at https://www.reddit.com/r/PrivateInternetAccess/comments/g08ojr/is_wireguard_available_yet/fnvs20c/
# and at https://gist.github.com/tpretz/5ea1226517d95361f063f621e45de0a6
#
# significantly modified by Triffid_Hunter
#
# Improved with suggestions from Threarah at https://www.reddit.com/r/PrivateInternetAccess/comments/h9y4da/is_there_any_way_to_generate_wireguard_config/fv3cgi9/
#
# After the first run to fetch various data files and an auth token, this script does not require the ability to DNS resolve privateinternetaccess.com

if ! which jq &>/dev/null
then
	echo "The 'jq' utility is required"
	echo "    Most package managers should have a 'jq' package available"
	EXIT=1
fi

if ! which ip &>/dev/null
then
	echo "The 'ip' utility from iproute2 is required"
	echo "    Most package managers should have a 'iproute2' package available"
	EXIT=1
fi

if ! which wg &>/dev/null
then
	echo "The 'wg' utility from wireguard/wireguard-tools is required"
	echo "    Most package managers should have 'wireguard' or 'wireguard-tools' packages available"
	EXIT=1
fi

[ -n "$EXIT" ] && exit 1

if [ -z "$CONFIGDIR" ]
then
	CONFIGDIR="$HOME/.config/pia-wg"
	mkdir -p "$CONFIGDIR"
fi

if [ -z "$CONFIG" ]
then
	CONFIG="$CONFIGDIR/pia-wg.conf"
fi

if [ -r "$CONFIG" ]
then
	source "$CONFIG"
fi

if [ -z "$CLIENT_PRIVATE_KEY" ]
then
	echo "Generating new private key"
	CLIENT_PRIVATE_KEY="$(wg genkey)"
fi

if [ -z "$CLIENT_PUBLIC_KEY" ]
then
	CLIENT_PUBLIC_KEY=$(wg pubkey <<< "$CLIENT_PRIVATE_KEY")
fi

if [ -z "$CLIENT_PUBLIC_KEY" ]
then
	echo "Failed to generate client public key, check your config!"
	exit 1
fi

if [ -z "$LOC" ]
then
	echo "Setting default location: US (any, using pattern match)"
	LOC="us"
fi

if [ -z "$PIA_INTERFACE" ]
then
	echo "Setting default wireguard interface name: pia"
	PIA_INTERFACE="pia"
fi

if [ -z "$PIA_CERT" ]
then
	PIA_CERT="$CONFIGDIR/rsa_4096.crt"
fi

if [ -z "$TOKENFILE" ]
then
	TOKENFILE="$CONFIGDIR/.token"
fi

if [ -z "$DATAFILE" ]
then
	DATAFILE="$CONFIGDIR/data.json"
fi

if [ -z "$REMOTEINFO" ]
then
	REMOTEINFO="$CONFIGDIR/remote.info"
fi

# get token
if [ -z "$TOK" ] && [ -r "$TOKENFILE" ]
then
	TOK=$(< "$TOKENFILE")
fi

# echo "$TOK"

if [ -z "$TOK" ] && ([ -z "$USER" ] || [ -z "$PASS" ])
then
	if [ -z "$USER" ]
	then
		read -p "Please enter your privateinternetaccess.com username: " USER
	fi
	if [ -z "$PASS" ]
	then
		echo "If you do not wish to save your password, and want to be asked every time an auth token is required, simply press enter now"
		read -p "Please enter your privateinternetaccess.com password: " -s PASS
	fi
	cat <<ENDCONFIG > "$CONFIG"
# your privateinternetaccess.com username (not needed if you already have an auth token)
USER="$USER"
# your privateinternetaccess.com password (not needed if you already have an auth token)
PASS="$PASS"

# your desired endpoint location
LOC="$LOC"

# the name of the network interface (default: pia)
# PIA_INTERFACE="$PIA_INTERFACE"

# wireguard client-side private key (new key generated every invocation if not specified)
CLIENT_PRIVATE_KEY="$CLIENT_PRIVATE_KEY"

ENDCONFIG
	echo "Config saved"
fi

# fetch data.json if missing
if ! [ -r "$DATAFILE" ]
then
	echo "Fetching wireguard server list from PIA"
	# wget -O "$DATAFILE" 'https://raw.githubusercontent.com/pia-foss/desktop/master/tests/res/openssl/payload1/payload' || exit 1
	curl 'https://www.privateinternetaccess.com/vpninfo/servers?version=1001&client=x-alpha' > "$DATAFILE.temp" || exit 1
	if [ "$(jq 'map_values(select(.wireguard)) | keys' "$DATAFILE.temp" 2>/dev/null | wc -l)" -le 50 ]
	then
		echo "Bad serverlist retrieved to $DATAFILE.temp, exiting"
		echo "You can try again if there was a transient error"
		exit 1
	else
		jq -cM 'map_values(select(.wireguard))' "$DATAFILE.temp" > "$DATAFILE" 2>/dev/null
	fi
fi

if [ "$(jq -r ".$LOC.wireguard" "$DATAFILE")" == "null" ]
then
	# echo "No exact match for location \"$LOC\" trying pattern"
	# from https://unix.stackexchange.com/questions/443884/match-keys-with-regex-in-jq/443927#443927
	LOC=$(jq 'with_entries(if (.key|test("^'"$LOC"'")) then ( {key: .key, value: .value } ) else empty end ) | keys' "$DATAFILE" | grep ^\  | cut -d\" -f2 | shuf -n 1)
fi

if ! [ -r "$PIA_CERT" ]
then
	echo "Fetching PIA self-signed cert from github"
	curl 'https://raw.githubusercontent.com/pia-foss/desktop/master/daemon/res/ca/rsa_4096.crt' > "$PIA_CERT" || exit 1
fi

if [ "$(jq -r ".$LOC.wireguard" "$DATAFILE")" == "null" ]
then
	echo "Location $LOC not found!"
	echo "Options are:"
	jq 'map_values(select(.wireguard)) | keys' "$DATAFILE"
	echo
	echo "Please edit $CONFIG and change your desired location, then try again"
	exit 1
fi

if [ -z "$TOK" ]
then
	if [ -z "$PASS" ]
	then
		echo "A new auth token is required, and you have not saved your password."
		echo "Your password will NOT be saved if you enter it now."
		read -p "Please enter your privateinternetaccess.com password for $USER: " -s PASS
	fi
	TOK=$(curl -X POST \
	-H "Content-Type: application/json" \
	-d "{\"username\":\"$USER\",\"password\":\"$PASS\"}" \
	"https://www.privateinternetaccess.com/api/client/v2/token" | jq -r '.token')

	echo "got token: $TOK"
fi

if [ -z "$TOK" ]; then
  echo "Failed to authenticate with privateinternetaccess"
  exit 1
fi

touch "$TOKENFILE"
chmod 600 "$TOKENFILE"
echo "$TOK" > "$TOKENFILE"

WG_NAME="$(jq -r ".$LOC.name" "$DATAFILE")"
WG_DNS="$(jq -r ".$LOC.dns" "$DATAFILE")"
WG_URL="$(jq -r ".$LOC.wireguard.host" "$DATAFILE")"
WG_SERIAL="$(jq -r ".$LOC.wireguard.serial" "$DATAFILE")"
WG_SN="$(cut -d. -f1 <<< "$WG_DNS")"
WG_HOST="$(cut -d: -f1 <<< "$WG_URL")"
WG_PORT="$(cut -d: -f2 <<< "$WG_URL")"

if [ -z "$WG_URL" ]; then
  echo "no wg region, exiting"
  exit 1
fi

echo "Registering public key with $WG_NAME ($WG_HOST)"

curl -GsS \
  --max-time 5 \
  --data-urlencode "pubkey=$CLIENT_PUBLIC_KEY" \
  --data-urlencode "pt=$TOK" \
  --cacert "$PIA_CERT" \
  --resolve "$WG_SERIAL:$WG_PORT:$WG_HOST" \
  "https://$WG_SERIAL:$WG_PORT/addKey" > "$REMOTEINFO.temp" \
  || (
	echo "Failed to register key with $WG_SN ($WG_HOST)"
	if ip link list "$PIA_INTERFACE" > /dev/null
	then
		echo "If you're trying to change hosts because your link has stopped working,"
		echo "  you may need to "$'\x1b[1m'"ip link del dev $PIA_INTERFACE"$'\x1b[0m'" and try this script again"
	fi
	exit 1
)

if [ "$(jq -r .status "$REMOTEINFO.temp")" != "OK" ]
then
	echo "WG key registration failed - bad token?"
	echo "If you see an auth error, consider deleting $TOKENFILE and getting a new token"
	exit 1
fi

mv  "$REMOTEINFO.temp" \
	"$REMOTEINFO"

PEER_IP="$(jq -r .peer_ip "$REMOTEINFO")"
SERVER_PUBLIC_KEY="$(jq -r .server_key  "$REMOTEINFO")"
SERVER_IP="$(jq -r .server_ip "$REMOTEINFO")"
SERVER_PORT="$(jq -r .server_port "$REMOTEINFO")"
SERVER_VIP="$(jq -r .server_vip "$REMOTEINFO")"

if [ -z "$WGCONF" ]
then
	WGCONF="$CONFIGDIR/${PIA_INTERFACE}.conf"
fi

# echo "Generating $WGCONF"
# echo

cat > "$WGCONF" <<ENDWG
[Interface]
PrivateKey = $CLIENT_PRIVATE_KEY
Address    = $PEER_IP
Table      = off
DNS        = $(jq -r '.dns_servers[0:2]' "$REMOTEINFO" | grep ^\  | cut -d\" -f2 | xargs echo | sed -e 's/ /,/g')

[Peer]
PublicKey  = $SERVER_PUBLIC_KEY
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint   = $SERVER_IP:$SERVER_PORT
ENDWG

# echo
# echo "OK"

# echo "Bringing up wireguard interface $PIA_INTERFACE... "
if [ "$EUID" -eq 0 ]
then
	# scratch current config if any
	# put new settings into existing interface instead of teardown/re-up to prevent leaks
	if ip link list "$PIA_INTERFACE" > /dev/null
	then
		echo "Updating existing interface '$PIA_INTERFACE'"

		OLD_PEER_IP="$(ip -j addr show dev pia | jq -r '.[].addr_info[].local')"
		OLD_KEY="$(echo $(wg showconf "$PIA_INTERFACE" | grep ^PublicKey | cut -d= -f2-))"
		OLD_ENDPOINT="$(wg show "$PIA_INTERFACE" endpoints | grep "$OLD_KEY" | cut -d$'\t' -f2 | cut -d: -f1)"

		# Note: unnecessary if Table != off above, but doesn't hurt.
		# ensure we don't get a packet storm loop
		ip rule add to "$SERVER_IP" lookup china pref 10

		if [ "$OLD_KEY" != "$SERVER_PUBLIC_KEY" ]
		then
			echo "    [Change Peer from $OLD_KEY to $SERVER_PUBLIC_KEY]"
			wg set "$PIA_INTERFACE" private-key <(echo "$CLIENT_PRIVATE_KEY") peer "$SERVER_PUBLIC_KEY" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips "0.0.0.0/0,::/0" || exit 1
			# remove old key
			wg set "$PIA_INTERFACE" peer "$OLD_KEY" remove
		fi

		if [ "$PEER_IP" != "$OLD_PEER_IP/32" ]
		then
			echo "    [Change $PIA_INTERFACE ipaddr from $OLD_PEER_IP to $PEER_IP]"
			# update link ip address in case
			ip addr replace "$PEER_IP" dev "$PIA_INTERFACE"
			ip addr del "$OLD_PEER_IP/32" dev "$PIA_INTERFACE"

			# remove old route
			ip rule del to "$OLD_PEER_IP" lookup china 2>/dev/null
		fi
	else
		echo "Bringing up interface '$PIA_INTERFACE'"

		# Note: unnecessary if Table != off above, but doesn't hurt.
		ip rule add to "$SERVER_IP" lookup china pref 10

		# bring up wireguard interface
# 		wg-quick up "$WGCONF"
		ip link add "$PIA_INTERFACE" type wireguard || exit 1
		ip link set dev "$PIA_INTERFACE" up || exit 1
		wg set "$PIA_INTERFACE" private-key <(echo "$CLIENT_PRIVATE_KEY") peer "$SERVER_PUBLIC_KEY" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips "0.0.0.0/0,::/0" || exit 1
		ip addr replace "$PEER_IP" dev "$PIA_INTERFACE" || exit 1

		# Note: only if Table = off in wireguard config file above
		ip route add default dev "$PIA_INTERFACE"

		# Specific to my setup
		ip route add default table vpnonly dev "$PIA_INTERFACE"
	fi
else
	echo ip rule add to "$SERVER_IP" lookup china pref 10
	sudo ip rule add to "$SERVER_IP" lookup china pref 10

	if ! ip link list "$PIA_INTERFACE" > /dev/null
	then
		echo ip link add "$PIA_INTERFACE" type wireguard
		sudo ip link add "$PIA_INTERFACE" type wireguard
	fi

	echo wg set "$PIA_INTERFACE" private-key "$CLIENT_PRIVATE_KEY" peer "$SERVER_PUBLIC_KEY" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips "0.0.0.0/0,::/0"
	sudo wg set "$PIA_INTERFACE" private-key <(echo "$CLIENT_PRIVATE_KEY") peer "$SERVER_PUBLIC_KEY" endpoint "$SERVER_IP:$SERVER_PORT" allowed-ips "0.0.0.0/0,::/0"

	echo ip addr replace "$PEER_IP" dev "$PIA_INTERFACE"
	sudo ip addr replace "$PEER_IP" dev "$PIA_INTERFACE"

	if ip link list $PIA_INTERFACE > /dev/null
	then
		OLD_PEER_IP="$(ip -j addr show dev pia | jq '.[].addr_info[].local')"
		OLD_KEY="$(echo $(wg showconf "$PIA_INTERFACE" | grep ^PublicKey | cut -d= -f2))"
		OLD_ENDPOINT="$(wg show "$PIA_INTERFACE" endpoints | grep "$OLD_KEY" | cut -d$'\t' -f2 | cut -d: -f1)"

		echo wg set "$PIA_INTERFACE" peer "$OLD_KEY" remove
		sudo wg set "$PIA_INTERFACE" peer "$OLD_KEY" remove

		echo ip rule del to "$OLD_PEER_IP" lookup china
		sudo ip rule del to "$OLD_PEER_IP" lookup china
	fi
fi

echo "PIA Wireguard '$PIA_INTERFACE' configured successfully"

echo -n "Waiting for connection to stabilise..."
while ! ping -n -c1 -w 5 -I "$PIA_INTERFACE" "$SERVER_VIP" &>/dev/null
do
	echo -n "."
done
echo " OK"

if find "$DATAFILE" -mtime -3 -exec false {} +
then
	echo
	echo "PIA endpoint cache is stale, fetching new list.."
	curl 'https://www.privateinternetaccess.com/vpninfo/servers?version=1001&client=x-alpha' > "$DATAFILE.temp" || exit 1
	if [ "$(jq 'map_values(select(.wireguard)) | keys' "$DATAFILE.temp" 2>/dev/null | wc -l)" -le 50 ]
	then
		echo "Bad serverlist retrieved to $DATAFILE.temp, ignoring"
	else
		jq -cM 'map_values(select(.wireguard))' "$DATAFILE.temp" > "$DATAFILE" 2>/dev/null
		echo "Success"
	fi
fi
