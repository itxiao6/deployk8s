source env.sh

# 创建kube-proxy证书签名请求
echo "=========创建kube-proxy证书签名请求========"
cat > ${KUBEPROXY_PATH}/kube-proxy-csr.json <<EOF
{
    "CN": "system:kube-proxy",
    "key": {
        "algo": "rsa",
        "size": 2048
    },
    "names": [
        {
            "C": "CN",
            "ST": "Shanghai",
            "L": "Shanghai",
            "O": "k8s",
            "OU": "kube-proxy"
        }
    ]
}
EOF
cat ${KUBEPROXY_PATH}/kube-proxy-csr.json

# 创建kube-proxy证书和私钥
echo "=======创建kube-proxy证书和私钥======="
cfssl gencert \
-ca=/etc/kubernetes/cert/ca.pem \
-ca-key=/etc/kubernetes/cert/ca-key.pem \
-config=/etc/kubernetes/cert/ca-config.json \
-profile=kubernetes \
${KUBEPROXY_PATH}/kube-proxy-csr.json | \
cfssljson -bare ${KUBEPROXY_PATH}/kube-proxy
if [ $? -ne 0 ];then echo "生成kube-proxy证书和私钥失败，退出脚本";exit 1;fi
ls ${KUBEPROXY_PATH}/kube-proxy*.pem

# 创建kube-proxy kubeconfig文件
echo "=========创建kube-proxy kubeconfig文件========="
kubectl config set-cluster kubernetes \
--certificate-authority=/etc/kubernetes/cert/ca.pem \
--server=${KUBE_APISERVER} \
--kubeconfig=${KUBEPROXY_PATH}/kube-proxy.kubeconfig

kubectl config set-credentials kube-proxy \
--client-certificate=/etc/kubernetes/cert/kube-proxy.pem \
--client-key=/etc/kubernetes/cert/kube-proxy-key.pem \
--kubeconfig=${KUBEPROXY_PATH}/kube-proxy.kubeconfig

kubectl config set-context default \
--cluster=kubernetes \
--user=kube-proxy \
--kubeconfig=${KUBEPROXY_PATH}/kube-proxy.kubeconfig

kubectl config use-context default \
--kubeconfig=${KUBEPROXY_PATH}/kube-proxy.kubeconfig
cat ${KUBEPROXY_PATH}/kube-proxy.kubeconfig

# 创建kube-proxy配置模板
echo "=========创建kube-proxy配置模板========"
cat > ${KUBEPROXY_PATH}/kube-proxy.config.yaml.template <<EOF
apiVersion: kubeproxy.config.k8s.io/v1alpha1
bindAddress: ##NODE_IP##
clientConnection:
  kubeconfig: /etc/kubernetes/kube-proxy.kubeconfig
clusterCIDR: ${CLUSTER_CIDR}
healthzBindAddress: ##NODE_IP##:10256
hostnameOverride: ##NODE_NAME##
kind: KubeProxyConfiguration
metricsBindAddress: ##NODE_IP##:10249
mode: "iptables"
EOF
ls ${KUBEPROXY_PATH}/kube-proxy.config.yaml.template

# 创建kube-proxy配置文件
echo "=========创建kube-proxy配置文件========"
for ((i=0; i < 3; i++))
  do
    echo ">>> ${NODE_IPS[i]}"
    sed -e "s/##NODE_NAME##/${NODE_NAMES[i]}/" \
        -e "s/##NODE_IP##/${NODE_IPS[i]}/" \
    ${KUBEPROXY_PATH}/kube-proxy.config.yaml.template > \
    ${KUBEPROXY_PATH}/kube-proxy-${NODE_IPS[i]}.config.yaml
    cat ${KUBEPROXY_PATH}/kube-proxy-${NODE_IPS[i]}.config.yaml
  done

# 创建kube-proxy systemd service文件
echo "========创建kube-proxy systemd service文件========="
cat > ${KUBEPROXY_PATH}/kube-proxy.service <<EOF
[Unit]
Description=Kubernetes Kube-Proxy Server
Documentation=https://github.com/GoogleCloudPlatform/kubernetes
After=network.target

[Service]
WorkingDirectory=/var/lib/kube-proxy
ExecStart=/usr/local/bin/kube-proxy \\
--config=/etc/kubernetes/kube-proxy.config.yaml \\
--alsologtostderr=true \\
--logtostderr=false \\
--log-dir=/var/log/kubernetes \\
--v=2
Restart=on-failure
RestartSec=60
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF
cat ${KUBEPROXY_PATH}/kube-proxy.service

# 分发kube-proxy并启动
echo "=======分发kube-proxy并启动========"
for node_ip in ${NODE_IPS[@]}
  do
    echo ">>> ${node_ip}"
    echo "分发kube-proxy二进制文件"
    ssh root@${node_ip} "
      if [ -f /usr/local/bin/kube-proxy ];then
      systemctl stop kube-proxy
      rm -f /usr/local/bin/kube-proxy
      fi"
    scp ${KUBEPROXY_PATH}/kube-proxy \
      root@${node_ip}:/usr/local/bin/
    
    echo "分发kube-proxy证书和私钥"
    ssh root@${node_ip} "mkdir -p /etc/kubernetes/cert"
    scp ${KUBEPROXY_PATH}/kube-proxy*.pem \
    root@${node_ip}:/etc/kubernetes/cert/

    echo "分发kube-proxy kubeconfig文件"
    ssh root@${node_ip} "mkdir -p /etc/kubernetes"
    scp ${KUBEPROXY_PATH}/kube-proxy.kubeconfig \
    root@${node_ip}:/etc/kubernetes/

    echo "分发kube-proxy配置文件"
    scp ${KUBEPROXY_PATH}/kube-proxy-${node_ip}.config.yaml \
      root@${node_ip}:/etc/kubernetes/kube-proxy.config.yaml

    echo "分发kube-proxy systemd service文件"
    scp ${KUBEPROXY_PATH}/kube-proxy.service \
      root@${node_ip}:/usr/lib/systemd/system/

    echo "启动kube-proxy"
    ssh root@${node_ip} "
      mkdir -p /var/lib/kube-proxy
      mkdir -p /var/log/kubernetes
      systemctl daemon-reload
      systemctl enable kube-proxy
      systemctl start kube-proxy
      echo 'wait 5s for kube-proxy up'
      sleep 5
      systemctl status kube-proxy | grep Active
      netstat -lnpt | grep kube-pro"

    if [ $? -ne 0 ];then echo "启动kube-proxy失败，退出脚本";exit 1;fi
  done
