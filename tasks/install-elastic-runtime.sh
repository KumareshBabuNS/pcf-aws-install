#!/bin/bash

set -e -x

stackname=$AWS_CLOUDFORMATION_STACK_NAME
opsmanDomain=$OPS_MANAGER_DOMAIN
adminUser=$OPS_MANAGER_ADMIN_USER
adminPass=$OPS_MANAGER_ADMIN_PASS
hostedZoneId=$AWS_HOSTED_ZONE_ID
systemDomain=$CF_SYSTEM_DOMAIN
appsDomain=$CF_APPS_DOMAIN
cfNotifyEmail=$CF_NOTIFY_EMAIL
cfSmtpFrom=$CF_SMTP_FROM
cfSmtpAddress=$CF_SMTP_ADDRESS
cfSmtpPort=$CF_SMTP_PORT
cfSmtpUsername=$CF_SMTP_USERNAME
cfSmtpPassword=$CF_SMTP_PASSWORD
cfS3Endpoint=$CF_S3_ENDPOINT

# Get AWS Stack Outputs
stack=$(aws cloudformation describe-stacks --stack-name $stackname)

# asdf
# Create CNAMEs
pcfElbDnsName=$(echo $stack | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "PcfElbDnsName") | .OutputValue')
pcfElbSshDnsName=$(echo $stack | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "PcfElbSshDnsName") | .OutputValue')
pcfElbTcpDnsName=$(echo $stack | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "PcfElbTcpDnsName") | .OutputValue')

jq -n \
--arg appsDomain "*.$appsDomain" \
--arg systemDomain "*.$systemDomain" \
--arg sshDomain "ssh.$systemDomain" \
--arg tcpDomain "tcp.$appsDomain" \
--arg pcfElbDnsName "$pcfElbDnsName" \
--arg pcfElbSshDnsName "$pcfElbSshDnsName" \
--arg pcfElbTcpDnsName "$pcfElbTcpDnsName" \
'{
  Comment: "create record sets for pcf",
  Changes: [
    {
      Action: "CREATE",
      ResourceRecordSet: {
        Name: $appsDomain,
        Type: "CNAME",
        TTL: 300,
        ResourceRecords: [{
          Value: $pcfElbDnsName
        }]
      }
    },
    {
      Action: "CREATE",
      ResourceRecordSet: {
        Name: $systemDomain,
        Type: "CNAME",
        TTL: 300,
        ResourceRecords: [{
          Value: $pcfElbDnsName
        }]
      }
    },
    {
      Action: "CREATE",
      ResourceRecordSet: {
        Name: $sshDomain,
        Type: "CNAME",
        TTL: 300,
        ResourceRecords: [{
          Value: $pcfElbSshDnsName
        }]
      }
    },
    {
      Action: "CREATE",
      ResourceRecordSet: {
        Name: $tcpDomain,
        Type: "CNAME",
        TTL: 300,
        ResourceRecords: [{
          Value: $pcfElbTcpDnsName
        }]
      }
    }
  ]
}' > change-resource-record-sets.json

createRecordSet=$(aws route53 change-resource-record-sets --hosted-zone-id $hostedZoneId --change-batch file://change-resource-record-sets.json)

changeId=$(echo $createRecordSet | jq -r '.ChangeInfo.Id')

aws route53 wait resource-record-sets-changed --id $changeId

# Login to UAA
uaac target https://$opsmanDomain/uaa --skip-ssl-validation
uaac token owner get opsman $adminUser -p $adminPass -s ''
UAA_ACCESS_TOKEN=$(uaac context admin | grep access_token | awk '{ print $2 }')

# Upload elastic-runtime
file=$(ls elastic-runtime/cf-*.pivotal)

curl "https://$opsmanDomain/api/v0/available_products" -k \
    -X POST \
    -H "Authorization: Bearer $UAA_ACCESS_TOKEN" \
    -F "product[file]=@$file"

# Stage elastic-runtime
availableProducts=$(curl "https://$opsmanDomain/api/v0/available_products" -k \
    -X GET \
    -H "Authorization: Bearer $UAA_ACCESS_TOKEN")

cfVersion=$(echo $availableProducts | jq -r '.[] | select(.name == "cf") | .product_version')

stageData=$(jq -n \
--arg cfVersion $cfVersion \
'{
  name: "cf",
  product_version: $cfVersion
}')

curl "https://$opsmanDomain/api/v0/staged/products" -k \
    -X POST \
    -H "Authorization: Bearer $UAA_ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$stageData"

# Get the guid
stagedProducts=$(curl "https://$opsmanDomain/api/v0/staged/products" -k \
    -X GET \
    -H "Authorization: Bearer $UAA_ACCESS_TOKEN")

cfGuid=$(echo $stagedProducts | jq -r '.[] | select(.type == "cf") | .guid')

# Configure elastic-runtime
properties=$(jq -n \
--arg systemDomain $systemDomain \
--arg appsDomain $appsDomain \
--arg cfNotifyEmail $cfNotifyEmail \
--arg cfS3Endpoint $cfS3Endpoint \
--arg accessKeyId $(echo $stack | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "PcfIamUserAccessKey") | .OutputValue') \
--arg secretAccessKey $(echo $stack | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "PcfIamUserSecretAccessKey") | .OutputValue') \
--arg buildpacksBucket $(echo $stack | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "PcfElasticRuntimeS3BuildpacksBucket") | .OutputValue') \
--arg dropletsBucket $(echo $stack | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "PcfElasticRuntimeS3DropletsBucket") | .OutputValue') \
--arg packagesBucket $(echo $stack | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "PcfElasticRuntimeS3PackagesBucket") | .OutputValue') \
--arg resourcesBucket $(echo $stack | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "PcfElasticRuntimeS3ResourcesBucket") | .OutputValue') \
--arg cfSmtpFrom $cfSmtpFrom \
--arg cfSmtpAddress $cfSmtpAddress \
--arg cfSmtpPort $cfSmtpPort \
--arg cfSmtpUsername $cfSmtpUsername \
--arg cfSmtpPassword $cfSmtpPassword \
'{
  properties: {
    ".cloud_controller.system_domain": {
      value: $systemDomain
    },
    ".cloud_controller.apps_domain": {
      value: $appsDomain
    },
    ".properties.networking_point_of_entry": {
      value: "external_non_ssl"
    },
    ".properties.logger_endpoint_port": {
      value: "4443"
    },
    ".properties.security_acknowledgement": {
      value: "X"
    },
    ".mysql_monitor.recipient_email": {
      value: $cfNotifyEmail
    },
    ".properties.system_blobstore": {
      value: "external"
    },
    ".properties.system_blobstore.external.endpoint": {
      value: $cfS3Endpoint
    },
    ".properties.system_blobstore.external.access_key": {
      value: $accessKeyId
    },
    ".properties.system_blobstore.external.secret_key": {
      value: {
        secret: $secretAccessKey
      }
    },
    ".properties.system_blobstore.external.buildpacks_bucket": {
      value: $buildpacksBucket
    },
    ".properties.system_blobstore.external.droplets_bucket": {
      value: $dropletsBucket
    },
    ".properties.system_blobstore.external.packages_bucket": {
      value: $packagesBucket
    },
    ".properties.system_blobstore.external.resources_bucket": {
      value: $resourcesBucket
    },
    ".properties.smtp_from": {
      value: $cfSmtpFrom
    },
    ".properties.smtp_address": {
      value: $cfSmtpAddress
    },
    ".properties.smtp_port": {
      value: $cfSmtpPort
    },
    ".properties.smtp_credentials": {
      value: {
        identity: $cfSmtpUsername,
        password: $cfSmtpPassword
      }
    },
    ".properties.smtp_enable_starttls_auto": {
      value: "true"
    }
  }
}')

curl "https://$opsmanDomain/api/v0/staged/products/$cfGuid/properties" -k \
    -X PUT \
    -H "Authorization: Bearer $UAA_ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$properties"

# Configure jobs
jobs=$(curl "https://$opsmanDomain/api/v0/staged/products/$cfGuid/jobs" -k \
    -X GET \
    -H "Authorization: Bearer $UAA_ACCESS_TOKEN")

# Configure router job
routerGuid=$(echo $jobs | jq -r '.jobs[] | select(.name == "router") | .guid')

routerConfig=$(curl "https://$opsmanDomain/api/v0/staged/products/$cfGuid/jobs/$routerGuid/resource_config" -k \
    -X GET \
    -H "Authorization: Bearer $UAA_ACCESS_TOKEN")

pcfElbDnsName=$(echo $stack | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "PcfElbDnsName") | .OutputValue')

pcfElbName=$(aws elb describe-load-balancers | jq -r --arg pcfElbDnsName $pcfElbDnsName '.LoadBalancerDescriptions[] | select(.DNSName == $pcfElbDnsName) | .LoadBalancerName')

routerConfigElb=$(echo $routerConfig | jq -r --arg pcfElbName $pcfElbName '.elb_names = [ $pcfElbName ]')

curl "https://$opsmanDomain/api/v0/staged/products/$cfGuid/jobs/$routerGuid/resource_config" -k \
    -X PUT \
    -H "Authorization: Bearer $UAA_ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$routerConfigElb"

# Configure Diego Brain elb
pcfElbSshDns=$(echo $stack | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "PcfElbSshDnsName") | .OutputValue')

pcfElbSshName=$(aws elb describe-load-balancers | jq -r --arg pcfElbSshDns $pcfElbSshDns '.LoadBalancerDescriptions[] | select(.DNSName == $pcfElbSshDns) | .LoadBalancerName')

diegoBrainGuid=$(echo $jobs | jq -r '.jobs[] | select(.name == "diego_brain") | .guid')

diegoBrainConfig=$(curl "https://$opsmanDomain/api/v0/staged/products/$cfGuid/jobs/$diegoBrainGuid/resource_config" -k \
    -X GET \
    -H "Authorization: Bearer $UAA_ACCESS_TOKEN")

diegoBrainConfigWithElb=$(echo $diegoBrainConfig | jq -r --arg pcfElbSshName $pcfElbSshName '.elb_names = [ $pcfElbSshName ]')

curl "https://$opsmanDomain/api/v0/staged/products/$cfGuid/jobs/$diegoBrainGuid/resource_config" -k \
    -X PUT \
    -H "Authorization: Bearer $UAA_ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$diegoBrainConfigWithElb"

# Upload stemcell
stemcell=$(ls stemcell/*.tgz)

curl "https://$opsmanDomain/api/v0/stemcells" -k \
    -X POST \
    -H "Authorization: Bearer $UAA_ACCESS_TOKEN" \
    -F "stemcell[file]=@$stemcell"

# Apply Changes
pendingChanges=$(curl "https://$opsmanDomain/api/v0/staged/pending_changes" -k \
    -X GET \
    -H "Authorization: Bearer $UAA_ACCESS_TOKEN")

postDeployErrands=$(echo $pendingChanges | jq --arg cfGuid $cfGuid '[.product_changes[] | select (.guid == $cfGuid) | .errands[] | select(.post_deploy == true) | .name]')

errandsData=$(jq -n \
--arg cfGuid "$cfGuid" \
--argjson postDeployErrands "$postDeployErrands" \
'{
  enabled_errands: {
    ($cfGuid): {
      post_deploy_errands: $postDeployErrands
    }
  }
}')

curl "https://$opsmanDomain/api/v0/installations" -k \
    -X POST \
    -H "Authorization: Bearer $UAA_ACCESS_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$errandsData"
