source env.sh

# 创建flanneld证书签名请求
echo "==========创建flanneld证书签名请求========="
cat > ${FLANNEL_PATH}/flanneld-csr.json <<EOF
{
  "CN": "flanneld",
  "hosts": [],
  "key": {
    "algo": "rsa",
    "size": 2048
  },
  "names": [
    {
      "C": "CN",
      "ST": "BeiJing",
      "L": "BeiJing",
      "O": "k8s",
      "OU": "4Paradigm"
    }
  ]
}
EOF
cat ${FLANNEL_PATH}/flanneld-csr.json

# 生成flanneld证书和私钥
echo "=========生成flanneld证书和私钥========"
cfssl gencert \
-ca=/etc/kubernetes/cert/ca.pem \
-ca-key=/etc/kubernetes/cert/ca-key.pem \
-config=/etc/kubernetes/cert/ca-config.json \
-profile=kubernetes \
${FLANNEL_PATH}/flanneld-csr.json | \
cfssljson -bare ${FLANNEL_PATH}/flanneld
if [ $? -ne 0 ];then echo "生成flanneld证书和私钥失败，退出脚本";exit 1;fi
ls ${FLANNEL_PATH}/flanneld*.pem

# 向etcd写入集群Pod网段信息
echo "=========向etcd写入集群Pod网段信息========="
etcdctl \
--endpoints=${ETCD_ENDPOINTS} \
--ca-file=/etc/kubernetes/cert/ca.pem \
--cert-file=${FLANNEL_PATH}/flanneld.pem \
--key-file=${FLANNEL_PATH}/flanneld-key.pem \
set ${FLANNEL_ETCD_PREFIX}/config '{"Network":"'${CLUSTER_CIDR}'", 
"SubnetLen": 24, "Backend": {"Type": "vxlan"}}'

# 创建flanneld的systemd unit文件
echo "=======创建flanneld的systemd unit文件========="
#export IFACE=ens33
cat > ${FLANNEL_PATH}/flanneld.service << EOF
[Unit]
Description=Flanneld overlay address etcd agent
After=network.target
After=network-online.target
Wants=network-online.target
After=etcd.service
Before=docker.service

[Service]
Type=notify
ExecStart=/usr/local/bin/flanneld \\
  -etcd-cafile=/etc/kubernetes/cert/ca.pem \\
  -etcd-certfile=/etc/flanneld/cert/flanneld.pem \\
  -etcd-keyfile=/etc/flanneld/cert/flanneld-key.pem \\
  -etcd-endpoints=${ETCD_ENDPOINTS} \\
  -etcd-prefix=${FLANNEL_ETCD_PREFIX} \\
  -iface=${VIP_IF}
ExecStartPost=/usr/local/bin/mk-docker-opts.sh -k DOCKER_NETWORK_OPTIONS \\
  -d /run/flannel/docker
Restart=on-failure

[Install]
WantedBy=multi-user.target
RequiredBy=docker.service
EOF
cat ${FLANNEL_PATH}/flanneld.service

# 分发并启动flanneld
echo "=========分发并启动flanneld========"
for node_ip in ${NODE_IPS[@]}
  do
    echo ">>> ${node_ip}"
    echo "分发flanneld二进制文件"
    ssh root@${node_ip} "
      if [ -f /usr/local/bin/flanneld ];then
      systemctl stop flanneld
      rm -f /usr/local/bin/{flanneld,mk-docker-opts.sh}
      fi"
    scp ${FLANNEL_PATH}/{flanneld,mk-docker-opts.sh} \
    root@${node_ip}:/usr/local/bin/

    echo "分发flanneld证书和私钥"
    ssh root@${node_ip} "mkdir -p /etc/flanneld/cert"
    scp ${FLANNEL_PATH}/flanneld*.pem \
    root@${node_ip}:/etc/flanneld/cert/

    echo "分发flanneld.service"
    scp ${FLANNEL_PATH}/flanneld.service \
    root@${node_ip}:/usr/lib/systemd/system/

    echo "启动flanneld"
    ssh root@${node_ip} "
      systemctl daemon-reload
      systemctl enable flanneld
      systemctl start flanneld
      echo 'wait 5s for flanneld up'
      sleep 5
      systemctl status flanneld | grep Active"
    if [ $? -ne 0 ];then echo "启动flanneld失败，退出脚本";exit 1;fi

    echo "查看集群Pod网段"
    ssh root@${node_ip} "
      etcdctl \
      --endpoints=${ETCD_ENDPOINTS} \
      --ca-file=/etc/kubernetes/cert/ca.pem \
      --cert-file=/etc/flanneld/cert/flanneld.pem \
      --key-file=/etc/flanneld/cert/flanneld-key.pem \
      get ${FLANNEL_ETCD_PREFIX}/config"
    if [ $? -ne 0 ];then echo "查看集群Pod网段失败，退出脚本";exit 1;fi

    echo "查看已分配的Pod子网段列表"
    ssh root@${node_ip} "
      etcdctl \
      --endpoints=${ETCD_ENDPOINTS} \
      --ca-file=/etc/kubernetes/cert/ca.pem \
      --cert-file=/etc/flanneld/cert/flanneld.pem \
      --key-file=/etc/flanneld/cert/flanneld-key.pem \
      ls ${FLANNEL_ETCD_PREFIX}/subnets"
    if [ $? -ne 0 ];then echo "查看已分配的Pod子网段列表失败，退出脚本";exit 1;fi

    echo "验证各节点能通过Pod网段互通"
    ssh root@${node_ip} "ip addr show flannel.1 | grep -w inet"
  done
