# Standalone EC2 Vodia proof of concept

This path launches a plain Canonical Ubuntu 24.04 x86_64 AMI in the AWS account of the AWS CLI caller, using a pre-existing subnet, security group and SSH key. It does not use the Vodia Marketplace AMI or make a Marketplace purchase. EC2 and encrypted EBS charges apply after `--apply`. The Vodia software may still require a license.

Run `deploy-vodia-ubuntu.sh --plan` in AWS CloudShell with AWS_REGION, SUBNET_ID, SECURITY_GROUP_ID, KEY_NAME and INSTANCE_NAME. The plan checks that the Canonical AMI has no Marketplace product code, the VPC and subnet align, the key and architecture exist, and IPv4 ports 22/80/443 appear in the security group. It downloads the official Vodia Linux installer to a temporary file and prints its SHA-256 hash. It does not launch anything. Review the vendor installer before use.

Run the same inputs with `--apply` and `INSTALLER_SHA256=<plan hash>`. Apply re-fetches and checks that exact vendor script before launching. The instance's user-data fetches it again, verifies the same hash, and executes it. If the upstream script changes during the process, installation stops; inspect root-only `/var/log/vodia-install.log` and rerun with a reviewed hash rather than blindly rerunning cloud-init. Cloud-init runs once at first launch. The PBX initial credentials are in the root-only installer log. No password is embedded in user data.

SSH 22 must be permitted from your admin IP so you can read the installer result. For call testing, configure SIP/RTP according to Vodia's port requirements. The script does not create a security group or open ports. No IAM instance profile is attached. The current Marketplace entitlement IAM profile is intentionally not reused for a plain Ubuntu image.

The launcher does not register the PBX with the MCP or create tenants, DNS, certificates or Microsoft Direct Routing. The next connection batch must bind a PBX API account to this EC2 instance. Manual installation has different initial credentials from the Marketplace AMI; use the installer output and change the password.

Local verification used mocked AWS and vendor endpoints to exercise both plan and apply paths and Bash syntax. No real AWS instance was created by development tests.
