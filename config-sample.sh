#!/usr/bin/bash
#
# Read the doc at https://github.com/soderlind/move-domains-to-afd/blob/main/README.md
#
set -e

RG="MY-AFD-RG"
DNS_RG="MY-DNS-RG"
AFD="MY-FD"
AFD_HOST="MY-FD.azurefd.net"
AFD_ROUTINGRULES="$AFD-routingrule httptohttps"
KV="MY-KV"
OUTPUT="json" # Change to "none" to get less output
BLACK_LIST="domain1.tld domain2.tld" # Don't touch these apex domains.
