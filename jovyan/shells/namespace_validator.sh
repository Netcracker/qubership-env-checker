#!/bin/bash

check_namespace() {
    local namespace="$1"
    if ! kubectl get namespace "$namespace" > /dev/null 2>&1; then
        printf "\033[0;31mERROR: namespace=%s does not exist.\033[0m\n" "$namespace"
        return 1
    fi
    return 0
}

params="$1"
namespace_value=""
overall_result=0

if [[ $params == "namespace:"* ]]; then
    namespace_value=$(echo "$params" | grep -oP '(?<=namespace: ).*')
    check_namespace "$namespace_value" || overall_result=1
elif [[ $params == "namespaces:"* ]]; then
    namespace_value=$(echo "$params" | grep -oP '(?<=namespaces: ).*')
    namespace_value=$(echo "$namespace_value" | tr -d '[] ')
    IFS=',' read -ra namespaces <<< "$namespace_value"
    for ns in "${namespaces[@]}"; do
        check_namespace "$ns" || overall_result=1
    done
fi

exit $overall_result