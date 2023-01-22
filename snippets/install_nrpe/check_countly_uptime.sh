#!/bin/bash
#
# Author: Kaan KÃ¶lkÃ¶y
# Version: 1.0
# License: GNU GENERAL PUBLIC LICENSE Version 3
#
# -----------------------------------------------------------------------------------------------------------
#  Plugin Description
# -----------------------------------------------------------------------------------------------------------
#
# This script checks uptime for Countly service
#
# Usage:
# ./check_countly_uptime
#
#
# Output:
# OK       - if the uptime is above the critical threshold
# CRITICAL - if the uptime is under the critical threshold
#
# -----------------------------------------------------------------------------------------------------------

UP_SINCE=$(countly status | grep Active | awk -F'since' '{print $2}' | awk -F';' '{print $1}')
UP_SINCE_SECS=$(date -d "${UP_SINCE}" +%s)
UPTIME_IN_SECS=$(($(date +%s) - $UP_SINCE_SECS))
OS_UPTIME_IN_MINS=$(echo $(awk '{print $1}' /proc/uptime) / 60 | bc)

if (( $(echo "$OS_UPTIME_IN_MINS > 2" |bc -l) )); then
    if (( $(echo "$UPTIME_IN_SECS > 120" |bc -l) )); then
        echo "OK - Can't detect new restart | Uptime=$UPTIME_IN_SECS"
        exit 0
    else
        echo "CRITICAL - Detected new restart | Uptime=$UPTIME_IN_SECS"
        exit 2
    fi
else
    echo "OK - Server just started | Uptime=$UPTIME_IN_SECS"
    exit 0
fi
