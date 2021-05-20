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
# The variable below are set by the script.
AFD_ID=$(az network front-door show --resource-group $RG --name $AFD --query id -o tsv)
KV_ID=$(az keyvault list --resource-group $RG  | jq -r '[.[].id]|join("")')
OLD_FRONTENDS=$(az network front-door frontend-endpoint list --resource-group $RG --front-door-name $AFD | jq -r '[.[].name]|join(" ")' )
DNS_ZONES=$(az network dns zone list --resource-group $DNS_RG --query '[].name' | jq -r '.|join(" ")')