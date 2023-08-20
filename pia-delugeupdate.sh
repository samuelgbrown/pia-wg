#!/bin/bash

# This script will update deluge with the forwarded port received from WireGuard
# Note: This script was designed to be run by a user DIFFERENT than the one that normally
# runs Deluge (e.g., a root user who just set up WireGuard, to update a Deluge instance
# maintained by a user).  Therefore, the configuration *directory* must be configured.

# Configure
DELUGE_CONFIGDIR=/var/lib/deluge/.config/deluge/
DELUGE_CONFIGFILE_RAW=core.conf

# Check and set inputs
if [ $# -ne 1 ]
then
	echo "This script accepts a single integer, the port to be sent to the Deluge instance" > /dev/stderr
	echo "Received $# inputs instead" > /dev/stderr
	exit 1
fi

if [[ ! -d $DELUGE_CONFIGDIR ]]
then
	echo "The deluge configuration directory $DELUGE_CONFIGDIR does not exist, cannot write port to deluge configuration" > /dev/stderr
	exit 1
fi

DELUGE_CONFIGFILE="$DELUGE_CONFIGDIR$DELUGE_CONFIGFILE_RAW"
if [[ ! -w $DELUGE_CONFIGFILE ]]
then
	echo "The deluge configuration file $DELUGE_CONFIGFILE does not exist, or is not writable" > /dev/stderr
	echo "Attempting to write to file regardless..." > /dev/stderr
fi

PORT=$1

# Update Deluge (ignore errors due to annoying verbose deluge-console bug about localization)
deluge-console -c $DELUGE_CONFIGDIR "config --set random_port False" 2> /dev/null
deluge-console -c $DELUGE_CONFIGDIR "config --set listen_ports ($PORT $PORT)" 2> /dev/null
deluge-console -c $DELUGE_CONFIGDIR "config --set outgoing_ports ($PORT $PORT)" 2> /dev/null
