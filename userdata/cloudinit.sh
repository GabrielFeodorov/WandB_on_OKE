#!/bin/bash
#adding comments to make code readable

set -o pipefail
LOG_FILE="/var/log/Wandb-initialize.log"
log() { 
	echo "$(date) [${EXECNAME}]: $*" >> "${LOG_FILE}" 
}



region=`curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/regionInfo/regionIdentifier`
load_balancer_ip=`curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v2/instance/metadata/load_balancer_ip`
oke_cluster_id=`curl -s -H "Authorization: Bearer Oracle" -L http://169.254.169.254/opc/v1/instance/metadata/oke_cluster_id`
country=`echo $region|awk -F'-' '{print $1}'`
city=`echo $region|awk -F'-' '{print $2}'`




cat <<EOF | sudo tee /etc/yum.repos.d/kubernetes.repo
[kubernetes]
name=Kubernetes
baseurl=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/
enabled=1
gpgcheck=0
repo_gpgcheck=0
gpgkey=https://pkgs.k8s.io/core:/stable:/v1.29/rpm/repodata/repomd.xml.key
EOF


yum install kubectl git -y >> $LOG_FILE


mkdir -p /home/opc/.kube
echo "source <(kubectl completion bash)" >> ~/.bashrc
echo "alias k='kubectl'" >> ~/.bashrc
echo "source <(kubectl completion bash)" >> /home/opc/.bashrc
echo "alias k='kubectl'" >> /home/opc/.bashrc
source ~/.bashrc



yum install python36-oci-cli -y >> $LOG_FILE

echo "export OCI_CLI_AUTH=instance_principal" >> ~/.bash_profile
echo "export OCI_CLI_AUTH=instance_principal" >> ~/.bashrc
echo "export OCI_CLI_AUTH=instance_principal" >> /home/opc/.bash_profile
echo "export OCI_CLI_AUTH=instance_principal" >> /home/opc/.bashrc




while [ ! -f /root/.kube/config ]
do
    sleep 5
	source ~/.bashrc
	oci ce cluster create-kubeconfig --cluster-id ${oke_cluster_id} --file /root/.kube/config  --region ${region} --token-version 2.0.0 >> $LOG_FILE
done

cp /root/.kube/config /home/opc/.kube/config
chown -R opc:opc /home/opc/.kube/


mkdir -p /opt/WandB
cd /opt/Wandb


cat <<EOF | tee /opt/WandB/wandb_namespace.yaml
apiVersion: v1
kind: Namespace
metadata:
  name: wandb
EOF


kubectl --kubeconfig /root/.kube/config create -f /opt/WandB/wandb_namespace.yaml



LBIP=$load_balancer_ip


DOMAIN="wandb.${LBIP}.nip.io"


mkdir -p /opt/LB_certs
cd /opt/LB_certs
openssl req -x509             -sha256 -days 356             -nodes             -newkey rsa:2048             -subj "/CN=${DOMAIN}/C=$country/L=$city"             -keyout rootCA.key -out rootCA.crt


cat > csr.conf <<EOF
[ req ]
default_bits = 2048
prompt = no
default_md = sha256
req_extensions = req_ext
distinguished_name = dn
[ dn ]
C = $country
ST = $city
L = $city
O = WandB
OU = WandB
CN = ${DOMAIN}
[ req_ext ]
subjectAltName = @alt_names
[ alt_names ]
DNS.1 = ${DOMAIN}
IP.1 = ${LBIP}
EOF


openssl genrsa -out "${DOMAIN}.key" 2048
openssl req -new -key "${DOMAIN}.key" -out "${DOMAIN}.csr" -config csr.conf

cat > cert.conf <<EOF
authorityKeyIdentifier=keyid,issuer
basicConstraints=CA:FALSE
keyUsage = digitalSignature, nonRepudiation, keyEncipherment, dataEncipherment
subjectAltName = @alt_names
[alt_names]
DNS.1 = ${DOMAIN}
IP.1 = ${LBIP}
EOF


openssl x509 -req     -in "${DOMAIN}.csr"     -CA rootCA.crt -CAkey rootCA.key     -CAcreateserial -out "${DOMAIN}.crt"     -days 365     -sha256 -extfile cert.conf

kubectl --kubeconfig /root/.kube/config create secret tls wandb-tls-cert --key=$DOMAIN.key --cert=$DOMAIN.crt -n wandb





cat <<EOF | tee /opt/WandB/wandb_deploy.yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: wandb
  namespace: wandb
spec:
  selector:
    matchLabels:
      app: wandb
  template:
    metadata:
      labels:
        app: wandb
    spec:
      containers:
        - name: wandb
          image: wandb/local
          resources:
            limits:
              memory: "1G"
              cpu: "500m"
          ports:
            - containerPort: 8080               
EOF

kubectl --kubeconfig /root/.kube/config apply -f /opt/WandB/wandb_deploy.yaml

sleep 30




cat <<EOF | tee /opt/WandB/wandb_api_service.yaml
apiVersion: v1
kind: Service
metadata:
  name: wandb-api-service
  namespace: wandb
spec:
  selector:
    app: wandb
  ports:
    - port: 8080
      targetPort: 8080
      protocol: TCP
      name: api
EOF

kubectl --kubeconfig /root/.kube/config apply -f /opt/WandB/wandb_api_service.yaml


kubectl --kubeconfig /root/.kube/config apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.11.2/deploy/static/provider/cloud/deploy.yaml
sleep 30

kubectl --kubeconfig /root/.kube/config delete svc ingress-nginx-controller -n ingress-nginx



cat <<EOF | tee /opt/WandB/nginx_service.yaml
apiVersion: v1
kind: Service
metadata:
  name: ingress-nginx-controller
  namespace: ingress-nginx
  labels:
    nginx: ingressgateway
  annotations:
    oci.oraclecloud.com/load-balancer-type: "lb"
    service.beta.kubernetes.io/oci-load-balancer-backend-protocol: "TCP"
    service.beta.kubernetes.io/oci-load-balancer-shape: "flexible"
    service.beta.kubernetes.io/oci-load-balancer-shape-flex-min: "10"
    service.beta.kubernetes.io/oci-load-balancer-shape-flex-max: "10"
spec:
  type: LoadBalancer
  loadBalancerIP: $load_balancer_ip
  selector:
    app.kubernetes.io/name: ingress-nginx
  ports:
    - name: https
      port: 443
      targetPort: 443
    - name: http
      port: 80
      targetPort: 80
EOF

kubectl --kubeconfig /root/.kube/config apply -f /opt/WandB/nginx_service.yaml





cat <<EOF | tee /opt/WandB/wandb_api_ingress.yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: wandb-api-ingress
  namespace: wandb
spec:
  ingressClassName: nginx
  tls:
  - hosts:
      - "$DOMAIN"
    secretName: wandb-tls-cert
  rules:
    - host: "$DOMAIN"
      http:
        paths:
          - pathType: Prefix
            path: "/"
            backend:
              service:
                name: wandb-api-service
                port:
                  number: 8080
EOF

kubectl --kubeconfig /root/.kube/config apply -f /opt/WandB/wandb_api_ingress.yaml





echo "Load Balancer IP is ${LBIP}" |tee -a $LOG_FILE
echo "Point your browser to https://${DOMAIN}" |tee -a $LOG_FILE