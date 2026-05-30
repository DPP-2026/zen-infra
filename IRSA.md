IAM Roles for Service Accounts (IRSA) on EKS
Give your Kubernetes pods secure, fine-grained AWS permissions — no hardcoded credentials needed.

📖 What is IRSA?
IAM Roles for Service Accounts (IRSA) lets you assign an AWS IAM Role directly to a Kubernetes Service Account. Any pod that uses that Service Account automatically gets temporary AWS credentials via the pod's identity — no .aws/credentials files, no environment variable hacks.

Pod → Service Account → IAM Role → AWS S3


🗺️ Overview of Steps
Step
What We Do
1
Install prerequisites
2
Create an EKS cluster with eksctl
3
Enable OIDC provider on the cluster
4
Create an S3 bucket (if needed)
5
Create an IAM policy for S3 access
6
Create an IAM Role + Service Account (IRSA)
7
Deploy a pod and verify S3 access



✅ Prerequisites
Install the following tools before starting:

# 1. AWS CLI

brew install awscli          # macOS

# or follow: https://docs.aws.amazon.com/cli/latest/userguide/install-cliv2.html

# 2. eksctl

brew tap weaveworks/tap

brew install weaveworks/tap/eksctl

# 3. kubectl

brew install kubectl

# 4. Confirm versions

aws --version

eksctl version

kubectl version --client

Also make sure your AWS credentials are configured:

aws configure

# Enter: AWS Access Key ID, Secret Key, Region (e.g. ap-south-1), Output format (json)


Step 1 — Create the EKS Cluster
Create a file named cluster.yaml:

# cluster.yaml

apiVersion: eksctl.io/v1alpha5

kind: ClusterConfig

metadata:

  name: my-cluster          # Change this to your preferred cluster name

  region: ap-south-1        # Change to your AWS region

managedNodeGroups:

  - name: ng-1

    instanceType: t3.medium

    desiredCapacity: 2

    minSize: 1

    maxSize: 3

Now create the cluster:

eksctl create cluster -f cluster.yaml

⏳ This takes about 15–20 minutes. Grab a coffee!

Once done, verify the cluster is up:

kubectl get nodes

# You should see 2 nodes in Ready state


Step 2 — Enable the OIDC Provider
IRSA works by linking your cluster to an OIDC (OpenID Connect) identity provider. This is what allows AWS to trust tokens issued by your Kubernetes cluster.

# Replace with your cluster name and region

eksctl utils associate-iam-oidc-provider \

  --cluster my-cluster \

  --region ap-south-1 \

  --approve

Verify it was created:

aws iam list-open-id-connect-providers

# You should see an ARN listed — that's your cluster's OIDC provider


Step 3 — Create an S3 Bucket (Skip if you have one)
# Replace with a globally unique name

aws s3 mb s3://my-irsa-demo-bucket --region ap-south-1

Add a test file so we can verify access later:

echo "Hello from S3!" > test.txt

aws s3 cp test.txt s3://my-irsa-demo-bucket/test.txt


Step 4 — Create an IAM Policy for S3 Access
Create a file named s3-policy.json:

{

  "Version": "2012-10-17",

  "Statement": [

    {

      "Effect": "Allow",

      "Action": [

        "s3:GetObject",

        "s3:PutObject",

        "s3:ListBucket"

      ],

      "Resource": [

        "arn:aws:s3:::my-irsa-demo-bucket",

        "arn:aws:s3:::my-irsa-demo-bucket/*"

      ]

    }

  ]

}

💡 Replace my-irsa-demo-bucket with your actual bucket name.

Apply the policy:

aws iam create-policy \

  --policy-name S3AccessPolicy \

  --policy-document file://s3-policy.json

Note down the Policy ARN from the output. It looks like:

arn:aws:iam::123456789012:policy/S3AccessPolicy


Step 5 — Create the IAM Role + Kubernetes Service Account
This single eksctl command does three things at once:

Creates an IAM Role
Attaches the S3 policy to it
Creates a Kubernetes Service Account linked to that role

eksctl create iamserviceaccount \

  --name s3-access-sa \

  --namespace default \

  --cluster my-cluster \

  --region ap-south-1 \

  --attach-policy-arn arn:aws:iam::123456789012:policy/S3AccessPolicy \

  --approve \

  --override-existing-serviceaccounts

Replace the --attach-policy-arn value with your actual Policy ARN from Step 4.

Verify the Service Account was created:

kubectl get serviceaccount s3-access-sa -n default -o yaml

You should see an annotation like this in the output:

annotations:

  eks.amazonaws.com/role-arn: arn:aws:iam::123456789012:role/eksctl-my-cluster-addon-iamserviceaccount-...

✅ That annotation is the key — it's what links your pod to the IAM Role.


Step 6 — Deploy a Pod to Test S3 Access
Create a file named s3-test-pod.yaml:

# s3-test-pod.yaml

apiVersion: v1

kind: Pod

metadata:

  name: s3-test-pod

  namespace: default

spec:

  serviceAccountName: s3-access-sa   # 👈 This links the pod to the IAM Role

  containers:

    - name: aws-cli

      image: amazon/aws-cli:latest

      command: ["sleep", "3600"]     # Keep the pod alive for 1 hour

  restartPolicy: Never

Deploy it:

kubectl apply -f s3-test-pod.yaml

# Wait for it to be Running

kubectl get pod s3-test-pod


Step 7 — Verify S3 Access from Inside the Pod
# Open a shell inside the pod

kubectl exec -it s3-test-pod -- bash

# Inside the pod, run these commands:

# List the bucket contents

aws s3 ls s3://my-irsa-demo-bucket

# Download the test file

aws s3 cp s3://my-irsa-demo-bucket/test.txt /tmp/test.txt

cat /tmp/test.txt

# Output: Hello from S3!

# Upload a file

echo "Written from the pod!" > /tmp/from-pod.txt

aws s3 cp /tmp/from-pod.txt s3://my-irsa-demo-bucket/from-pod.txt

If these commands work — 🎉 IRSA is set up correctly!


🧹 Cleanup
When you're done, clean up to avoid AWS charges:

# Delete the pod

kubectl delete pod s3-test-pod

# Delete the cluster (this also removes the Service Account and IAM Role)

eksctl delete cluster --name my-cluster --region ap-south-1

# Delete the IAM policy

aws iam delete-policy --policy-arn arn:aws:iam::123456789012:policy/S3AccessPolicy

# Delete the S3 bucket

aws s3 rb s3://my-irsa-demo-bucket --force


🔍 How It Works Under the Hood
┌─────────────────────────────────────────────────────┐

│                   EKS Cluster                       │

│                                                     │

│   Pod                                               │

│   └── serviceAccountName: s3-access-sa             │

│        └── annotation: eks.amazonaws.com/role-arn  │

│             └── IAM Role (S3AccessPolicy attached) │

│                  └── Temporary credentials via STS │

│                       └── Accesses S3 Bucket ✅    │

└─────────────────────────────────────────────────────┘

When the pod starts, the EKS pod identity webhook injects a web identity token into the pod.
The AWS SDK inside the pod sees this token and calls AWS STS to exchange it for temporary credentials.
STS validates the token against the cluster's OIDC provider.
Temporary credentials are returned — valid for a short time and automatically refreshed.
The pod uses these credentials to access S3.

No long-lived keys. No secrets to manage. ✅



