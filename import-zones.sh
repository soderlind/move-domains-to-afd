#!/usr/bin/bash

#
# Read the doc at https://github.com/soderlind/move-domains-to-afd/blob/main/README.md
#

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