import boto3

client = boto3.client('ec2', region_name='us-east-1')

response1 = client.create_security_group(
    GroupName="sg_tf_ec2",
    Description="SSH - HTTP",
    VpcId="vpc-0461807bed973b847"
)

response2 = client.authorize_security_group_ingress(
    GroupId="sg-preview-1",
    IpPermissions=[{"IpProtocol": "tcp", "FromPort": 22, "ToPort": 22, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}, {"IpProtocol": "tcp", "FromPort": 80, "ToPort": 80, "IpRanges": [{"CidrIp": "0.0.0.0/0"}]}]
)

response3 = client.run_instances(
    MaxCount=1,
    MinCount=1,
    ImageId="ami-0c30b7300f5fb34cd",
    InstanceType="t3.small",
    KeyName="cf36-aws-nv-sshkeys",
    EbsOptimized=True,
    BlockDeviceMappings=[{"DeviceName": "/dev/sda1", "Ebs": {"Encrypted": False, "DeleteOnTermination": True, "Iops": 3000, "SnapshotId": "snap-0dcac6c306445999c", "VolumeSize": 10, "VolumeType": "gp3", "Throughput": 125}}],
    NetworkInterfaces=[{"SubnetId": "subnet-065e5315bbd873c9e", "AssociatePublicIpAddress": True, "DeviceIndex": 0, "Groups": ["sg-preview-1"]}],
    CreditSpecification={"CpuCredits": "unlimited"},
    TagSpecifications=[{"ResourceType": "instance", "Tags": [{"Key": "Name", "Value": "Linux"}]}],
    MetadataOptions={"HttpEndpoint": "enabled", "HttpPutResponseHopLimit": 2, "HttpTokens": "required"},
    PrivateDnsNameOptions={"HostnameType": "ip-name", "EnableResourceNameDnsARecord": False, "EnableResourceNameDnsAAAARecord": False}
)
