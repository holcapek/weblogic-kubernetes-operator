#!/bin/bash
# Copyright (c) 2018,2019,2020 Oracle Corporation and/or its affiliates.  All rights reserved.
# Licensed under the Universal Permissive License v 1.0 as shown at https://oss.oracle.com/licenses/upl.

#  This script is to create or delete Ingress controllers. We support two ingress controllers: traefik and voyager.

MYDIR="$(dirname "$(readlink -f "$0")")"
VNAME=voyager-operator  # release name of Voyager
TNAME=traefik-operator  # release name of Traefik
VSPACE=voyager # NameSpace for Voyager
TSPACE=traefik   # NameSpace for Traefik

helm version --short | grep v3
[[ $? == 0 ]] && HELM_VERSION=V3
[[ $? == 1 ]] && HELM_VERSION=V2

echo "Detected Helm Version [$HELM_VERSION]"

if [ "$HELM_VERSION" == "V3" ]; then
   v_list_args="--namespace $VSPACE "
   t_list_args="--namespace $TSPACE "
   v_uninstall_args="--namespace $VSPACE "
   t_uninstall_args="--namespace $TSPACE "
   v_helm_install="helm install $VNAME appscode/voyager  "
   t_helm_install="helm install $TNAME stable/traefik "
else
   v_list_args=""
   t_list_args=""
   v_uninstall_args=""
   t_uninstall_args=""
   v_helm_install="helm install appscode/voyager --name $VNAME  "
   t_helm_install="helm install stable/traefik --name $TNAME "
fi

function createVoyager() {
  echo "Creating Voyager operator on namespace 'voyager'."
  echo

  if [ "$(helm search appscode/voyager | grep voyager |  wc -l)" = 0 ]; then
    echo "Add Appscode Chart Repository"
    helm repo add appscode https://charts.appscode.com/stable/
    helm repo update
  else
    echo "Appscode Chart Repository is already added."
  fi
  echo

  if [ "$(helm list ${v_list_args} | grep $VNAME |  wc -l)" = 0 ]; then
    echo "Install voyager operator."
    
    ${v_helm_install} --version 7.4.0 \
      --namespace ${VSPACE} \
      --set cloudProvider=baremetal \
      --set apiserver.enableValidatingWebhook=false \
      --set ingressClass=voyager
  else
    echo "Voyager operator is already installed."
  fi 
  echo

  echo "Wait until Voyager operator running."
  max=20
  count=0
  while [ $count -lt $max ]; do
    kubectl -n ${VSPACE} get pod
    if [ "$(kubectl -n voyager get pod | grep voyager | awk '{ print $2 }')" = 1/1 ]; then
      echo "Voyager operator is running now."
      exit 0;
    fi
    count=`expr $count + 1`
    sleep 5
  done
  echo "Error: Voyager operator failed to start."
  exit 1

}

function createTraefik() {
  echo "Creating Traefik operator on namespace 'traefik'." 
  echo

  if [ "$(helm list ${t_list_args} | grep $TNAME |  wc -l)" = 0 ]; then
    echo "Install Traefik Operator."
    ${t_helm_install} --namespace ${TSPACE} --values ${MYDIR}/../traefik/values.yaml
  else
    echo "Traefik Operator is already installed."
  fi
  echo

  echo "Wait until Traefik operator running."
  max=20
  count=0
  while test $count -lt $max; do
    kubectl -n traefik get pod
    if test "$(kubectl -n ${TSPACE} get pod | grep traefik | awk '{ print $2 }')" = 1/1; then
      echo "Traefik operator is running now."
      exit 0;
    fi
    count=`expr $count + 1`
    sleep 5
  done
  echo "Error: Traefik operator failed to start."
  exit 1
}


function purgeCRDs() {
  # get rid of Voyager crd deletion deadlock:  https://github.com/kubernetes/kubernetes/issues/60538
  crds=(certificates ingresses)
  for crd in "${crds[@]}"; do
    pairs=($(kubectl get ${crd}.voyager.appscode.com --all-namespaces -o jsonpath='{range .items[*]}{.metadata.name} {.metadata.namespace} {end}' || true))
    total=${#pairs[*]}

    # save objects
    if [ $total -gt 0 ]; then
      echo "dumping ${crd} objects into ${crd}.yaml"
      kubectl get ${crd}.voyager.appscode.com --all-namespaces -o yaml >${crd}.yaml
    fi

    for ((i = 0; i < $total; i += 2)); do
      name=${pairs[$i]}
      namespace=${pairs[$i + 1]}
      # remove finalizers
      kubectl patch ${crd}.voyager.appscode.com $name -n $namespace -p '{"metadata":{"finalizers":[]}}' --type=merge
      # delete crd object
      echo "deleting ${crd} $namespace/$name"
      kubectl delete ${crd}.voyager.appscode.com $name -n $namespace
    done

    # delete crd
    kubectl delete crd ${crd}.voyager.appscode.com || true
  done
  # delete user roles
  kubectl delete clusterroles appscode:voyager:edit appscode:voyager:view
}

function deleteVoyager() {
  if [ "$(helm list ${v_list_args} | grep $VNAME |  wc -l)" = 1 ]; then
    echo "Uninstall Voyager Operator. "
    helm uninstall $VNAME ${v_uninstall_args}
    kubectl delete ns ${VSPACE}
    purgeCRDs
  else
    echo "Voyager operator has already been unistalled" 
  fi
  echo

  if [ "$(helm search appscode/voyager | grep voyager |  wc -l)" != 0 ]; then
    echo "Remove Appscode Chart Repository."
    helm repo remove appscode
  fi
  echo

}

function deleteTraefik() {
  if [ "$(helm list ${t_list_args}| grep $TNAME |  wc -l)" = 1 ]; then
    echo "Uninstall Traefik operator." 
    helm uninstall $TNAME ${t_uninstall_args}
    kubectl delete ns ${TSPACE}
  else
    echo "Traefik operator has already been unistalled" 
  fi
}

function usage() {
  echo "usage: $0 create|delete traefik|voyager"
  exit 1
}

function main() {
  if [ "$#" != 2 ]; then
    usage
  fi
  if [ "$1" != create ] && [ "$1" != delete ]; then
    usage
  fi
  if [ "$2" != traefik ] && [ "$2" != voyager ]; then
    usage
  fi

  if [ "$1" = create ]; then
    if [ "$2" = traefik ]; then
      createTraefik
    else
      createVoyager
    fi
  else
    if [ "$2" = traefik ]; then
      deleteTraefik
    else
      deleteVoyager
    fi
  fi
}

main "$@"
