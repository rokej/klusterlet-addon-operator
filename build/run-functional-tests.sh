#!/bin/bash
###############################################################################
# Copyright (c) 2020 Red Hat, Inc.
###############################################################################
# set -x #To trace

export DOCKER_IMAGE=$1
KIND_CONFIGS=build/kind-config
KIND_KUBECONFIG="${PROJECT_DIR}/kind_kubeconfig.yaml"
export KUBECONFIG=${KIND_KUBECONFIG}
export PULL_SECRET=multicloud-image-pull-secret

if [ -z $DOCKER_USER ]; then
   echo "DOCKER_USER is not defined!"
   exit 1
fi
if [ -z $DOCKER_PASS ]; then
   echo "DOCKER_PASS is not defined!"
   exit 1
fi

set_linux_arch () {
    local _arch=$(uname -m)
    if [ "$_arch" == "x86_64" ]; then
        _linux_arch="amd64"
    elif [ "$_arch" == "ppc64le" ]; then
        _linux_arch="ppc64le"
    else
        echo "Unrecognized architecture $_arch"
        return 1
    fi
}

install_kubectl () {
    if $(type kubectl >/dev/null 2>&1); then
        echo "kubectl already installed"
        return 0
    fi
    # alway install when running from Travis
    if [ "$(uname)" != "Darwin" ]; then
        set_linux_arch
        sudo curl -s -L https://storage.googleapis.com/kubernetes-release/release/v1.18.0/bin/linux/$_linux_arch/kubectl -o /usr/local/bin/kubectl
        sudo chmod +x /usr/local/bin/kubectl
        kubectl version --client=true
        if [ $? != 0 ]; then
          echo "kubectl installation failed"
          return 1
        fi
    fi
}

install_kind () {
    if $(type kind >/dev/null 2>&1); then
        echo "kind installed"
        return 0
    fi
    curl -Lo ./kind https://github.com/kubernetes-sigs/kind/releases/download/v0.7.0/kind-$(uname)-amd64
    chmod +x ./kind
    sudo mv ./kind /usr/local/bin/kind
    kind version
    if [ $? != 0 ]; then
        echo "kind installation failed"
        return 1
    fi
}

# Wait until the cluster is imported by checking the hub side
# Parameter: KinD Config File
wait_installed() {
    CONFIG_FILE=$1

    _timeout_seconds=120
    _interval_seconds=10
    _max_nb_loop=$(($_timeout_seconds/$_interval_seconds))
    while [ $_max_nb_loop -gt 0 ]
    do
        _result=$(for file in `ls deploy/crs/agent.open-cluster-management.io_*_cr.yaml`; do kubectl get -f $file -o=jsonpath="{.metadata.name}{' '}{.status.conditions[?(@.reason=='InstallSuccessful')].reason}{'\n'}"; done)
        _result_exit_code=$?
        _result_not_success=$(echo "$_result" | grep -v "InstallSuccessful")
        if [ $? == 0 ] || [ $_result_exit_code != 0 ] ; then
            echo "=========== Waiting for success ==========="
            echo "$_result"
            sleep $_interval_seconds
            _max_nb_loop=$(($_max_nb_loop-1))
        else
            echo "=========== Success ==========="
            echo "$_result"
            return 0
        fi
    done
    echo "====================== ERROR with config $CONFIG_FILE ==================="
    echo "Timeout: Herlm charts deployment failed after "$_timeout_seconds" seconds"
    for cr in $_result_not_success; do kubectl get $cr $cr -n klusterlet -o=jsonpath="{.metadata.name}{','}{.status.conditions[*].message}{'\n'}"; done
    return 1
}

check_ocp_install(){
    echo "checking route installation: kubectl get route -n klusterlet"
    kubectl get route -l component=work-manager -n klusterlet
    _not_installed_route=1
    if [ $(kubectl get route -l component=work-manager -n klusterlet | wc -l)  -gt 1 ]; then
      echo "route installed correctly"
      _not_installed_route=0
    fi
    _not_installed_scc=1
    echo "checking scc installation"
    kubectl get securitycontextconstraints -n klusterlet
    if [ $(kubectl get securitycontextconstraints -n klusterlet | wc -l) -gt 2 ]; then
      echo "scc installed correctly"
      _not_installed_scc=0
    fi
    if [ $_not_installed_route != 0 ] || [ $_not_installed_scc != 0 ]; then
      return 1
    fi
    return 0
}

#Create a cluster with as parameter the KinD config file and run the test
run_test() {
  CONFIG_FILE=$1
  echo "====================== START with config $CONFIG_FILE ==================="
  #Delete cluster
	kind delete cluster --name=test-cluster

  # Create cluster
  kind create cluster --name=test-cluster --config $CONFIG_FILE

  #export context to kubeconfig
  # export KUBECONFIG=$(mktemp /tmp/kubeconfigXXXX)
  kind export kubeconfig --name=test-cluster --kubeconfig ${KIND_KUBECONFIG}

  #Load image into cluster
  kind load docker-image $DOCKER_IMAGE --name=test-cluster

  #Apply all crds
  for file in `ls deploy/crds/agent.open-cluster-management.io_*_crd.yaml`; do kubectl apply -f $file; done

  #Try to apply the securitycontextconstraints
  ocp_env=0
  kubectl apply -f deploy/crds/security.openshift.io_securitycontextconstraints_crd.yaml
  if [ $? == 0 ]; then
    ocp_env=1
    echo "This is an OCP-like environment"
    kubectl apply -f deploy/crds/fake_route.openshift.io_route_crd.yaml
  else
    echo "This is not an OCP-like environment"
  fi

  #Create the namespace
  kubectl apply -f ${PROJECT_DIR}/deploy/namespace.yaml

  #Install all CRs
  for file in `ls deploy/crs/agent.open-cluster-management.io_*_cr.yaml`; do kubectl apply -f $file; done

  #Configure kubectl
  tmpKUBECONFIG=$(mktemp /tmp/kubeconfigXXXX)
  kind export kubeconfig --kubeconfig $tmpKUBECONFIG --name=test-cluster

  #Create a generic klusterlet-bootstrap
  kubectl create secret generic klusterlet-bootstrap -n klusterlet --from-file=kubeconfig=$tmpKUBECONFIG

  #Create the docker secret for quay.io
  kubectl create secret docker-registry $PULL_SECRET \
      --docker-server=quay.io/open-cluster-management \
      --docker-username=$DOCKER_USER \
      --docker-password=$DOCKER_PASS \
      -n klusterlet
  
  for dir in overlays/test/* ; do
    echo "Executing test "$dir
    kubectl apply -k $dir
    kubectl patch deployment klusterlet-component-operator -n klusterlet -p "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"klusterlet-component-operator\",\"image\":\"${DOCKER_IMAGE}\"}]}}}}"
    #Wait if all helm-charts are installed
    wait_installed $CONFIG_FILE
    _timeout=$?
    if [ $_timeout != 0 ]; then
      break
    fi
    _installed_failed=0
    #Check detailed installed resources
    if [ $ocp_env != 0 ]; then
      check_ocp_install
      _installed_failed=$?
      if [ $_installed_failed != 0 ]; then
        break
      fi
    fi
  done

  #Delete cluster
	kind delete cluster --name=test-cluster
  echo "====================== END of config $CONFIG_FILE ======================"
  if [ $_timeout != 0 ]; then
    return 1
  fi
  if [ $_installed_failed != 0 ]; then
    return 1
  fi
}


install_kubectl
if [ $? != 0 ]; then
  exit 1
fi

install_kind
if [ $? != 0 ]; then
  exit 1
fi

FAILED=0
for kube_config in `ls $KIND_CONFIGS/*`; do
  run_test $kube_config
  if [ $? != 0 ]; then
    FAILED=1
  fi
done

if [ $FAILED == 1 ]; then
  echo "At least, one of the KinD configuration failed"
fi

exit $FAILED