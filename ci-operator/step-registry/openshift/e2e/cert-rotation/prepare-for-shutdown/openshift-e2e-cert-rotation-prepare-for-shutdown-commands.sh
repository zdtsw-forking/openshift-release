#!/bin/bash

set -o nounset
set -o errexit
set -o pipefail
set -x

echo "************ prepare openshift nodes for shutdown command ************"

# Fetch packet basic configuration
# shellcheck source=/dev/null
source "${SHARED_DIR}/packet-conf.sh"

# This file has commonly used functions for cert rotation steps
cat >"${SHARED_DIR}"/cert-rotation-functions.sh <<'EOF'
#!/bin/bash
set -euo pipefail

SSH_OPTS=${SSH_OPTS:- -o 'ConnectionAttempts=100' -o 'ConnectTimeout=5' -o 'StrictHostKeyChecking=no' -o 'UserKnownHostsFile=/dev/null' -o 'ServerAliveInterval=90' -o 'ServerAliveCountMax=100' -o LogLevel=ERROR}
SCP=${SCP:-scp ${SSH_OPTS}}
SSH=${SSH:-ssh ${SSH_OPTS}}
COMMAND_TIMEOUT=15m
LONG_COMMAND_TIMEOUT=30m

# HA cluster's KUBECONFIG points to a directory - it needs to use first found cluster
if [ -d "$KUBECONFIG" ]; then
  export KUBECONFIG=$(find "$KUBECONFIG" -type f | head -n 1)
fi

if [ ! -f /srv/control_node_ips ]; then
mapfile -d ' ' -t control_nodes < <( oc get nodes --selector='node-role.kubernetes.io/master' --template='{{ range $index, $_ := .items }}{{ range .status.addresses }}{{ if (eq .type "InternalIP") }}{{ if $index }} {{end }}{{ .address }}{{ end }}{{ end }}{{ end }}' )

mapfile -d ' ' -t compute_nodes < <( oc get nodes --selector='!node-role.kubernetes.io/master' --template='{{ range $index, $_ := .items }}{{ range .status.addresses }}{{ if (eq .type "InternalIP") }}{{ if $index }} {{end }}{{ .address }}{{ end }}{{ end }}{{ end }}' )

ssh-keyscan -H ${control_nodes[@]} ${compute_nodes[@]} >> ~/.ssh/known_hosts

# Save found node IPs for "gather-cert-rotation" step
echo -n "${control_nodes[@]}" > /srv/control_node_ips
echo -n "${compute_nodes[@]}" > /srv/compute_node_ips

echo "Wrote control_node_ips: $(cat /srv/control_node_ips), compute_node_ips: $(cat /srv/compute_node_ips)"
else
  mapfile -d ' ' -t control_nodes < /srv/control_node_ips
  mapfile -d ' ' -t compute_nodes < /srv/compute_node_ips
fi

function run-on-all-nodes {
  for n in ${control_nodes[@]} ${compute_nodes[@]}; do timeout ${COMMAND_TIMEOUT} ${SSH} core@"${n}" sudo 'bash -eEuxo pipefail' <<< ${1}; done
}

function run-on-first-master {
  timeout ${COMMAND_TIMEOUT} ${SSH} "core@${control_nodes[0]}" sudo 'bash -eEuo pipefail' <<< ${1}
}

function run-on-first-master-long {
  timeout ${LONG_COMMAND_TIMEOUT} ${SSH} "core@${control_nodes[0]}" sudo bash -eEuo pipefail ${1}
}

function run-on-first-master-silent {
  timeout ${COMMAND_TIMEOUT} ${SSH} "core@${control_nodes[0]}" sudo 'bash -eEuo pipefail' <<< ${1}
}

function run-on-first-master-silent-long {
  timeout ${LONG_COMMAND_TIMEOUT} ${SSH} "core@${control_nodes[0]}" sudo 'bash -eEuo pipefail' <<< ${1}
}

function copy-file-from-first-master {
  timeout ${COMMAND_TIMEOUT} ${SCP} "core@${control_nodes[0]}:${1}" "${2}"
}

if [ ! -f /tmp/ensure-nodes-are-ready.sh ]; then
  cat << 'EOZ' > /tmp/ensure-nodes-are-ready.sh
  set +e
  # Read cluster shutdown time from /var/cluster-shutdown-time
  if [[ -f /var/cluster-shutdown-time ]]; then
    start_timestamp="$(cat /var/cluster-shutdown-time)"
    echo "Cluster shutdown time is set to ${start_timestamp}"
  else
    # Fallback on current time if /var/cluster-shutdown-time is not set
    start_timestamp=$(date -u +'%Y-%m-%dT%H:%M:%SZ')
    echo "Unable to find cluster shutdown time, falling back to ${start_timestamp}"
  fi

  export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig
  until oc --request-timeout=5s get nodes; do sleep 10; done | /usr/local/bin/tqdm --desc "Waiting for API server to come up" --null
  mapfile -t nodes < <( oc --request-timeout=5s get nodes -o name )

  echo "Approving CSRs at $(date +%X)"
  fields=( kubernetes.io/kube-apiserver-client-kubelet kubernetes.io/kubelet-serving )
  for field in ${fields[@]}; do
    (( required_csrs=${#nodes[@]} ))
    approved_csrs=0
    attempt=0
    until (( approved_csrs >= required_csrs )); do
      ((attempt++))
      echo -n ""
      echo -n ""
      echo "$(date +%X) attempt #${attempt} approved CSRs: ${approved_csrs} of ${required_csrs}"

      mapfile -t all_csrs < <(oc --request-timeout=5s get csr --field-selector=spec.signerName=${field} --no-headers)
      pending_csrs=()
      approved_csrs=0

      for csr_line in "${all_csrs[@]}"; do
        csr_name=$(echo "$csr_line" | awk '{print $1}')
        csr_condition=$(echo "$csr_line" | awk '{print $NF}')
        if [[ "$csr_condition" == "Pending" ]]; then
          pending_csrs+=("$csr_name")
        else
          # Don't count CSRs created before the start of the script
          if [[ $(date -d "$(oc --request-timeout=5s get csr ${csr_name} -o jsonpath='{.metadata.creationTimestamp}')" +%s) -ge $(date -d "${start_timestamp}" +%s) ]]; then
            (( approved_csrs=approved_csrs+1 ))
          fi
        fi
      done
      echo "found ${#pending_csrs[@]} pending CSRs, ${approved_csrs} fresh approved CSRs, total ${#all_csrs[@]} CSRs"
      if [[ ${#pending_csrs[@]} -gt 0 ]]; then
        for csr_name in ${pending_csrs[@]}; do
          oc --request-timeout=5s get csr ${csr_name} -o yaml
          oc --request-timeout=5s adm certificate approve ${csr_name}
        done
      fi
      sleep 30
      echo "" >&3
    done 3> >(/usr/local/bin/tqdm --desc "Approving ${field} CSRs" --null)
  done
  echo "All CSRs approved at $(date)"

  for nodename in ${nodes[@]}; do
    STATUS="False"
    TIME_DIFF="301"
    until [[ ${TIME_DIFF} -le 300 ]] && [[ ${STATUS} == True ]]; do
      STATUS=$(oc --request-timeout=5s get ${nodename} -o jsonpath='{.status.conditions[?(@.type=="Ready")].status}')
      NODE_HEARTBEAT_TIME=$(oc --request-timeout=5s get ${nodename} -o jsonpath='{.status.conditions[?(@.type=="Ready")].lastHeartbeatTime}')
      if [[ -z ${NODE_HEARTBEAT_TIME} ]]; then
        continue
      fi
      TIME_DIFF=$(($(date +%s)-$(date -d ${NODE_HEARTBEAT_TIME} +%s)))
      sleep 10
      done | /usr/local/bin/tqdm --desc "Waiting for ${nodename} to send heartbeats" --null
  done
  echo "All nodes are ready at $(date)"
EOZ
  chmod a+x /tmp/ensure-nodes-are-ready.sh
  timeout ${COMMAND_TIMEOUT} ${SCP} /tmp/ensure-nodes-are-ready.sh "core@${control_nodes[0]}:/tmp/ensure-nodes-are-ready.sh"
  run-on-first-master "mv /tmp/ensure-nodes-are-ready.sh /usr/local/bin/ensure-nodes-are-ready.sh && chmod a+x /usr/local/bin/ensure-nodes-are-ready.sh"
fi

function wait-for-nodes-to-be-ready {
  run-on-first-master-long "/usr/local/bin/ensure-nodes-are-ready.sh"
  run-on-first-master "cp -rvf /etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/lb-ext.kubeconfig /tmp/lb-ext.kubeconfig && chown nobody:nobody /tmp/lb-ext.kubeconfig && chmod 644 /tmp/lb-ext.kubeconfig"
  copy-file-from-first-master /tmp/lb-ext.kubeconfig /tmp/lb-ext.kubeconfig
}

if [ ! -f /tmp/wait-for-valid-lb-ext-kubeconfig.sh ]; then
  cat << 'EOZ' > /tmp/wait-for-valid-lb-ext-kubeconfig.sh
    set +e
  echo "Waiting for lb-ext kubeconfig to be valid"
  export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/lb-ext.kubeconfig
  until oc --request-timeout=5s get nodes; do sleep 10; done
EOZ
  chmod a+x /tmp/wait-for-valid-lb-ext-kubeconfig.sh
  timeout ${COMMAND_TIMEOUT} ${SCP} /tmp/wait-for-valid-lb-ext-kubeconfig.sh "core@${control_nodes[0]}:/tmp/wait-for-valid-lb-ext-kubeconfig.sh"
  run-on-first-master "mv /tmp/wait-for-valid-lb-ext-kubeconfig.sh /usr/local/bin/wait-for-valid-lb-ext-kubeconfig.sh && chmod a+x /usr/local/bin/wait-for-valid-lb-ext-kubeconfig.sh"
fi

function wait-for-valid-lb-ext-kubeconfig {
  run-on-first-master-silent "bash /usr/local/bin/wait-for-valid-lb-ext-kubeconfig.sh"
}

if [ ! -f /tmp/wait-for-kubeapiserver-to-start-progressing.sh ]; then
  cat << 'EOZ' > /tmp/wait-for-kubeapiserver-to-start-progressing.sh
  echo "Waiting for kube-apiserver to start progressing to avoid stale operator statuses"
  export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/lb-ext.kubeconfig
  # TODO: kube-apiserver never starts progressing in 4.19+
  # oc --request-timeout=5s wait --for=condition=Progressing=True clusteroperator/kube-apiserver --timeout=300s
  sleep 300
EOZ
  chmod a+x /tmp/wait-for-kubeapiserver-to-start-progressing.sh
  timeout ${COMMAND_TIMEOUT} ${SCP} /tmp/wait-for-kubeapiserver-to-start-progressing.sh "core@${control_nodes[0]}:/tmp/wait-for-kubeapiserver-to-start-progressing.sh"
  run-on-first-master "mv /tmp/wait-for-kubeapiserver-to-start-progressing.sh /usr/local/bin/wait-for-kubeapiserver-to-start-progressing.sh && chmod a+x /usr/local/bin/wait-for-kubeapiserver-to-start-progressing.sh"
fi

function wait-for-kubeapiserver-to-start-progressing {
  run-on-first-master "bash /usr/local/bin/wait-for-kubeapiserver-to-start-progressing.sh"
}

if [ ! -f /tmp/pod-restart-workarounds.sh ]; then
  cat << 'EOZ' > /tmp/pod-restart-workarounds.sh
  set +e
  export KUBECONFIG=/etc/kubernetes/static-pod-resources/kube-apiserver-certs/secrets/node-kubeconfigs/localhost-recovery.kubeconfig
  until oc --request-timeout=5s get nodes; do sleep 10; done | /usr/local/bin/tqdm --desc "Waiting for API server to come up" --null
  ocp_minor_version=$(oc --request-timeout=5s version -o json | jq -r '.openshiftVersion' | cut -d '.' -f2)

  # Workaround for https://issues.redhat.com/browse/OCPBUGS-42001
  # Restart OVN / Multus before proceeding
  oc --request-timeout=5s -n openshift-multus delete pod -l app=multus --force --grace-period=0
  oc --request-timeout=5s -n openshift-ovn-kubernetes delete pod -l app=ovnkube-node --force --grace-period=0
  oc --request-timeout=5s -n openshift-ovn-kubernetes delete pod -l app=ovnkube-control-plane --force --grace-period=0
EOZ
  chmod a+x /tmp/pod-restart-workarounds.sh
  timeout ${COMMAND_TIMEOUT} ${SCP} /tmp/pod-restart-workarounds.sh "core@${control_nodes[0]}:/tmp/pod-restart-workarounds.sh"
  run-on-first-master "mv /tmp/pod-restart-workarounds.sh /usr/local/bin/pod-restart-workarounds.sh && chmod a+x /usr/local/bin/pod-restart-workarounds.sh"
fi

function pod-restart-workarounds {
  run-on-first-master-silent "bash /usr/local/bin/pod-restart-workarounds.sh"
}

function prepull-tools-image-for-gather-step {
  # Prepull tools image on the nodes. "gather-cert-rotation" step uses it to run sos report
  # However, if time is too far in the future the pull will fail with "Trying to pull registry.redhat.io/rhel8/support-tools:latest...
  # Error: initializing source ...: tls: failed to verify certificate: x509: certificate has expired or is not yet valid: current time ... is after <now + 6m>"
  run-on-all-nodes "podman pull --authfile /var/lib/kubelet/config.json registry.redhat.io/rhel8/support-tools:latest"
}

function wait-for-operators-to-stabilize {
  export KUBECONFIG=/tmp/lb-ext.kubeconfig
  oc --request-timeout=5s get nodes
  # Wait for operators to stabilize
  if
    ! oc --request-timeout=5s adm wait-for-stable-cluster --minimum-stable-period=5m --timeout=30m; then
      oc --request-timeout=5s get nodes
      oc --request-timeout=5s get co | grep -v "True\s\+False\s\+False"
      exit 1
  fi
}

EOF
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/cert-rotation-functions.sh "root@${IP}:/usr/local/share"

cat >"${SHARED_DIR}"/set-client-ssh-settings.sh <<'EOF'
#!/bin/bash
set -euo pipefail

source /usr/local/share/cert-rotation-functions.sh

# Install tqdm
python -m ensurepip && python -m pip install tqdm
run-on-all-nodes "python -m ensurepip && python -m pip install tqdm"

# Stop chrony service on all nodes
sudo systemctl stop chronyd
run-on-all-nodes "systemctl disable chronyd --now"

# Set ClientAliveInterval
set +e
run-on-all-nodes "sed -i -e 's/.*ClientAliveInterval.*/ClientAliveInterval 120/g' /etc/ssh/sshd_config && sed -i -e 's/.*ClientAliveCountMax.*/ClientAliveCountMax 100/g' /etc/ssh/sshd_config"
run-on-all-nodes "systemctl restart sshd"
for n in ${control_nodes[@]} ${compute_nodes[@]}; do
  until timeout ${COMMAND_TIMEOUT} ${SSH} core@"${n}" true >/dev/null 2>&1; do
    echo "."
  done
done
sed -i -e 's/.*ClientAliveInterval.*/ClientAliveInterval 120/g' /etc/ssh/sshd_config && sed -i -e 's/.*ClientAliveCountMax.*/ClientAliveCountMax 100/g' /etc/ssh/sshd_config
systemctl restart sshd
EOF

chmod +x "${SHARED_DIR}"/set-client-ssh-settings.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/set-client-ssh-settings.sh "root@${IP}:/usr/local/bin"

timeout \
	--kill-after 10m \
	30m \
	ssh \
	"${SSHOPTS[@]}" \
  -o 'ServerAliveInterval=90' -o 'ServerAliveCountMax=100' \
	"root@${IP}" \
	/usr/local/bin/set-client-ssh-settings.sh

timeout \
	--kill-after 10m \
	30m \
	ssh \
	"${SSHOPTS[@]}" \
  -o 'ServerAliveInterval=90' -o 'ServerAliveCountMax=100' \
	"root@${IP}" \
  "systemctl restart sshd"

# This file is scp'd to the machine where the nested libvirt cluster is running
# It rotates node kubeconfigs so that it could be shut down earlier than 24 hours
cat >"${SHARED_DIR}"/prepare-nodes-for-shutdown.sh <<'EOF'
#!/bin/bash

set -euxo pipefail

# HA cluster's KUBECONFIG points to a directory - it needs to use first found cluster
if [ -d "$KUBECONFIG" ]; then
  export KUBECONFIG=$(find "$KUBECONFIG" -type f | head -n 1)
fi

oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=30m

# Use emptyDir for image-registry
oc patch configs.imageregistry.operator.openshift.io cluster --type merge --patch '{"spec":{"managementState":"Managed","storage":{"emptyDir":{}}}}'

# Disable all marketplace sources to avoid "Back-off pulling image"
oc patch OperatorHub cluster --type json \
    -p '[{"op": "add", "path": "/spec/disableAllDefaultSources", "value": true}]'

# Generate custom ingress certificate valid for 10 years
tenYears=3650
baseDomain=$(oc get dns.config cluster -o=jsonpath='{.spec.baseDomain}')
temp_dir=$(mktemp -d)
openssl req -newkey rsa:4096 -nodes -sha256 -keyout "${temp_dir}/ca.key" -x509 -days ${tenYears} -subj "/CN=$baseDomain" -out "${temp_dir}/ca.crt"

openssl genrsa -out "${temp_dir}/ca.key" 4096
openssl req -x509 -sha256 -key "${temp_dir}/ca.key" -nodes -new -days ${tenYears} -out "${temp_dir}/ca.crt" -subj "/CN=${baseDomain}" -set_serial 1
cat ${temp_dir}/ca.crt >> /home/assisted/custom_manifests/ca.pem

oc create configmap custom-ca \
     --from-file=ca-bundle.crt="/home/assisted/custom_manifests/ca.pem" \
     -n openshift-config

oc patch proxy/cluster \
     --type=merge \
     --patch='{"spec":{"trustedCA":{"name":"custom-ca"}}}'

defaultIngressDomain=$(oc get ingresscontroller default -o=jsonpath='{.status.domain}' -n openshift-ingress-operator)
cat <<EOZ > "${temp_dir}/tmp.conf"
[cus]
subjectAltName = DNS:*.${defaultIngressDomain}
EOZ
openssl genrsa -out "${temp_dir}/server.key" 4096
openssl req -new -key "${temp_dir}/server.key" -subj "/CN=${defaultIngressDomain}" -addext "subjectAltName = DNS:*.${defaultIngressDomain}" -out "${temp_dir}/server.csr"
openssl x509 -req -days ${tenYears} -CA "${temp_dir}/ca.crt" -CAkey "${temp_dir}/ca.key" -CAserial caproxy.srl -CAcreateserial -extfile "${temp_dir}/tmp.conf" -extensions cus -in "${temp_dir}/server.csr" -out "${temp_dir}/server.crt"

oc create secret tls custom-cert \
     --cert="${temp_dir}/server.crt" \
     --key="${temp_dir}/server.key" \
     -n openshift-ingress

oc patch ingresscontroller.operator default \
     --type=merge -p \
     '{"spec":{"defaultCertificate": {"name": "custom-cert"}}}' \
     -n openshift-ingress-operator
oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=30m

source /usr/local/share/cert-rotation-functions.sh
prepull-tools-image-for-gather-step

# Sync host and node timezones to avoid possible errors when skewing time
HOST_TZ=$(date +"%Z %z" | cut -d' ' -f1)
run-on-all-nodes "timedatectl set-timezone ${HOST_TZ}"

oc adm wait-for-stable-cluster --minimum-stable-period=2m --timeout=30m

oc -n openshift-machine-config-operator create serviceaccount kubelet-bootstrap-cred-manager
oc -n openshift-machine-config-operator adm policy add-cluster-role-to-user cluster-admin -z kubelet-bootstrap-cred-manager
cat << 'EOZ' > /tmp/kubelet-bootstrap-cred-manager-ds.yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: kubelet-bootstrap-cred-manager
  namespace: openshift-machine-config-operator
  labels:
    k8s-app: kubelet-bootstrap-cred-manager
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: kubelet-bootstrap-cred-manager
  template:
    metadata:
      labels:
        k8s-app: kubelet-bootstrap-cred-manager
    spec:
      containers:
      - name: kubelet-bootstrap-cred-manager
        image: quay.io/openshift/origin-cli:4.12
        command: ['/bin/bash', '-ec']
        args:
          - |
            #!/bin/bash

            set -eoux pipefail

            while true; do
              unset KUBECONFIG

              echo "---------------------------------"
              echo "Gather info..."
              echo "---------------------------------"
              # context
              intapi=$(oc get infrastructures.config.openshift.io cluster -o "jsonpath={.status.apiServerInternalURI}")
              context="$(oc --kubeconfig=/etc/kubernetes/kubeconfig config current-context)"
              # cluster
              cluster="$(oc --kubeconfig=/etc/kubernetes/kubeconfig config view -o "jsonpath={.contexts[?(@.name==\"$context\")].context.cluster}")"
              server="$(oc --kubeconfig=/etc/kubernetes/kubeconfig config view -o "jsonpath={.clusters[?(@.name==\"$cluster\")].cluster.server}")"
              # token
              ca_crt_data="$(oc get secret -n openshift-machine-config-operator node-bootstrapper-token -o "jsonpath={.data.ca\.crt}" | base64 --decode)"
              namespace="$(oc get secret -n openshift-machine-config-operator node-bootstrapper-token  -o "jsonpath={.data.namespace}" | base64 --decode)"
              token="$(oc get secret -n openshift-machine-config-operator node-bootstrapper-token -o "jsonpath={.data.token}" | base64 --decode)"

              echo "---------------------------------"
              echo "Generate kubeconfig"
              echo "---------------------------------"

              export KUBECONFIG="$(mktemp)"
              kubectl config set-credentials "kubelet" --token="$token" >/dev/null
              ca_crt="$(mktemp)"; echo "$ca_crt_data" > $ca_crt
              kubectl config set-cluster $cluster --server="$intapi" --certificate-authority="$ca_crt" --embed-certs >/dev/null
              kubectl config set-context kubelet --cluster="$cluster" --user="kubelet" >/dev/null
              kubectl config use-context kubelet >/dev/null

              echo "---------------------------------"
              echo "Print kubeconfig"
              echo "---------------------------------"
              cat "$KUBECONFIG"

              echo "---------------------------------"
              echo "Whoami?"
              echo "---------------------------------"
              oc whoami
              whoami

              echo "---------------------------------"
              echo "Moving to real kubeconfig"
              echo "---------------------------------"
              cp /etc/kubernetes/kubeconfig /etc/kubernetes/kubeconfig.prev
              chown root:root ${KUBECONFIG}
              chmod 0644 ${KUBECONFIG}
              mv "${KUBECONFIG}" /etc/kubernetes/kubeconfig

              echo "---------------------------------"
              echo "Sleep 60 seconds..."
              echo "---------------------------------"
              sleep 60
            done
        securityContext:
          privileged: true
          runAsUser: 0
        volumeMounts:
          - mountPath: /etc/kubernetes/
            name: kubelet-dir
      nodeSelector:
        node-role.kubernetes.io/master: ""
      priorityClassName: "system-cluster-critical"
      restartPolicy: Always
      securityContext:
        runAsUser: 0
      serviceAccountName: kubelet-bootstrap-cred-manager
      tolerations:
      - key: "node-role.kubernetes.io/master"
        operator: "Exists"
        effect: "NoSchedule"
      - key: "node.kubernetes.io/unreachable"
        operator: "Exists"
        effect: "NoExecute"
        tolerationSeconds: 120
      - key: "node.kubernetes.io/not-ready"
        operator: "Exists"
        effect: "NoExecute"
        tolerationSeconds: 120
      volumes:
        - hostPath:
            path: /etc/kubernetes/
            type: Directory
          name: kubelet-dir
EOZ
oc create -f /tmp/kubelet-bootstrap-cred-manager-ds.yaml

NODE_COUNT=$(oc get nodes --selector='node-role.kubernetes.io/master' --no-headers 2>/dev/null | wc -l)
oc -n openshift-machine-config-operator wait --for jsonpath='{.status.currentNumberScheduled}'=${NODE_COUNT} ds/kubelet-bootstrap-cred-manager
oc -n openshift-machine-config-operator wait pods -l k8s-app=kubelet-bootstrap-cred-manager --for condition=Ready --timeout=300s
oc -n openshift-kube-controller-manager-operator delete secrets/csr-signer-signer secrets/csr-signer
oc adm wait-for-stable-cluster --minimum-stable-period=1m --timeout=30m
oc -n openshift-machine-config-operator delete ds kubelet-bootstrap-cred-manager

EOF
chmod +x "${SHARED_DIR}"/prepare-nodes-for-shutdown.sh
scp "${SSHOPTS[@]}" "${SHARED_DIR}"/prepare-nodes-for-shutdown.sh "root@${IP}:/usr/local/bin"

timeout \
	--kill-after 10m \
	120m \
	ssh \
	"${SSHOPTS[@]}" \
	-o 'ServerAliveInterval=90' -o 'ServerAliveCountMax=100' \
	"root@${IP}" \
	/usr/local/bin/prepare-nodes-for-shutdown.sh
