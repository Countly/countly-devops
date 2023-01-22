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
# This script checks the latest MongoDB log if it contains any output about `pthread`
#
# You need to run `kill -SIGUSR1 $(cat <mongodb_data_directory>/mongod.lock)`
# to rotate log after fix the issue
#
# Usage:
# ./check_mongodb_pthread.sh
#
#
# Output:
# OK       - if the log not contains output with `pthread`
# CRITICAL - if the log contains output with `pthread`
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


if grep -q "pthread" "/var/log/mongodb/mongod.log"; then
    echo "CRITICAL - There is pthread output in log"
    exit 1
else
    echo "OK - No pthread in log"
    exit 0
fi