# createvm
## Prerequisites
- kvm
- qemu
- virsh
- qemu-img
- cloud-localds    
Must run as root for now    
## Usage
### Create
1. edit cluster.json
2. ```./createvm.sh -f cluster.json```
### Snapshot
1. ```./createvm.sh -f cluster.json -b```
### Revert a Snapshot
1. ```./createvm.sh -f cluster.json -r```
### Remove
1. ```./createvm.sh -f cluster.json -k```

