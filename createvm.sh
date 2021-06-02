#!/bin/bash

vmList="ubuntu1:192.168.1.223 ubuntu2:192.168.1.224 ubuntu3:192.168.1.225 ubuntu4:192.168.1.226 ubuntu5:192.168.1.227"

function mask2cdr(){
   # Assumes there's no "255." after a non-255 byte in the mask
   local x=${1##*255.}
   set -- 0^^^128^192^224^240^248^252^254^ $(( (${#1} - ${#x})*2 )) ${x%%.*}
   x=${1%%$3*}
   echo $(( $2 + (${#x}/4) ))
}

function createNetwork(){
  virsh net-info ${clusterName}_${networkName} > /dev/null 2>&1
  if [[ $? -eq 1 ]]; then
    netXML=${out}/net.xml
    prefix=$(echo ${subnet}|awk -F"/" '{print $1}')
    prefixLength=$(echo ${subnet}|awk -F"/" '{print $2}')
    mask=$(mask2cdr ${prefixLength})
    cat << EOF > ${netXML}
<network>
  <name>${clusterName}_${networkName}</name>
  <forward mode='nat'>
    <nat>
      <port start='1024' end='65535'/>
    </nat>
  </forward>
  <ip address='${gateway}' netmask='255.255.255.0'>
  </ip>
</network>
EOF
    virsh net-define ${netXML}
    virsh net-start ${clusterName}_${networkName}
    virsh net-autostart ${clusterName}_${networkName}
  fi
}

function create(){
  createNetwork
  curl -sL ${md5sum} -o ${out}/$(basename ${md5sum})
  imageMD5=$(grep ${imageName} ${out}/$(basename ${md5sum}) |awk '{print $1}')
  if [[ -f ${libvirtImageLocation}/${imageName} ]]; then
    md5=$(md5sum ${libvirtImageLocation}/${imageName} |awk '{print $1}')
    if [[ ${md5} != ${imageMD5} ]]; then
      curl -L ${imageLocation}/${imageName} -o ${libvirtImageLocation}/${imageName}
    fi
  else
    curl -L ${imageLocation}/${imageName} -o ${libvirtImageLocation}/${imageName}
  fi
  pubKey=$(cat ${pubKey})
  for k in $(jq '.instances | keys | .[]' ${file}); do
    hostname=$(jq -r ".instances[$k].name" ${file});
    ip=$(jq -r ".instances[$k].ip" ${file});
    qemu-img create -b ${imageName} -f qcow2 -F qcow2 ${libvirtImageLocation}/${imageName}-${clusterName}-${hostname}.qcow2 ${disk} > /dev/null 2>&1
    cat << EOF > ${out}/cloud_init-${clusterName}-${hostname}.cfg
#cloud-config
hostname: ${hostname}.${clusterName}.${suffix}
manage_etc_hosts: true
users:
  - name: ubuntu
    sudo: ALL=(ALL) NOPASSWD:ALL
    groups: users, admin
    home: /home/ubuntu
    shell: /bin/bash
    lock_passwd: false
    ssh-authorized-keys:
      - ${pubKey}
  - name: root
    ssh-authorized-keys:
      - ${pubKey}
# only cert auth via ssh (console access can still login)
ssh_pwauth: true
disable_root: false
chpasswd:
  list: |
     ubuntu:linux
     root:linux
  expire: False
write_files:
- content: |
    [Resolve]
    DNS=${dnsserver}
  path: /etc/systemd/resolved.conf
runcmd:
  - [ systemctl, restart, systemd-resolved.service ]
  - cat /etc/systemd/resolved.conf > /run/test
# written to /var/log/cloud-init-output.log
final_message: "The system is finally up, after $UPTIME seconds"
EOF

    cat << EOF > ${out}/network_config_static-${clusterName}-${hostname}.cfg
version: 2
ethernets:
  enp1s0:
     dhcp4: false
     addresses: [ ${ip}/24 ]
     gateway4: ${gateway}
EOF
      cloud-localds -v --network-config=${out}/network_config_static-${clusterName}-${hostname}.cfg ${libvirtImageLocation}/${clusterName}-${hostname}-seed.img ${out}/cloud_init-${clusterName}-${hostname}.cfg > /dev/null 2>&1
      virt-install --name ${clusterName}-${hostname} \
        --virt-type kvm --memory ${memory} --vcpus ${cpu} \
        --boot hd,menu=on \
        --disk path=${libvirtImageLocation}/${clusterName}-${hostname}-seed.img,device=cdrom \
        --disk path=${libvirtImageLocation}/${imageName}-${clusterName}-${hostname}.qcow2,device=disk \
        --graphics vnc \
        --os-type Linux --os-variant ubuntu20.04 \
        --network network=${clusterName}_${networkName},model=virtio \
        --noautoconsole \
        --console pty,target_type=serial
  done
  rm -rf ${out}
}

function snapshot(){
  for k in $(jq '.instances | keys | .[]' ${file}); do
    hostname=$(jq -r ".instances[$k].name" ${file});
    virsh snapshot-create-as ${clusterName}-${hostname} --name snap_${clusterName}-${hostname}
  done
}

function revert(){
  for k in $(jq '.instances | keys | .[]' ${file}); do
    hostname=$(jq -r ".instances[$k].name" ${file});
    shutdown
    virsh snapshot-revert ${clusterName}-${hostname} snap_${clusterName}-${hostname}
  done
}

function start(){
  echo "starting"
  for k in $(jq '.instances | keys | .[]' ${file}); do
    hostname=$(jq -r ".instances[$k].name" ${file});
    echo start vm ${clusterName}-${hostname}
    virsh start ${clusterName}-${hostname}
  done
}

function shutdown(){
  for k in $(jq '.instances | keys | .[]' ${file}); do
    hostname=$(jq -r ".instances[$k].name" ${file});
    virsh shutdown ${clusterName}-${hostname} > /dev/null 2>&1
  done
}

function kill(){
  for k in $(jq '.instances | keys | .[]' ${file}); do
    hostname=$(jq -r ".instances[$k].name" ${file});
    instanceSnapshot=$(virsh snapshot-list ${clusterName}-${hostname} --name)
    if [[ ${instanceSnapshot} != "" ]]; then
      virsh snapshot-delete ${clusterName}-${hostname} ${instanceSnapshot}
    fi
    for instance in $(virsh list --name --state-running); do
      if [[ ${instance} == ${clusterName}-${hostname} ]]; then
        virsh destroy ${clusterName}-${hostname}
	break
      fi
    done
    for instance in $(virsh list --name --state-shutoff); do
      if [[ ${instance} == ${clusterName}-${hostname} ]]; then
        virsh undefine ${clusterName}-${hostname}
	break
      fi
    done
  done
  for virshnet in $(virsh net-list --all --name); do
    if [[ ${virshnet} == ${clusterName}_${networkName} ]]; then
      virsh net-destroy ${clusterName}_${networkName}
    fi
  done
  for virshnet in $(virsh net-list --all --name --inactive); do
    if [[ ${virshnet} == ${clusterName}_${networkName} ]]; then
      virsh net-undefine ${clusterName}_${networkName}
    fi
  done
}

function setVars(){
  suffix=$(jq -r ".suffix" ${file});
  imageLocation=$(jq -r ".imageLocation" ${file});
  md5sum=$(jq -r ".md5sum" ${file});
  imageName=$(jq -r ".imageName" ${file});
  pubKey=$(jq -r ".pubKey" ${file});
  libvirtImageLocation=$(jq -r ".libvirtImageLocation" ${file});
  disk=$(jq -r ".disk" ${file});
  cpu=$(jq -r ".cpu" ${file});
  memory=$(jq -r ".memory" ${file});
  clusterName=$(jq -r ".name" ${file});
  networkName=$(jq -r ".network.name" ${file});
  subnet=$(jq -r ".network.subnet" ${file});
  gateway=$(jq -r ".network.gateway" ${file});
  dnsserver=$(jq -r ".network.dnsserver" ${file});
  networkType=$(jq -r ".network.type" ${file});
  out=$(mktemp -d)
}

case $1 in
    -f|--file) file=$2; setVars ;;
    *) echo "Unknown parameter passed: $1"; exit 1 ;;
esac

while getopts cspbkrtf: flag
do
  case "${flag}" in
    c) create;;
    s) start;;
    p) shutdown;;
    b) snapshot;;
    k) kill;;
    r) revert;;
    t) test;;
  esac
done
