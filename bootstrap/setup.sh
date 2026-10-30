#!/usr/bin/env bash
# ONE-TIME setup. Run from AWS CloudShell (ap-south-2) or a machine with admin credentials:
#   bash bootstrap/setup.sh
# Creates: CodeCommit repo, S3 artifact bucket, DB password in SSM Parameter Store,
# EC2 instance role/profile, CodeBuild service role, and 3 CodeBuild projects.
# Safe to re-run.
set -euo pipefail
cd "$(dirname "$0")/.."
source config.env

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
REPO_NAME=${REPO_NAME:-$APP_NAME}
BRANCH=${BRANCH:-main}
ARTIFACT_BUCKET=${ARTIFACT_BUCKET:-$APP_NAME-artifacts-$ACCOUNT_ID-$AWS_REGION}
CB_ROLE=$APP_NAME-codebuild-role
EC2_ROLE=$APP_NAME-ec2-role
CB_IMAGE=${CB_IMAGE:-aws/codebuild/standard:7.0}
TMP=$(mktemp -d)

echo "Account $ACCOUNT_ID | Region $AWS_REGION | Bucket $ARTIFACT_BUCKET"

echo "== 1. CodeCommit repository =="
aws codecommit get-repository --repository-name "$REPO_NAME" >/dev/null 2>&1 || \
  aws codecommit create-repository --repository-name "$REPO_NAME" \
    --repository-description "FDE Task Tracker - ui, api, db" >/dev/null
REPO_URL=$(aws codecommit get-repository --repository-name "$REPO_NAME" \
  --query repositoryMetadata.cloneUrlHttp --output text)
echo "$REPO_URL"

echo "== 2. S3 artifact bucket =="
if ! aws s3api head-bucket --bucket "$ARTIFACT_BUCKET" 2>/dev/null; then
  aws s3api create-bucket --bucket "$ARTIFACT_BUCKET" \
    --create-bucket-configuration LocationConstraint="$AWS_REGION" >/dev/null
fi
aws s3api put-public-access-block --bucket "$ARTIFACT_BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-versioning --bucket "$ARTIFACT_BUCKET" --versioning-configuration Status=Enabled

echo "== 3. DB password in SSM Parameter Store =="
if ! aws ssm get-parameter --name "$DB_PASSWORD_PARAM" >/dev/null 2>&1; then
  PW=$(python3 -c "import secrets,string;a=string.ascii_letters+string.digits;print(''.join(secrets.choice(a) for _ in range(24)))")
  aws ssm put-parameter --name "$DB_PASSWORD_PARAM" --type SecureString --value "$PW" >/dev/null
  echo "Created $DB_PASSWORD_PARAM"
fi

echo "== 4. EC2 instance role + profile =="
cat > "$TMP/ec2-trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ec2.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
cat > "$TMP/ec2-policy.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Effect":"Allow","Action":["s3:GetObject"],"Resource":"arn:aws:s3:::$ARTIFACT_BUCKET/releases/*"},
 {"Effect":"Allow","Action":["s3:ListBucket"],"Resource":"arn:aws:s3:::$ARTIFACT_BUCKET"},
 {"Effect":"Allow","Action":["ssm:GetParameter"],"Resource":"arn:aws:ssm:$AWS_REGION:$ACCOUNT_ID:parameter/$APP_NAME/*"}
]}
EOF
aws iam get-role --role-name "$EC2_ROLE" >/dev/null 2>&1 || \
  aws iam create-role --role-name "$EC2_ROLE" --assume-role-policy-document "file://$TMP/ec2-trust.json" >/dev/null
aws iam attach-role-policy --role-name "$EC2_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore
aws iam put-role-policy --role-name "$EC2_ROLE" --policy-name app-access \
  --policy-document "file://$TMP/ec2-policy.json"
aws iam get-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE" >/dev/null 2>&1 || {
  aws iam create-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE" >/dev/null
  aws iam add-role-to-instance-profile --instance-profile-name "$EC2_INSTANCE_PROFILE" --role-name "$EC2_ROLE"
}

echo "== 5. CodeBuild service role =="
cat > "$TMP/cb-trust.json" <<'EOF'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"codebuild.amazonaws.com"},"Action":"sts:AssumeRole"}]}
EOF
cat > "$TMP/cb-policy.json" <<EOF
{"Version":"2012-10-17","Statement":[
 {"Sid":"Logs","Effect":"Allow","Action":["logs:CreateLogGroup","logs:CreateLogStream","logs:PutLogEvents"],
  "Resource":"arn:aws:logs:$AWS_REGION:$ACCOUNT_ID:log-group:/aws/codebuild/$APP_NAME-*"},
 {"Sid":"Source","Effect":"Allow","Action":["codecommit:GitPull"],
  "Resource":"arn:aws:codecommit:$AWS_REGION:$ACCOUNT_ID:$REPO_NAME"},
 {"Sid":"Artifacts","Effect":"Allow","Action":["s3:GetObject","s3:PutObject","s3:ListBucket","s3:GetBucketLocation"],
  "Resource":["arn:aws:s3:::$ARTIFACT_BUCKET","arn:aws:s3:::$ARTIFACT_BUCKET/*"]},
 {"Sid":"Ec2Read","Effect":"Allow","Action":["ec2:Describe*"],"Resource":"*"},
 {"Sid":"Ec2Provision","Effect":"Allow","Action":["ec2:RunInstances","ec2:StartInstances","ec2:CreateTags",
   "ec2:CreateSecurityGroup","ec2:AuthorizeSecurityGroupIngress"],"Resource":"*",
  "Condition":{"StringEquals":{"aws:RequestedRegion":"$AWS_REGION"}}},
 {"Sid":"PassEc2Role","Effect":"Allow","Action":"iam:PassRole",
  "Resource":"arn:aws:iam::$ACCOUNT_ID:role/$EC2_ROLE"},
 {"Sid":"UbuntuAmiLookup","Effect":"Allow","Action":["ssm:GetParameter","ssm:GetParameters"],
  "Resource":"arn:aws:ssm:$AWS_REGION::parameter/aws/service/canonical/*"},
 {"Sid":"SsmDeploy","Effect":"Allow","Action":["ssm:SendCommand","ssm:GetCommandInvocation",
   "ssm:ListCommandInvocations","ssm:DescribeInstanceInformation"],"Resource":"*"}
]}
EOF
aws iam get-role --role-name "$CB_ROLE" >/dev/null 2>&1 || \
  aws iam create-role --role-name "$CB_ROLE" --assume-role-policy-document "file://$TMP/cb-trust.json" >/dev/null
aws iam put-role-policy --role-name "$CB_ROLE" --policy-name pipeline-access \
  --policy-document "file://$TMP/cb-policy.json"
CB_ROLE_ARN=$(aws iam get-role --role-name "$CB_ROLE" --query Role.Arn --output text)
echo "Waiting 15s for IAM propagation..."; sleep 15

echo "== 6. CodeBuild projects =="
make_project() {  # name buildspec
  local name=$1 spec=$2 json
  json=$(cat <<EOF
{"name":"$name",
 "source":{"type":"CODECOMMIT","location":"$REPO_URL","buildspec":"$spec","gitCloneDepth":1},
 "sourceVersion":"refs/heads/$BRANCH",
 "artifacts":{"type":"NO_ARTIFACTS"},
 "environment":{"type":"LINUX_CONTAINER","image":"$CB_IMAGE","computeType":"BUILD_GENERAL1_SMALL",
   "environmentVariables":[
     {"name":"ARTIFACT_BUCKET","value":"$ARTIFACT_BUCKET","type":"PLAINTEXT"},
     {"name":"APP_NAME","value":"$APP_NAME","type":"PLAINTEXT"}]},
 "serviceRole":"$CB_ROLE_ARN","timeoutInMinutes":45,
 "logsConfig":{"cloudWatchLogs":{"status":"ENABLED","groupName":"/aws/codebuild/$name"}}}
EOF
)
  if aws codebuild batch-get-projects --names "$name" --query 'projects[0].name' --output text | grep -q "$name"; then
    aws codebuild update-project --cli-input-json "$json" >/dev/null && echo "Updated $name"
  else
    aws codebuild create-project --cli-input-json "$json" >/dev/null && echo "Created $name"
  fi
}
make_project "$APP_NAME-build"     buildspecs/build.yml
make_project "$APP_NAME-provision" buildspecs/provision.yml
make_project "$APP_NAME-deploy"    buildspecs/deploy.yml

rm -rf "$TMP"
cat <<EOF

Setup complete.
  Repo:     $REPO_URL
  Bucket:   s3://$ARTIFACT_BUCKET
Next: push this code to the repo (branch $BRANCH), then run the jobs - see README.md.
EOF
