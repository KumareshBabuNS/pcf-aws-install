#!/bin/bash

set -e -x

stackname=$AWS_CLOUDFORMATION_STACK_NAME
opsmanAmi=$OPS_MANAGER_AMI
keyName=$AWS_KEY_NAME

stack=$(aws cloudformation describe-stacks --stack-name $stackname)

opsmanSgId=$(echo $stack | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "PcfOpsManagerSecurityGroupId") | .OutputValue')
opsmanSubnetId=$(echo $stack | jq -r '.Stacks[0].Outputs[] | select(.OutputKey == "PcfPublicSubnetId") | .OutputValue')

ec2Instance=$(aws ec2 run-instances \
  --image-id $opsmanAmi \
  --count 1 \
  --instance-type m3.large \
  --key-name $keyName \
  --security-group-ids $opsmanSgId \
  --subnet-id $opsmanSubnetId \
  --associate-public-ip-address \
  --block-device-mappings '[{"DeviceName":"/dev/sda1","Ebs":{"VolumeSize":100,"VolumeType":"gp2"}}]')

ec2InstanceId=$(echo $ec2Instance | jq -r ".Instances[0].InstanceId")

aws ec2 create-tags --resources $ec2InstanceId --tags "Key=Name,Value=Ops Manager"

aws ec2 wait instance-running --instance-ids $ec2InstanceId
