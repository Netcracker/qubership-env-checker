#!/bin/bash

check_namespace() {
    local namespace="$1"
    kubectl get namespace "$namespace" > /dev/null 2>&1
    if [ $? -ne 0 ]; then
        printf "\033[0;31mERROR: namespace=$namespace does not exist.\033[0m\n"
        return 1
    fi
    return 0
}

local params="$1"
local namespace_value=""
local overall_result=0

if [[ $params == "namespace:"* ]]; then
    namespace_value=$(echo "$params" | grep -oP '(?<=namespace: ).*')
    check_namespace "$namespace_value" || overall_result=1
elif [[ $params == "namespaces:"* ]]; then
    namespace_value=$(echo "$params" | grep -oP '(?<=namespaces: ).*')
    namespace_value=$(echo "$namespace_value" | tr -d '[] ') # Removing square brackets and commas
    IFS=',' read -ra namespaces <<< "$namespace_value" # Split into individual values
    for ns in "${namespaces[@]}"; do
        check_namespace "$ns" || overall_result=1
    done
fi

exit $overall_result