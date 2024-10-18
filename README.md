# Weights and Biases on OCI OKE

This quickstart template deploys the self managed [WandB](https://wandb.org/) on [Oracle Kubernetes Engine (OKE)](https://docs.oracle.com/en-us/iaas/Content/ContEng/Concepts/contengoverview.htm).

# Pre-Requisites

Please read the following prerequisites sections thoroughly prior to deployment.

## Instance Principals & IAM Policy

Deployment depends on use of [Instance Principals](https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/callingservicesfrominstances.htm) via OCI CLI to generate kube config for use with kubectl. You should create a [dynamic group](https://docs.oracle.com/en-us/iaas/Content/Identity/Tasks/managingdynamicgroups.htm) for the compartment where you are deploying wandb.

    instance.compartment.id='ocid.comp....'

After creating the group, you should set specific [IAM policies](https://docs.oracle.com/en-us/iaas/Content/Identity/Reference/policyreference.htm) for OCI service interaction:

    Allow dynamic-group wandb to manage cluster-family in compartment wandb
    Allow dynamic-group wandb to manage object-family in compartment wandb
    Allow dynamic-group wandb to manage virtual-network-family in compartment wandb

## Storing WandB artifacts to OCI Bucket

Weights and Biases allows to use an Object Storage Bucket of your choosing only when using a paying licence.
Specifying the Bucket is easly done using the Console. More info can be found on [Wandb Bring Your Own Bucket](https://docs.wandb.ai/guides/hosting/data-security/secure-storage-connector/).

## Reserved Public IP

Deployment depends on a public ip for the Load Balancer. This is used to create the certificates and expose the Wandb Console to public network. Go to [Create a Reserved Public IP](https://docs.oracle.com/en-us/iaas/Content/Network/Tasks/reserved-public-ip-create.htm).

# Deployment

This deployment uses [Oracle Resource Manager](https://docs.oracle.com/en-us/iaas/Content/ResourceManager/Concepts/resourcemanager.htm) and consists of a VCN,an OKE Cluster with Node Pool, and an Edge node. The Edge node installs OCI CLI, Kubectl, wandb and configures everything. This is done using [cloudinit](userdata/cloudinit.sh) - the build process is logged in `/var/log/OKE-wandb-initialize.log`.

_Note that you should select shapes and scale your node pool as appropriate for your workload._

This template deploys the following by default:

- Virtual Cloud Network
  - Public (Edge) Subnet
  - Private Subnet
  - Internet Gateway
  - NAT Gateway
  - Service Gateway
  - Route tables
  - Security Lists
    - TCP 22 for Edge SSH on public subnet
    - Ingress to both subnets from VCN CIDR
    - Egress to Internet for both subnets
- OCI Virtual Machine Edge Node
- OKE Cluster and Node Pool
- Load Balancer

Simply click the Deploy to OCI button to create an ORM stack, then walk through the menu driven deployment. Once the stack is created, use the menu to Plan and Apply the template.

[![Deploy to Oracle Cloud](https://oci-resourcemanager-plugin.plugins.oci.oraclecloud.com/latest/deploy-to-oracle-cloud.svg)](https://console.us-ashburn-1.oraclecloud.com/resourcemanager/stacks/create?region=home&zipUrl=https://github.com/GabrielFeodorov/WandB_on_OKE/archive/refs/heads/main.zip)

## OKE post-deployment

Please wait for 10-12 minutes until the cloud init script installs and configures everything.

You can check status of the OKE cluster using the following kubectl commands:

    kubectl get all -A

### wandb Access

The console should be available at `https://wandb.<reserved_public_ip>.nip.io`. In case you're not seeing it, please wait for it to be available or:

    ssh -i ~/.ssh/PRIVATE_KEY opc@EDGE_NODE_IP
    cat /var/log/OKE-wandb-initialize.log|egrep -i "Point your browser to"

Wandb offers the use of a trial licence but it has limitations.
Information on how to configure the accounts and licence can be found on [this page](https://docs.wandb.ai/guides/hosting/self-managed/basic-setup).

### Destroying the Stack

Note that with the inclusion of SSL Load Balancer, you will need to remove the `ingress-nginx-controller` service before you destroy the stack, or you will get an error.

    kubectl delete svc ingress-nginx-controller -n ingress-nginx

This will remove the service, then you can destroy the build without errors.
