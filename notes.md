A practical AWS VPC naming convention uses a consistent, lowercase, hyphen-separated pattern such as 

[project/org]-[env]-[region]-[purpose]-vpc (for example, acme-prod-ap-south-1-core-vpc)

# Console

cloudbinary-dev-us-east-1-jobportal-gui-vpc
192.168.0.0/16 (IPV4 - Class-C : 192.168.0.0/16 )

aws ec2 create-vpc --no-amazon-provided-ipv6-cidr-block --instance-tenancy 'default' --cidr-block '192.168.0.0/16' --tag-specifications '{"ResourceType":"vpc","Tags":[{"Key":"Name","Value":"cloudbinary-dev-us-east-1-jobportal-gui-vpc"},{"Key":"Environment","Value":"dev"},{"Key":"Owner","Value":"platform-jobportal@cloudbinary.in"},{"Key":"Application","Value":"Job Portal"},{"Key":"CostCenter","Value":"CC-2026"},{"Key":"ManagedBy","Value":"Console"}]}' 

# IaC

cloudbinary-dev-us-east-1-jobportal-vpc
(IPV4 - Class-A : 10.0.0.0/16 )


Name : cloudbinary-dev-us-east-1-jobportal-gui-vpc
Environment : dev
Owner: platform-jobportal@cloudbinary.in
Application : Job Portal
CostCenter : CC-2026
ManagedBy : Console


IPV4 : 

5 Classess:
A : 10.0.0.0 Private 
    10.255.255.255
    
    172.15.0.0 : Public
B : 172.16.0.0 : Private ip
    172.17.0.0 : Private ip
    172.31.0.0 : Private ip
    172.32.0.0 : Public
C  : 
    192.167.0.0 : Public
    192.168.0.0 : Private ip
    192.169.0.0 : Public
D
E

Public : Pay and Use
IPv6: ? 2001:4860:7:805::c8

IPv4: ? 49.43.228.147

Private : Free

ISP : 1700 - 