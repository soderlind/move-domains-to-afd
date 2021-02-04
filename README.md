# Moving multiple domains to Azure Front Door

I manage a WordPress Multisite and when migrating it to Azure, I had to move more than 100 domains.

I highly recommend that you test the scripts below on your test platform in Azure before you do it in production, and please read the disclaimer at the end of this document.

## Prerequisite

### Tools

Either use [Azure Shell](https://shell.azure.com/) (bash)

Or install

- [Azure CLI](https://docs.microsoft.com/en-us/cli/azure/install-azure-cli), aka `az`
- [jq](https://stedolan.github.io/jq/), a lightweight and flexible command-line JSON processor.

### Domains must be moved to Azure DNS.

I moved the domains using the following script

- Add 3 sub folders, `ok`, `failed` and `zones`. In `zones`, add a zone file per domain in the format `domain.tld`. If the import fails for a zone file, it lands in `failed`. Fix the file and put it back into `zones` and run the script again.
- Log in to Azure: `az login`
- Run the script.


```shell
#!/usr/bin/bash

RG="MY-DNS-RG"
zone_dir="./zones"

# for each zone file, read zone file from folder
for zone_file in "$zone_dir"/*
do
  	ZONE=` basename "$zone_file"`
  	printf "Importing $ZONE\n"
	az network dns zone import --resource-group $RG --name $ZONE --file-name $zone_file
	if [ $? -eq 0 ]
	then
  		mv $zone_file ok/.
	else
  		mv $zone_file failed/.
	fi
done
```

- After you've created the zones in Azure DNS, get the nameservers per zone and tell the registrar to change them.

The `az` command below will create a csv-file, with zone and nameservers per line.

```shell
az network dns zone list --resource-group MY-DNS-RG --output json | jq -r '[.[] | {zone: .name, nameservers: .nameServers[]}] | map({zone,nameservers}) | (first | keys_unsorted) as $keys | map([to_entries[] | .value]) as $rows | $keys,$rows[] | @csv' > zones-with-nameservers.csv
```

### Certificates in Azure Key Vault

Azure Front Door (AFD) [doesn't support AFD managed certificates](https://docs.microsoft.com/en-us/azure/frontdoor/front-door-how-to-onboard-apex-domain#enable-https-on-your-custom-domain) for the apex (root) domain :confused:, so you must bring your own certificates. I use [keyvault-acmebot](https://github.com/shibayan/keyvault-acmebot) and its [bulk add form](https://github.com/shibayan/keyvault-acmebot/issues/230#issuecomment-769638846). **NOTE**, the Let's Encrypt SAN certificate doesn't support more than 100 domains, so don't add more at a time. I suggest you add 50 domains at a time.

#### Access Policies

You need to setup the right permissions for Front Door to access your Key vault:

- Register Azure Front Door Service as an app in your Azure Active Directory (AAD) via PowerShell using this command:
`New-AzADServicePrincipal -ApplicationId "ad0e1c7e-6d38-4ba4-9efd-0bc77ba9f037"`.
- Grant Azure Front Door Service the permission to access the secrets in your Key vault. Go to “Access policies” from your Key vault to add a new policy, then grant “Microsoft.Azure.Frontdoor” service principal a “get-secret” permission.

Microsoft.Azure.Frontdoor
  - Key Vault Secret Permissions: Get
  - Key Vault Certificate Permissions: Get

Function App (created when you installed keyvault-acmebot ):

- Key Vault Certificate Permissions: Get, List, Update, Create

You user:
- Key Vault Secret Permissions: Get, List
- Key Vault Certificate Permissions: Get, Lis



## Moving the domains to Azure Front Door

I assume Azure Front Door is up and running and that you have created your routing rules.

The script below will only update domains that are added to the Azure Key Vault .

### Config

I use these variables

```shell
RG="MY-AFD-RG"
DNS_RG="MY-DNS-RG"
AFD="MY-FD"
AFD_HOST="MY-FD.azurefd.net"
AFD_ID=$(az network front-door show --resource-group $RG --name $AFD --query id -o tsv)
AFD_ROUTINGRULES="$AFD-routingrule httptohttps"
KV="MY-KV"
KV_ID=$(az keyvault list --resource-group $RG  | jq -r '[.[].id]|join("")')
OLD_FRONTENDS=$(az network front-door frontend-endpoint list --resource-group $RG --front-door-name $AFD | jq -r '[.[].name]|join(" ")' )
OUTPUT="json" # Change to "none" to get less output
```

### Point the domain to the Azure Front Door

The apex domain (`@`) must be aliased and pointed to the Azure Front Door. To verify ownership of the domain, a `afdverify` CNAME must be added. If the host/subdomain previously had an A record and pointed to an IP address, it must be changed to a CNAME pointing to the front door.

The script below does this for you:

```shell
echo -e "\nUPDATING AZURE DNS"
snames=$(az keyvault certificate list --vault-name $KV | jq -r '[.[].name]|join(" ")')
for SECRET_NAME in $snames; do
	CUSTOMDOMAINS=$(az keyvault certificate show --vault-name $KV --name $SECRET_NAME | jq -r '.. | objects | select(.subjectAlternativeNames).subjectAlternativeNames.dnsNames |join(" ")')

	for DOMAIN in  $CUSTOMDOMAINS; do

		echo -e "\nUpdating $DOMAIN"
		ZONE=$(echo $DOMAIN | rev | cut -d. -f1-2 | rev) # NOTE, I assume domain.tld, if you have domain.co.tld you have to change this.
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
		else
			echo -e "\tpoint @ to $AFD_HOST"
			az network dns record-set a update --resource-group $DNS_RG --zone-name $ZONE --name "@"  --target-resource $AFD_ID --output $OUTPUT
			echo -e "\tAdd CNAME afdverify -> afdverify.$AFD_HOST"
			az network dns record-set cname set-record --resource-group $DNS_RG --zone-name $ZONE --record-set-name "afdverify" --cname "afdverify.${AFD_HOST}" --output $OUTPUT
		fi
	done
done
```

### Add the domain to Azure Front Door and enable HTTPS for the domain



```shell
echo -e "\nADDING DOMAINS TO AZURE FRONT DOOR"
snames=$(az keyvault certificate list --vault-name $KV | jq -r '[.[].name]|join(" ")')
for SECRET_NAME in $snames; do
	DOMAINS_WITH_CERTS=$(az keyvault certificate show --vault-name $KV --name $SECRET_NAME | jq -r '.. | objects | select(.subjectAlternativeNames).subjectAlternativeNames.dnsNames |join(" ")')
	SECRET_ID=$(az keyvault certificate show --vault-name $KV --name $SECRET_NAME |jq  -r '[.sid]|join("")|split("/")[-1]')
	for DOMAIN_WITH_CERT in $DOMAINS_WITH_CERTS; do
		is_validated_domain=$(az network front-door check-custom-domain --resource-group $RG  --name $AFD --host-name $DOMAIN_WITH_CERT --query customDomainValidated)
		if [[ "true" == $is_validated_domain  ]]; then
			FRONTENDPOINT="$(echo $DOMAIN_WITH_CERT | tr "." "-")-frontend-endpoint"
			if [[ ! $OLD_FRONTENDS =~ (^|[[:space:]])$FRONTENDPOINT($|[[:space:]]) ]]; then
				echo -e "\tAdding domain $DOMAIN_WITH_CERT to Front Door\n"
				az network front-door frontend-endpoint create --resource-group $RG --front-door-name $AFD --name $FRONTENDPOINT --host-name $DOMAIN_WITH_CERT --output $OUTPUT
				az network front-door frontend-endpoint enable-https --resource-group $RG --front-door-name $AFD --name $FRONTENDPOINT --vault-id $KV_ID --certificate-source AzureKeyVault --secret-name $SECRET_NAME --secret-version $SECRET_ID --output $OUTPUT
			else
				echo -e "\tDomain $DOMAIN_WITH_CERT with frontend endpoit $FRONTENDPOINT allreary exists in $AFD\n"
			fi
		fi
	done
done
```

### Add routing rules to Azure Front Door

```shell
echo -e "\nUPDATING AZURE FRONT DOOR ROUTING RULES"
AFD_FRONTENDS=$(az network front-door frontend-endpoint list --resource-group $RG --front-door-name $AFD | jq -r '[.[].name]|join(" ")' )
for RULE in $AFD_ROUTINGRULES; do
	echo -e "\tAdding ALL endpoints/domains to rule: $RULE"
	az network front-door routing-rule update --resource-group $RG --front-door-name $AFD --name $RULE --frontend-endpoints $AFD_FRONTENDS  --output $OUTPUT
done
```

## Copyright and License

move-domains-to-afd.sh is copyright 2021 Per Soderlind

move-domains-to-afd.sh is free software: you can redistribute it and/or modify it under the terms of the GNU General Public License as published by the Free Software Foundation, either version 2 of the License, or (at your option) any later version.

move-domains-to-afd.sh is distributed in the hope that it will be useful, but WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the GNU General Public License for more details.

You should have received a copy of the GNU Lesser General Public License along with the Extension. If not, see http://www.gnu.org/licenses/.