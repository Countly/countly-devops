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
# This script checks the CPU usage
#
# Usage:
# ./check_cpu_usage -w <warning threshold> -c <critical threshold>
#
#
# Output:
# OK       - if the CPU usage is under the warning and critical thresholds
# WARNING  - if the CPU usage is above the warning threshold and it is under the critical threshold
# CRITICAL - if the CPU usage is above the critical threshold
#
# -----------------------------------------------------------------------------------------------------------


if [ "$1" = "-w" ] && [ "$2" -lt "999" ] && [ "$3" = "-c" ] && [ "$4" -lt "999" ] ; then
  CORECOUNT=$(lscpu | grep 'CPU(s)' | awk -F ':' 'NR==1{print $2}' | sed 's/ //g')
  USAGEPERCENT=$(ps -A -o %cpu | awk -v CORECOUNT="$CORECOUNT" '{s+=$1} END {print s / CORECOUNT}')
  warn=$2
  crit=$4

  if (( $(echo "$USAGEPERCENT < $warn" |bc -l) )); then
    echo "OK - CPU usage = $USAGEPERCENT% | CPU usage=$USAGEPERCENT%;$warn;$crit;0;100"
    exit 0
  elif (( $(echo "$USAGEPERCENT > $warn" |bc -l) && $(echo "$USAGEPERCENT < $crit" |bc -l) )); then
    echo "WARNING - CPU usage = $USAGEPERCENT% | CPU usage=$USAGEPERCENT%;$warn;$crit;0;100"
    exit 1
  else
    echo "CRITICAL - CPU usage = $USAGEPERCENT% | CPU usage=$USAGEPERCENT%;$warn;$crit;0;100"
    exit 2
  fi
else
  echo "$0 - Nagios Plugin for checking the CPU usage in a Linux system"
  echo ""
  echo "Usage:    $0 -w <warnlevel> -c <critlevel>"
  echo "  = warnlevel and critlevel is warning and critical value for alerts."
  echo ""
  echo "EXAMPLE:  $0 -w 90 -c 95 "
  echo "  = This will send warning alert when CPU usage is more than 90%, and send critical when it is more than 95%"
  echo ""
  exit 3
fi