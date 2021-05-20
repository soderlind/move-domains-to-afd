#!/usr/bin/bash
#
# Read the doc at https://github.com/soderlind/move-domains-to-afd/blob/main/README.md
#
set -e

source config.sh

# Auto-add missing extension
az config set extension.use_dynamic_install=yes_without_prompt

# The variable below are set by the script.

KV_ID=$(az keyvault list --subscription "$SUBSCRIPTION" --resource-group $RG  | jq -r '[.[].id]|join("")')
OLD_FRONTENDS=$(az network front-door frontend-endpoint list --subscription "$SUBSCRIPTION" --resource-group $RG --front-door-name $AFD | jq -r '[.[].name]|join(" ")' )
DNS_ZONES=$(az network dns zone list --subscription "$SUBSCRIPTION" --resource-group $DNS_RG --query '[].name' | jq -r '.|join(" ")')
i=0

echo -e "\nUPDATING AZURE DNS"
SECRET_NAMES=$(az keyvault certificate list --vault-name $KV | jq -r '[.[].name]|join(" ")')
for SECRET_NAME in $SECRET_NAMES; do
	CUSTOMDOMAINS=$(az keyvault certificate show --vault-name $KV --name $SECRET_NAME | jq -r '.. | objects | select(.subjectAlternativeNames).subjectAlternativeNames.dnsNames |join(" ")')

	for DOMAIN in  $CUSTOMDOMAINS; do
		echo -e "\nUpdating $DOMAIN"
		ZONE=$(echo $DOMAIN | rev | cut -d. -f1-2 | rev)

		# If the domain in the certificate is in our Azure DNS, modify it.
		if [[ $DNS_ZONES =~ (^|[[:space:]])$ZONE($|[[:space:]]) ]]; then

			FRONTENDPOINT="$(echo $DOMAIN | tr "." "-")-frontend-endpoint"
			if [[  $OLD_FRONTENDS =~ (^|[[:space:]])$FRONTENDPOINT($|[[:space:]]) ]]; then
				echo -e "\tSkipping, $DOMAIN already in AFD"
				continue
			fi

			i=$((i+1))
			AFD_NR=$(($i%6 + 1))
			AFD_HOST="p-wordpress-fd0$AFD_NR.azurefd.net"
			AFD_ID=$(az network front-door show --subscription "$SUBSCRIPTION" --resource-group $RG --name $AFD_HOST --query id -o tsv)

			if [[ $ZONE != $DOMAIN ]]; then
				HOST=$(echo $DOMAIN | cut -d. -f1)
				echo -e "\tHOST: finding record type for $HOST in zone $ZONE"
				record_type=$(az network dns record-set list --subscription "$SUBSCRIPTION" --resource-group $DNS_RG --zone-name $ZONE --query "[?name=='$HOST'].type" | jq -r '.|join("")|split("/")[-1]' )
				echo -e "\tRecord type: $record_type"
				if [[ "A" == $record_type ]]; then
					echo -e "\tDELETE A-record"
					az network dns record-set a delete --subscription "$SUBSCRIPTION" --resource-group $DNS_RG --zone-name $ZONE --name $HOST --yes --output $OUTPUT
				fi
				echo -e "\tCreate CNAME $HOST -> $AFD_HOST"
				az network dns record-set cname set-record --subscription "$SUBSCRIPTION" --resource-group $DNS_RG --zone-name $ZONE --record-set-name $HOST --cname $AFD_HOST --output $OUTPUT
			elif [[ $BLACK_LIST =~ (^|[[:space:]])$ZONE($|[[:space:]]) ]]; then
				echo -e "\tBLACKLISTED, DO NOTHING to $ZONE"
			else
				echo -e "\tAPEX domain, point @ to $AFD_HOST"
				az network dns record-set a update --subscription "$SUBSCRIPTION" --resource-group $DNS_RG --zone-name $ZONE --name "@"  --target-resource $AFD_ID --output $OUTPUT
				echo -e "\tAdd CNAME afdverify -> afdverify.$AFD_HOST"
				az network dns record-set cname set-record --subscription "$SUBSCRIPTION" --resource-group $DNS_RG --zone-name $ZONE --record-set-name "afdverify" --cname "afdverify.${AFD_HOST}" --output $OUTPUT
			fi
		fi
	done
done

echo -e "\nADDING DOMAINS TO AZURE FRONT DOOR"
SECRET_NAMES=$(az keyvault certificate list --vault-name $KV | jq -r '[.[].name]|join(" ")')
for SECRET_NAME in $SECRET_NAMES; do
	DOMAINS_WITH_CERTS=$(az keyvault certificate show --vault-name $KV --name $SECRET_NAME | jq -r '.. | objects | select(.subjectAlternativeNames).subjectAlternativeNames.dnsNames |join(" ")')
	SECRET_ID=$(az keyvault certificate show --vault-name $KV --name $SECRET_NAME |jq  -r '[.sid]|join("")|split("/")[-1]')
	for DOMAIN_WITH_CERT in $DOMAINS_WITH_CERTS; do

		FRONTENDPOINT="$(echo $DOMAIN_WITH_CERT | tr "." "-")-frontend-endpoint"
		if [[ $OLD_FRONTENDS =~ (^|[[:space:]])$FRONTENDPOINT($|[[:space:]]) ]]; then
			echo -e "\t$DOMAIN_WITH_CERT in Front Door, skipping\n"
			continue
		fi

		ZONE=$(echo $DOMAIN_WITH_CERT | rev | cut -d. -f1-2 | rev)
		if [[ $ZONE != $DOMAIN_WITH_CERT ]]; then
			HOST=$(echo $DOMAIN_WITH_CERT | cut -d. -f1)
			AFD=$(az network dns record-set list --subscription "$SUBSCRIPTION" --resource-group $DNS_RG --zone-name $ZONE  --query "[?name=='$HOST'].cnameRecord.cname" -o tsv)
		else
			AFD=$(az network dns record-set list --subscription "$SUBSCRIPTION" --resource-group $DNS_RG --zone-name $ZONE --query "[?name=='@'].targetResource.id" | jq -r '.|join("")|split("/")[-1]')
			AFD="$AFD.azurefd.net"
		fi

		echo -e "\tAdding domain $DOMAIN_WITH_CERT to Front Door\n"
		az network front-door frontend-endpoint create --subscription "$SUBSCRIPTION" --resource-group $RG --front-door-name $AFD --name $FRONTENDPOINT --host-name $DOMAIN_WITH_CERT --output $OUTPUT
		az network front-door frontend-endpoint enable-https --subscription "$SUBSCRIPTION" --resource-group $RG --front-door-name $AFD --name $FRONTENDPOINT --vault-id $KV_ID --certificate-source AzureKeyVault --secret-name $SECRET_NAME --secret-version $SECRET_ID --output $OUTPUT

	done
done

echo -e "\nUPDATING AZURE FRONT DOOR ROUTING RULES"
AFD_FRONTENDS=$(az network front-door frontend-endpoint list --subscription "$SUBSCRIPTION" --resource-group $RG --front-door-name $AFD | jq -r '[.[].name]|join(" ")' )
for RULE in $AFD_ROUTINGRULES; do
	echo -e "\tAdding ALL endpoints/domains to rule: $RULE"
	az network front-door routing-rule update --subscription "$SUBSCRIPTION" --resource-group $RG --front-door-name $AFD --name $RULE --frontend-endpoints $AFD_FRONTENDS  --output $OUTPUT
done
