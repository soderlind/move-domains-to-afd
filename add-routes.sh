#!/usr/bin/bash
#
# Read the doc at https://github.com/soderlind/move-domains-to-afd/blob/main/README.md
#
set -e

source config.sh

# Auto-add missing extension
az config set extension.use_dynamic_install=yes_without_prompt

# The variable below are set by the script.



echo -e "\nUPDATING AZURE FRONT DOOR ROUTING RULES"
for door in p-wordpress-fd01 p-wordpress-fd02 p-wordpress-fd03 p-wordpress-fd04 p-wordpress-fd05 p-wordpress-fd06; do

	AFD_FRONTENDS=$(az network front-door frontend-endpoint list --subscription "$SUBSCRIPTION" --resource-group $RG --front-door-name $door | jq -r '[.[].name]|join(" ")' )
	for RULE in $AFD_ROUTINGRULES; do
		echo -e "\tAdding ALL endpoints/domains to rule: $RULE"
		az network front-door routing-rule update --subscription "$SUBSCRIPTION" --resource-group $RG --front-door-name $door --name $RULE --frontend-endpoints $AFD_FRONTENDS  --output $OUTPUT
	done
done