#!/bin/bash

set -ex

namespace="kubevirt"
template_name="windows2k12r2"

dv_name="${TARGET}-datavolume-original"

oc apply -n ${namespace} -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataVolume
metadata:
  name: ${dv_name}
spec:
  source:
    registry:
      secretRef: common-templates-container-disk-puller
      url: "docker://quay.io/openshift-cnv/ci-common-templates-images:${TARGET}"
  pvc:
    accessModes:
      - ReadWriteOnce
    resources:
      requests:
        storage: 60Gi
EOF

oc apply -f - <<EOF
---
apiVersion: v1
kind: Pod
metadata:
  name: winrmcli
  namespace: kubevirt
spec:
  containers:
  - image: quay.io/kubevirt/winrmcli
    command: ["/bin/sh","-c"]
    args: [ "sleep 3000"]
    imagePullPolicy: Always
    name: winrmcli
restartPolicy: Always
---
EOF

timeout=2000
sample=10
current_time=0

oc wait --for=condition=Ready --timeout=${timeout}s dv/${dv_name} -n $namespace

oc apply -n ${namespace} -f - <<EOF
apiVersion: cdi.kubevirt.io/v1beta1
kind: DataSource
metadata:
  name: ${dv_name}
spec:
  source:
    pvc:
      name: ${dv_name}
      namespace: ${namespace}
EOF

# Make sure winrmcli pod is ready
oc wait --for=condition=Ready --timeout=${timeout}s pod/winrmcli -n $namespace

sizes=("medium" "large")
workloads=("server" "highperformance")

if [[ $TARGET =~ windows10.* ]]; then
  template_name="windows10"
  workloads=("desktop")
elif [[ $TARGET =~ windows2016.* ]]; then
  template_name="windows2k16"
elif [[ $TARGET =~ windows2019.* ]]; then
  template_name="windows2k19"
fi

delete_vm(){
  vm_name=$1
  local template_name=$2
  set +e
  #stop vm
  ./virtctl stop $vm_name -n $namespace
  #delete vm
  oc delete vm $vm_name -n $namespace
  set -e
}

run_vm(){
  vm_name=$1
  template_path="dist/templates/$vm_name.yaml"
  local template_name=$( oc get -n ${namespace} -f ${template_path} -o=custom-columns=NAME:.metadata.name --no-headers -n kubevirt )
  running=false

  set +e

  #If first try fails, it tries 2 more time to run it, before it fails whole test
  for i in `seq 1 3`; do
    error=false

    oc process -n $namespace -o json $template_name NAME=$vm_name SRC_PVC_NAME=${dv_name} SRC_PVC_NAMESPACE=${namespace} | \
    jq '.items[0].metadata.labels["vm.kubevirt.io/template.namespace"]="kubevirt"' | \
    oc apply -n $namespace -f -
    
    # start vm
    ./virtctl start $vm_name -n $namespace

    oc wait --for=condition=Ready --timeout=${timeout}s vm/$vm_name -n $namespace

    # get ip address of vm
    ipAddressVMI=$(oc get vmi $vm_name -o json -n $namespace| jq -r '.status.interfaces[0].ipAddress')

    current_time=0
    # run ipconfig /all command on windows vm
    while [[ $(oc exec -n $namespace -i winrmcli -- ./usr/bin/winrm-cli -hostname $ipAddressVMI -port 5985 -username "Administrator" -password "Heslo123" "ipconfig /all" | grep "IPv4 Address" | wc -l ) -eq 0 ]] ; do 
      # VM can be stopped during test and recreated. That will change IP, so to be sure, get IP at every iteration
      ipAddressVMI=$(oc get vmi $vm_name -o json -n $namespace| jq -r '.status.interfaces[0].ipAddress')
      current_time=$((current_time + sample))
      if [[ $current_time -gt $timeout ]]; then
        error=true
        break
      fi
      sleep $sample;
    done

    delete_vm $vm_name $template_name
    #no error were observed, the vm is running
    if ! $error ; then
      running=true
      break
    fi
  done

  set -e

  if ! $running ; then
    exit 1 
  fi
}

for size in ${sizes[@]}; do
  for workload in ${workloads[@]}; do
    vm_name=$template_name-$workload-$size
    run_vm $vm_name
  done
done
