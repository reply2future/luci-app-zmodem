#!/bin/sh

PROGRAM="RM520N_IPCHK"
ENABLE_NATIVE_IPV6=$(uci get modem.@ndis[0].enable_native_ipv6) || ENABLE_NATIVE_IPV6=0
LOCKFILE="/tmp/ipcheck.lock"
RETRY_LIMIT_FILE="/tmp/retrylimit"
FAIL_COUNT=0
MAX_FAIL_COUNT=5
RETRY_LIMIT_SLEEP_TIME=1h

printMsg() {
    logger -t "${PROGRAM}" "$1"
} #日志输出调用API

printMsg "Start IP Check"

# Check if lockfile exists
if [ -f $LOCKFILE ]; then
    OLD_PID=$(cat $LOCKFILE)
    printMsg "Kill $OLD_PID"
    kill $OLD_PID
fi

echo $$ >$LOCKFILE

get_eth1_ip() {
    sendat 2 'at+qmap="wwan"' | grep IPV4 | awk -F \" '{print $6}'
}

is_ip_alive() {
    local ip=$1
    local at_check=$(sendat 2 'AT+CGPADDR' | grep "$ip")
    local ifconfig_check=$(ifconfig | grep "$ip")
    [[ -n "$at_check" && -n "$ifconfig_check" && "$ip" != "0.0.0.0" ]]
}

check_http_connectivity() {
    local http_code1=$(curl -o /dev/null -s -w %{http_code} http://connect.rom.miui.com/generate_204 --connect-timeout 3)
    local http_code2=$(curl -o /dev/null -s -w %{http_code} http://connectivitycheck.platform.hicloud.com/generate_204 --connect-timeout 3)
    [[ "$http_code1" == "204" || "$http_code2" == "204" ]]
}

update_network_type() {
    local nettype=$(sendat 2 'at+qnwinfo' | grep '+QNWINFO' | awk -F \" '{print $2}' | tr -d '\r\n')
    echo "$nettype" >/tmp/nettype
}

reconnect() {
    printMsg "Try to RECONNECT"
    sendat 2 'at+qmap="connect",0,1'
    sleep 2
    /sbin/ifup wan
    /sbin/ifup wan6
    sleep 10
    if [[ "$ENABLE_NATIVE_IPV6" -eq 1 ]]; then
        /usr/share/modem/enableipv6.sh
    fi
}

handle_retry_limit() {
    if [[ -e "$RETRY_LIMIT_FILE" ]]; then
        printMsg "Retry limit file ($RETRY_LIMIT_FILE) already exists. Exiting."
        printMsg "FAILURE to save the world, Retry Modem Init, exit"
        sleep "$RETRY_LIMIT_SLEEP_TIME"
    else
        touch "$RETRY_LIMIT_FILE"
    fi

    /usr/share/modem/rm520n.sh &
    rm -f "$LOCKFILE"
    exit 1
}

check_ip_if_alive() {
    local eth1_ip=$(get_eth1_ip)

    if ! is_ip_alive "$eth1_ip"; then
        printMsg "IP FAILURE, try restore"
        reconnect
        FAIL_COUNT=$((FAIL_COUNT + 1))
    elif ! check_http_connectivity; then
        printMsg "HTTP Check FAILURE"
        reconnect
        FAIL_COUNT=$((FAIL_COUNT + 1))
    else
        update_network_type
        FAIL_COUNT=0
        rm -f "$RETRY_LIMIT_FILE"
        return
    fi

    if [[ $FAIL_COUNT -ge $MAX_FAIL_COUNT ]]; then
        handle_retry_limit
    fi
}

# loop 2
while true; do
    check_ip_if_alive
    sleep 20
done
