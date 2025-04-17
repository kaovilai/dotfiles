# znap function listAWSRoute53HostedZones(){
# # Initialize an empty variable to store the NextHostedZoneId
#   next_zone_id=""
#   while [ -n "$next_zone_id" ]; do
#   # Fetch the list of hosted zones using the current NextHostedZoneId
#   zone_list=$(aws route53 list-hosted-zones-by-name --dnsname $next_zone_id --output text)

#   # Extract the NextHostedZoneId from the first response if available
#   next_zone_id=$(echo "$zone_list" | jq -r '.[0].NextDNSName')

#   # Extract and print the list of zone names using jq
#   zone_names=$(echo "$zone_list" | jq -r '.HostedZones[].Name')
#   echo "$zone_names"
#   done
# }
