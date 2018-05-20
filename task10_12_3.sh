#!/bin/bash
dir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "$dir/config"

#Create certs
mkdir $dir/docker/certs
openssl genrsa -out $dir/docker/certs/root.key 2048
openssl req -x509 -new\
        -key $dir/docker/certs/root.key\
        -days 365\
        -out $dir/docker/certs/root.crt\
        -subj '/C=UA/ST=Kharkiv/L=Kharkiv/O=NURE/OU=Mirantis/CN=rootCA'

openssl genrsa -out $dir/docker/certs/web.key 2048
openssl req -new\
        -key $dir/docker/certs/web.key\
        -nodes\
        -out $dir/docker/certs/web.csr\
        -subj "/C=UA/ST=Kharkiv/L=Karkiv/O=NURE/OU=Mirantis/CN=$(hostname -f)"

openssl x509 -req -extfile <(printf "subjectAltName=IP:${VM1_EXTERNAL_IP},DNS:${VM1_NAME}") -days 365 -in $dir/docker/certs/web.csr -CA $dir/docker/certs/root.crt -CAkey $dir/docker/certs/root.key -CAcreateserial -out $dir/docker/certs/web.crt

cat $dir/docker/certs/web.crt $dir/docker/certs/root.crt > $dir/docker/certs/web-bundle.crt

#Make directory for logs
mkdir -p $NGINX_LOG_DIR

#Change xml according to the config file
#External
MAC=52:54:00:`(date; cat /proc/interrupts) | md5sum | sed -r 's/^(.{6}).*$/\1/; s/([0-9a-f]{2})/\1:/g; s/:$//;'`
echo "<network>
  <name>${EXTERNAL_NET_NAME}</name>
  <forward mode='nat'/>
  <ip address='${EXTERNAL_NET_HOST_IP}' netmask='${EXTERNAL_NET_MASK}'>
    <dhcp>
      <range start='${EXTERNAL_NET}.2' end='${EXTERNAL_NET}.254'/>
      <host mac='${MAC}' name='${VM1_NAME}' ip='${VM1_EXTERNAL_IP}'/>
    </dhcp>
  </ip>
</network>" > $dir/networks/external.xml

#Inaternal
echo "<network>
  <name>${INTERNAL_NET_NAME}</name>
</network>" > $dir/networks/internal.xml

#Management
echo "<network>
  <name>${MANAGEMENT_NET_NAME}</name>
  <ip address='${MANAGEMENT_HOST_IP}' netmask='${MANAGEMENT_NET_MASK}'/>
</network>" > $dir/networks/management.xml

#VM1-config 
#meta-data
echo "instance-id: vm1-123
hostname: ${VM1_NAME}
local-hostname: ${VM1_NAME}
public-keys:
 - `cat ${SSH_PUB_KEY}`
network-interfaces: |
  auto ${VM1_EXTERNAL_IF}
  iface ${VM1_EXTERNAL_IF} inet dhcp
  
  auto ${VM1_INTERNAL_IF}
  iface ${VM1_INTERNAL_IF} inet static
  address ${VM1_INTERNAL_IP}
  netmask ${INTERNAL_NET_MASK}
  
  auto ${VM1_MANAGEMENT_IF} 
  iface ${VM1_MANAGEMENT_IF} inet static
  address ${VM1_MANAGEMENT_IP}
  netmask ${MANAGEMENT_NET_MASK}" > $dir/config-drives/vm1-config/meta-data

#user-data
echo "#!/bin/bash

echo 1 > /proc/sys/net/ipv4/ip_forward
iptables -t nat -A POSTROUTING -o ${VM1_EXTERNAL_IF} -j MASQUERADE
ip link add ${VXLAN_IF} type vxlan id ${VID} remote ${VM2_INTERNAL_IP} local ${VM1_INTERNAL_IP} dstport 4789
ip link set ${VXLAN_IF} up
ip addr add ${VM1_VXLAN_IP}/24 dev ${VXLAN_IF}
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
apt-key fingerprint 0EBFCD88
add-apt-repository 'deb [arch=amd64] https://download.docker.com/linux/ubuntu xenial stable'
apt-get update
apt-get install docker-ce -y
mount /dev/cdrom /mnt
cp -r /mnt/docker /home/ubuntu
umount /dev/cdrom
docker run -d -v /home/ubuntu/docker/etc/:/etc/nginx/conf.d -v /home/ubuntu/docker/certs:/etc/ssl/certs -v ${NGINX_LOG_DIR}:/var/log/nginx -p ${NGINX_PORT}:443 ${NGINX_IMAGE}" > $dir/config-drives/vm1-config/user-data

#VM2-config
#meta-data
echo "instance-id: vm2-123
hostname: ${VM2_NAME}
local-hostname: ${VM2_NAME}
public-keys:
 - `cat ${SSH_PUB_KEY}`
network-interfaces: |
  auto ${VM2_INTERNAL_IF}
  iface ${VM2_INTERNAL_IF} inet static
  address ${VM2_INTERNAL_IP}
  netmask ${INTERNAL_NET_MASK}
  gateway ${VM1_INTERNAL_IP}
  dns-nameservers ${VM_DNS}
  
  auto ${VM2_MANAGEMENT_IF} 
  iface ${VM2_MANAGEMENT_IF} inet static
  address ${VM2_MANAGEMENT_IP}
  netmask ${MANAGEMENT_NET_MASK}" > $dir/config-drives/vm2-config/meta-data

#user-data
echo "#!/bin/bash

ip link add ${VXLAN_IF} type vxlan id ${VID} remote ${VM1_INTERNAL_IP} local ${VM2_INTERNAL_IP} dstport 4789
ip link set ${VXLAN_IF} up
ip addr add ${VM2_VXLAN_IP}/24 dev ${VXLAN_IF}
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo apt-key add -
apt-key fingerprint 0EBFCD88
add-apt-repository 'deb [arch=amd64] https://download.docker.com/linux/ubuntu xenial stable'
apt-get update
apt-get install docker-ce -y
docker run -d -p ${APACHE_PORT}:80 ${APACHE_IMAGE}" > $dir/config-drives/vm2-config/user-data

#Create networks
virsh net-define $dir/networks/external.xml
virsh net-define $dir/networks/internal.xml
virsh net-define $dir/networks/management.xml

#Start networks
virsh net-start external
virsh net-start internal
virsh net-start management

#Download image and create disks
wget -O /var/lib/libvirt/images/ubuntu-server-16.04.qcow2 ${VM_BASE_IMAGE}
mkdir /var/lib/libvirt/images/vm1
mkdir /var/lib/libvirt/images/vm2
cp /var/lib/libvirt/images/ubuntu-server-16.04.qcow2 /var/lib/libvirt/images/vm1/vm1.qcow2
cp /var/lib/libvirt/images/ubuntu-server-16.04.qcow2 /var/lib/libvirt/images/vm2/vm2.qcow2

#Create iso conf drive
cp -r $dir/docker $dir/config-drives/vm1-config
mkisofs -o "/var/lib/libvirt/images/vm1/config-vm1.iso" -V cidata -r -J $dir/config-drives/vm1-config
mkisofs -o "/var/lib/libvirt/images/vm2/config-vm2.iso" -V cidata -r -J $dir/config-drives/vm2-config

#Nginx conf editing
echo "server {
        listen 443 ssl;
        ssl on;
        ssl_certificate /etc/ssl/certs/web-bundle.crt;
        ssl_certificate_key /etc/ssl/certs/web.key;
        location / {
                proxy_pass http://${VM2_VXLAN_IP}:${APACHE_PORT};
}
}" > $dir/docker/etc/nginx.conf

#Install VM1
virt-install --connect qemu:///system \
--name ${VM1_NAME} \
--ram ${VM1_MB_RAM} --vcpus=${VM1_NUM_CPU} --${VM_TYPE} \
--os-type=linux --os-variant=ubuntu16.04 \
--disk path=${VM1_HDD},format=qcow2,bus=virtio,cache=none \
--disk path=${VM1_CONFIG_ISO},device=cdrom \
--network network=${EXTERNAL_NET_NAME},mac=${MAC} \
--network network=${INTERNAL_NET_NAME} \
--network network=${MANAGEMENT_NET_NAME} \
--graphics vnc,port=-1 \
--noautoconsole --virt-type ${VM_VIRT_TYPE} --import

#Install VM2
virt-install --connect qemu:///system \
--name ${VM2_NAME} \
--ram ${VM2_MB_RAM} --vcpus=${VM2_NUM_CPU} --${VM_TYPE} \
--os-type=linux --os-variant=ubuntu16.04 \
--disk path=${VM2_HDD},format=qcow2,bus=virtio,cache=none \
--disk path=${VM2_CONFIG_ISO},device=cdrom \
--network network=${INTERNAL_NET_NAME} \
--network network=${MANAGEMENT_NET_NAME} \
--graphics vnc,port=-1 \
--noautoconsole --virt-type ${VM_VIRT_TYPE} --import
