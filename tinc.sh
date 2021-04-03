#!/bin/sh
cd `dirname "$0"`

###VARSBEGIN###
hostname='' # host name (for example: server01)
iface='' # tap interface name (for example: tap0)
vpnname='' # vpn name, the same as bridge name (for example: services)
address='' # internal ip address and mask (for example: 192.168.88.1/24)
###VARSEND###

[ -f ".env" ] && . ./.env

# Updating variables
# 1 - variable name
# 2 - optional check mask
# 3 - optional comment (will taken from variable comment if not exists)
# 4 - optional value for non-interactive update
selfUpdate() {
    [ -z "$1" ] && l fe "Variable name not exists"
    var=`cat -n "$0" | sed '1,/###VARSBEGIN###/d;/###VARSEND###/,$d;s/^[^0-9]\+//;/\t'"$1"'=/!d'`
    [ -n "$3" ] && comm="$3" || comm=`echo "$var" | sed '/#/!d;s/^.*#[ \t]*//'`
    [ -z "$comm" ] && comm="$1"
    val=`echo "$var" | sed 's/[ \t]*#.*$//;s/^[0-9]\+[ \t]*'"$1"'=//;s/^["'"'"']//;s/["'"'"']$//'`
    nline=`echo "$var" | awk '{print $1}'`
    if [ -z "$4" ]; then
        res=''
        while [ -z "$res" ]; do
            echo -n "Input $comm: "
            #[ -z "$val" ] && echo -n "Input $comm: " || echo -n "Input $comm (current is $val): "
            read res
            if [ -n "$2" ]; then
                [ -z "$(echo "$res" | grep -E "$2")" ] && echo "Variable $1 check is failed, try again" && res=''
            else
                break
            fi
         done
    else
        res="$4"
    fi
    mask="$(echo "$res" | sed 's#/#\\/#g')"
    mcomm="$(echo "$comm" | sed 's#/#\\/#g')"
    if [ -n "$nline" ]; then
        sed -i "$nline"'s/^.*$/'"$1"'='"'""$mask""'"" # $mcomm"'/' "$0"
    else
        nline=`cat -n "$0" | awk '$2~/###VARSEND###/ {print $1}'`
        sed -i "$nline"'i'"$1=\'$mask\' # $mcomm" "$0"
    fi
    #echo "Variable $1 is setted with value $res"
    export "$1"="$res"
}

# Check for root permissions
[ "$(whoami)" != "root" ] && echo "This script should be run with root permissions" && exit 1

# Check if tinc is installed
if [ -z "$(which tincd)" ]; then
    if [ -n "$(which apt)" ]; then
        apt install tinc
    else
        echo "Fail to install tinc, intall it manually"
        exit 2
    fi
fi

# Trying to get to /etc/tinc
! [ -d "/etc/tinc" ] && echo "Can't find /etc/tinc directory" && exit 3

# Setting up variables if not exists
selfUpdate hostname '^[a-zA-Z0-9\._-]*$'
[ -z "$vpnname" ] && selfUpdate vpnname '^[a-zA-Z0-9\._-]*$'
[ -z "$iface" ] && selfUpdate iface '^[a-zA-Z0-9\._-]*$'
selfUpdate address '^(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\.(25[0-5]|2[0-4][0-9]|[01]?[0-9][0-9]?)\/[0-9]{1,2}$'

# Scripts templates
tutpl='#!/bin/sh
cd `dirname "$0"`
[ -f ".env" ] && . ./.env

BR="$(basename `pwd`)"
INTERFACE=`cat tinc.conf | sed '"'"'/^Interface/!d;s/^.*[ \t]*=[ \t]//'"'"'`

ifstat=`ip l sh | grep -F " $INTERFACE: "`
[ -z "$ifstat" ] && echo "Interface $INTERFACE does not exists" && exit 1

ip l set dev "$INTERFACE" up
brstat=`ip l sh | grep -F " $BR: "`
if [ -z "$brstat" ]; then
        echo "Trying to bring up new bridge $BR"
        ip link add name "$BR" type bridge
        if [ -n "$ADDRESS" ]; then
            [ -z "$(ip a s dev $BR | grep -F "inet $ADDRESS")" ] && echo "Setting address $ADDRESS to bridge $BR" && ip a a "$ADDRESS" dev "$BR"
        fi
fi

ip l set dev "$BR" up

[ -z "$(echo "$ifstat" | grep -F " master $BR ")" ] && ip l set dev "$INTERFACE" master "$BR"

if [ -z "$(iptables -nvL INPUT | grep -F " spt:655")" ]; then
    iptables -I INPUT -p tcp --sport 655 -j ACCEPT
    iptables -I INPUT -p udp --sport 655 -j ACCEPT
fi
'

tdtpl='#!/bin/sh
cd `dirname "$0"`
[ -f ".env" ] && . ./.env
BR="$(basename `pwd`)"

brctl delif "$BR" "$INTERFACE"
ip link set "$INTERFACE" down
'

tpl='Name = %NAME%
Mode = switch
Interface = %IFACE%
Port = 655

# ConnectTo = XXX

'

# Creating directories and files
mkdir "/etc/tinc/$vpnname"
cd "/etc/tinc/$vpnname"

echo "INTERFACE=$iface
ADDRESS=$address" > .env

#BR="$(basename `pwd`)"

[ -d "hosts" ] || mkdir hosts

echo "$tpl" | sed 's/Name[ ]*=[ ]*.*$/Name = '"$hostname"'/g;s/Interface[ ]*=[ ]*.*$/Interface = '"$iface"'/' > tinc.conf
echo "$tutpl" > tinc-up
echo "$tdtpl" > tinc-down
chmod +x tinc-up tinc-down

echo "# Address = X.X.X.X
Cipher = aes-128-cbc
Digest = sha1
Compression = 0
" > "hosts/$hostname"

# Generating keypair
[ -f "rsa_key.priv" ] || tincd -n "$vpnname" -K2048

echo "Don't forget update Address field in /etc/tinc/$vpnname/hosts/$hostname if it necessary."
echo "For running/stopping/enable/disable service: 
    systemctl start/stop/enable|disable tinc@$vpnname"
