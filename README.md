# Packaging a Multi party collaboration LLM Model app using Kiwi-ng

![Multi party collaboration example using LLM Model](/docs/images/app.png)

## Summary

This application demonstrates how to take the [secure multi-party collaboration application](https://github.com/aws-samples/sample-mpc-app-using-aws-nitrotpm/) and package it as a Zero Operator Access (ZOA) AWS NitroTPM based attested TEE Image. For more information refer to [this repo](https://github.com/aws-samples/sample-mpc-app-using-aws-nitrotpm/), for details about how the sample app provides capabilities to publish and consume fine-tuned domain-specific LLM models or AI/ML models by leveraging a **Trusted Execution Environment (TEE) built on AWS using AWS NitroTPM and Amazon EC2 instance attestation with access to GPU to accelerate computation**. It enables two entities to collaborate securely: Party-A (model owner) can securely publish models for customers without risk of model exfiltration, while Party-B (model consumer) can consume models without exposing sensitive input data.

In this repo we will focus on how to build, package the sample app using a combination of tools [Kiwi-ng](https://osinside.github.io/kiwi/), [aws-nitro-tpm-tools](https://github.com/aws/NitroTPM-Tools/), [dm-verity](https://docs.kernel.org/admin-guide/device-mapper/verity.html), [erofs](https://docs.kernel.org/filesystems/erofs.html), [coldsnap](https://github.com/awslabs/coldsnap) to standup an isolated execution envrionment with no interactive access like [SSH](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/connect-to-linux-instance.html), [AWS Systems Manager Session Manager](https://docs.aws.amazon.com/systems-manager/latest/userguide/session-manager.html), [EC2 Instance Connect](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/connect-linux-inst-eic.html), [EC2 Serial Console](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/ec2-serial-console.html). Further the output of executing the scripts in this repo will be an [Amazon Machine Image (AMI)](https://docs.aws.amazon.com/AWSEC2/latest/UserGuide/AMIs.html). The packaging steps in this repo builds on top of an [existing sample](https://github.com/amazonlinux/kiwi-image-descriptions-examples) with additional steps to overlay the [sample application](https://github.com/aws-samples/sample-mpc-app-using-aws-nitrotpm/).

### Image Building Environment

Here is a quick depiction of the simple build/package pipeline, for simplicity all running on the same EC2 instance.

![Attestable AMI build process using Kiwi-ng recipe](/docs/images/build.png)

Launch an EC2, maintain parity with the intended deployment instance family for covering situations where
binaries sensitive to gcc, kernel, dkms will be built. 
This particular image building process was built and tested on G5 instance, specifically a G5.2xlarge.

Launch an EC2 with G5.2xlarge, attach a 200GB EBS root volume. 
Choose an instance profile/role that gives you capability to remote ssh using ssm session manager. Policy AmazonSSMManagedInstanceCore will give you just that. 
Choose or [create](https://github.com/aws-samples/sample-mpc-app-using-aws-nitrotpm/blob/main/dev_build/scripts/create_tpm_enabled_ami_from_latest_al2023.sh) an AMI that has TPM drivers for this build environment.
Setup your IDE with remote SSH capability, for example VSCode with remote explorer plugin.
Clone this project onto the build EC2 instance.
Now rest of the instructions are assuming that you are on a dev/build machine interactively.


Start the image building process
```sh
git clone <repo url>
cd <git repo name>
chmod +x install.sh
./install.sh \
--image-name al2023-attestable-image-mpc-webapp-example \
> zoa_install.log

```
Wait for the AMI build to run to completion, final result will be ImageId written to [pcr_measurements.json file](file:///mnt/image/pcr_measurements.json) , for e.g. "ImageId": "ami-0de41dc494d86fd34". 

```sh
cat /mnt/image/pcr_measurements.json
```


### Creating a TPM-TEE from the Attestable AMI.

This section details the bare minimum services, components needed to test out the sample App. Note that is is not a best practice recommendation. We will use AWS CLI commands to create the necessary AWS services, there is a AWS CDK sample project also available in this repo that will help create this and much more.

#### IAM Policy

This sample app needs an IAM role that gives the TPM-TEE permissions to 
1. Download the encrypted artifacts from Amazon S3 bucket
2. Decrypt the datakey using AWS KMS key decrypt action.

This example also runs few additional functionality which you would not run out of a TEE typically and for those the following additional IAM permissions are also needed.
1. Mutate the KMS key policy with various PCR choices as conditions to demonstrate conditional sealing/unsealing.
2. Delete Loaded models from the S3 bucket.

#### IAM Role

Next we need to attach the policies to an IAM role. Create the IAM role and policy using AWS CLI:

```bash

# Create IAM role
aws iam create-role \
  --role-name TPM-TEE-Role \
  --assume-role-policy-document file://iam/trust-policy.json

# Create and attach policy
aws iam create-policy \
  --policy-name TPM-TEE-Policy \
  --policy-document file://iam/tpm-tee-policy.json


aws iam attach-role-policy \
  --role-name TPM-TEE-Role \
  --policy-arn arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):policy/TPM-TEE-Policy


# Create instance profile
aws iam create-instance-profile --instance-profile-name TPM-TEE-InstanceProfile
aws iam add-role-to-instance-profile \
  --instance-profile-name TPM-TEE-InstanceProfile \
  --role-name TPM-TEE-Role
```

Note:
In addition to the IAM permissions attached to the TEE, there would be other guardrails necessary depending on the usecase and threat model. Some are noted here as examples.

1. Scoping down the KMS decrypt to this TEEs measurements would be done by the Model Owner using KMS Key policy PCR conditions.
2. Scoping down the S3 bucket access and specific operations that TEE is allowed to perform would be done by the Model consumer.


### Create Security group

The sample app running in the TPM-TEE needs port 3000 opened to your public IP for testing. The Kiwi-ng recipe config.sh already [handles](recipe/test-image-overlayroot/config.sh#L133) letting traffic into port 3000 of the TEE. This security group rule further lets the port 3000 available out of the security group. Use the below CLI commands, replace the cidr with your public IP/32 CIDR.

```sh

# Create the security group (replace VPC-ID with actual VPC ID from the describe command)
aws ec2 create-security-group \
  --group-name TPM-TEE-SecurityGroup \
  --description "Security group for TPM-TEE instances" \
  --vpc-id vpc-xxxxxxxx \
  --region <aws-region>

# Add ingress rules (replace sg-xxxxxxxx with the new security group ID returned above)
aws ec2 authorize-security-group-ingress \
  --group-id sg-xxxxxxxx \
  --protocol tcp \
  --port 3000 \
  --cidr <your-public-ip>/32 \
  --region <aws-region>


```

### Launch an EC2 Instance

Launch an EC2 instance with the ami created as the build output, here is the AWS CLI command, adjust the parameters as necessary, important is the instance family to maintain build parity.

```sh
aws ec2 run-instances \
  --image-id <replace-ami-id-from-kiwi-build> \
  --instance-type g5.2xlarge \
  --security-group-ids <replace-with-security-group-created-above> \
  --subnet-id <replace-with-a-public-subnet> \
  --iam-instance-profile Arn=<replace-with-instance-profile-created-above> \
  --block-device-mappings '[{"DeviceName":"/dev/xvda","Ebs":{"VolumeSize":200,"VolumeType":"gp3"}}]' \
  --tag-specifications 'ResourceType=instance,Tags=[{Key=Name,Value=mpc-webapp-kiwi-zoa}]'
  ```


### Debugging

If you run into issues with building the AMI, the following logs will have relevant messages to assist in debugging. Further increase the kiwi logging level to verbose by setting [loglevel](install.sh#L129) to 0.

```sh
zoa_install.log
./image/build/image-root/var/log/kiwi-config.log
```
