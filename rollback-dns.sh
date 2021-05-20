#!/usr/bin/bash
#
# Read the doc at https://github.com/soderlind/move-domains-to-afd/blob/main/README.md
#
set -e

source config.sh

echo -e "\nUPDATING AZURE DNS"
SECRET_NAMES=$(az keyvault certificate list --vault-name $KV | jq -r '[.[].name]|join(" ")')
for SECRET_NAME in $SECRET_NAMES; do
	CUSTOMDOMAINS=$(az keyvault certificate show --vault-name $KV --name $SECRET_NAME | jq -r '.. | objects | select(.subjectAlternativeNames).subjectAlternativeNames.dnsNames |join(" ")')

	for DOMAIN in  $CUSTOMDOMAINS; do
		echo -e "\nUpdating $DOMAIN"
		ZONE=$(echo $DOMAIN | rev | cut -d. -f1-2 | rev)

		# If the domain in the certificate is in our Azure DNS, modify it.
		if [[ $DNS_ZONES =~ (^|[[:space:]])$ZONE($|[[:space:]]) ]]; then
			if [[ $ZONE != $DOMAIN ]]; then
				HOST=$(echo $DOMAIN | cut -d. -f1)
				echo -e "\tHOST: finding record type for $HOST in zone $ZONE"
				record_type=$(az network dns record-set list --resource-group $DNS_RG --zone-name $ZONE --query "[?name=='$HOST'].type" | jq -r '.|join("")|split("/")[-1]' )
				echo -e "\tRecord type: $record_type"
				if [[ "A" == $record_type ]]; then
					echo -e "\tDELETE A-record"
					az network dns record-set a delete --resource-group $DNS_RG --zone-name $ZONE --name $HOST --yes --output $OUTPUT
				fi
				echo -e "\tCreate CNAME $HOST -> $AFD_HOST"
				az network dns record-set cname set-record --resource-group $DNS_RG --zone-name $ZONE --record-set-name $HOST --cname $AFD_HOST --output $OUTPUT
			elif [[ $BLACK_LIST =~ (^|[[:space:]])$ZONE($|[[:space:]]) ]]; then
				echo -e "\tBLACKLISTED, DO NOTHING to $ZONE"
			else
				echo -e "\tAPEX domain, point @ to $AFD_HOST"
				az network dns record-set a update --resource-group $DNS_RG --zone-name $ZONE --name "@"  --target-resource $AFD_ID --output $OUTPUT
				echo -e "\tAdd CNAME afdverify -> afdverify.$AFD_HOST"
				az network dns record-set cname set-record --resource-group $DNS_RG --zone-name $ZONE --record-set-name "afdverify" --cname "afdverify.${AFD_HOST}" --output $OUTPUT
			fi
		fi
	done
done