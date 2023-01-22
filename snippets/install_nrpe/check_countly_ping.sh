#!/bin/bash
#
# Author: Kaan K. KÃ¶lkÃ¶y
# Version: 1.0
# License: GNU GENERAL PUBLIC LICENSE Version 3
#
# -----------------------------------------------------------------------------------------------------------
#  Plugin Description
# -----------------------------------------------------------------------------------------------------------
#
# This script checks the HTTP status of http://127.0.0.1/o/ping response
#
# Usage:
# ./check_countly_ping.sh
#
#
# Output:
# OK       - if the response status code is 200
# CRITICAL - if the response status code different from 200
#
# ---------------------------------------- License ----------------------------------------------------------
#
# This program is free software: you can redistribute it and/or modify
#   it under the terms of the GNU General Public License as published by
#   the Free Software Foundation, either version 3 of the License, or
#   (at your option) any later version.
#
#  This program is distributed in the hope that it will be useful,
#   but WITHOUT ANY WARRANTY; without even the implied warranty of
#   MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
#   GNU General Public License for more details.
#
#   You should have received a copy of the GNU General Public License
#   along with this program.  If not, see <http://www.gnu.org/licenses/>.
#
# -----------------------------------------------------------------------------------------------------------

# Get the response's status code
STATUS_CODE=$(curl -s -m 45 -o /dev/null -w "%{http_code}" http://127.0.0.1:3001/o/ping)

if [[ "$STATUS_CODE" == 200 ]]
then
    echo "OK - Status code is 200"
    exit 0
else
    echo "CRITICAL - Status code is ${STATUS_CODE}"
    exit 1
fi
