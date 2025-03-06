#!/bin/sh
# Example: CONTEXTS="cluster1 cluster2" ./gather-cluster-info.sh [--hide-cluster-names|-h]

#######################################################################
# This script collects information about the resources in a set of Kubernetes contexts.
# It is v1 of the script used to get minimal information about the clusters used for v1(?)
# of the backend whic is a generalized overview, without specific details (getting region
# information, specific _used_ instance cost, etc.)
#######################################################################

# TODO
# - add in native sidecars https://istio.io/latest/blog/2023/native-sidecars/
# - add region information (v2?)
# - add specific details about the used instances (v2?)

# log colors
INFO='\033[0;34m'
WARN='\033[0;33m'
ERROR='\033[0;31m'
RESET='\033[0m'

log_info() {
  echo "${INFO}[INFO] $1${RESET}"
}

log_warn() {
  echo "${WARN}[WARN] $1${RESET}"
}

log_error() {
  echo "${ERROR}[ERROR] $1${RESET}"
}

# check contexts input
# TODO: Update - v1/MVP will only support a single context
if [ -z "$CONTEXTS" ]; then
  log_error "Please set the CONTEXTS environment variable to a space-separated list of kube contexts."
  exit 1
fi

OBFUSCATE_CLUSTER_NAMES=false

# check for optional flags
while [ $# -gt 0 ]; do
  case "$1" in
    --hide-cluster-names|-h)
      OBFUSCATE_CLUSTER_NAMES=true
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
  shift
done

# verify environment has expected tools
expected_commands="kubectl jq wc awk sha256sum"
missing_commands=""
for cmd in $expected_commands; do
  if ! command -v "$cmd" > /dev/null; then
    missing_commands="$missing_commands $cmd"
  fi
done

if [ -n "$missing_commands" ]; then
  log_error "The following commands are required but not found in the current environment:$missing_commands"
  exit 1
else
  log_info "All required commands found in the current environment."
fi

# Initialize JSON structure
echo '{}' > cluster_info.json

# JQ functions for parsing memory and CPU
parse_mem_cmd='def parse_mem:
  if test("^[0-9]+Ki$") then
    (.[0:-2] | tonumber) * 1024
  elif test("^[0-9]+Mi$") then
    (.[0:-2] | tonumber) * 1024 * 1024
  elif test("^[0-9]+Gi$") then
    (.[0:-2] | tonumber) * 1024 * 1024 * 1024
  else
    tonumber
  end;'

parse_cpu_cmd='def parse_cpu:
  if test("^[0-9]+m$") then
    (.[0:-1] | tonumber) / 1000
  else
    tonumber
  end;'

# Function to process namespace data from cached JSON
process_namespace_data() {
  local ns_name="$1"
  local ctx="$2"
  local out_ctx="$3"

  pods_json=$(kubectl --context="$ctx" -n "$ns_name" get pods -o json 2>/dev/null | jq -c '.items')
  # if the pods_json is empty or null, return 1
  if [ -z "$pods_json" ] || [ "$pods_json" = "null" ]; then
    log_warn "No pods found for namespace $ns_name"
    return 1
  fi

  # Process metrics in multiple steps to ensure proper JSON handling
  local regular_containers=0
  local istio_containers=0
  local pod_count=0
  local regular_cpu=0
  local regular_mem=0
  local istio_cpu=0
  local istio_mem=0

  # Get basic metrics first
  pod_count=$(jq -r 'length' <<< "$pods_json")
  if [ $? -ne 0 ] || [ -z "$pod_count" ]; then
    log_warn "Failed to get pod count for namespace $ns_name"
    return 1
  fi

  # Get container counts
  regular_containers=$(jq -r '[.[] | .spec.containers[]? | select(.name != "istio-proxy")] | length' <<< "$pods_json")
  istio_containers=$(jq -r '[.[] | .spec.containers[]? | select(.name == "istio-proxy")] | length' <<< "$pods_json")

  # Regular containers resources
  if [ "$regular_containers" -gt 0 ]; then
    regular_cpu=$(jq "${parse_cpu_cmd} ([.[] | .spec.containers[]? | select(.name != \"istio-proxy\") | .resources.requests.cpu? | select(. != null) | parse_cpu] | add // 0)" <<< "$pods_json")
    regular_mem=$(jq "${parse_mem_cmd} ([.[] | .spec.containers[]? | select(.name != \"istio-proxy\") | .resources.requests.memory? | select(. != null) | parse_mem] | add // 0) / (1024 * 1024 * 1024)" <<< "$pods_json")
  fi

  # Istio containers resources
  if [ "$istio_containers" -gt 0 ]; then
    istio_cpu=$(jq "${parse_cpu_cmd} ([.[] | .spec.containers[]? | select(.name == \"istio-proxy\") | .resources.requests.cpu? | select(. != null) | parse_cpu] | add // 0)" <<< "$pods_json")
    istio_mem=$(jq "${parse_mem_cmd} ([.[] | .spec.containers[]? | select(.name == \"istio-proxy\") | .resources.requests.memory? | select(. != null) | parse_mem] | add // 0) / (1024 * 1024 * 1024)" <<< "$pods_json")
  fi

  # Construct the final JSON object with error checking
  local metrics
  metrics=$(jq -n \
    --argjson pods "$pod_count" \
    --argjson reg_containers "$regular_containers" \
    --argjson reg_cpu "$regular_cpu" \
    --argjson reg_mem "$regular_mem" \
    --argjson istio_containers "$istio_containers" \
    --argjson istio_cpu "$istio_cpu" \
    --argjson istio_mem "$istio_mem" \
    '{
      pods: $pods,
      resources: {
        regular: {
          containers: $reg_containers,
          request: {
            cpu: $reg_cpu,
            memory_gb: $reg_mem
          }
        },
        istio: {
          containers: $istio_containers,
          request: {
            cpu: $istio_cpu,
            memory_gb: $istio_mem
          }
        }
      }
    }')

  if [ $? -ne 0 ]; then
    log_warn "Failed to construct metrics JSON for namespace $ns_name"
    return 1
  fi

  # Add namespace data to the main JSON file
  if [ -n "$metrics" ]; then
    jq --arg ctx "$out_ctx" --arg ns "$ns_name" --argjson data "$metrics" \
      '.[$ctx].namespaces[$ns] = $data' cluster_info.json > tmp.json && mv tmp.json cluster_info.json
  else
    log_warn "Empty metrics generated for namespace $ns_name"
    return 1
  fi
}

# Loop over each context provided
for ctx in $CONTEXTS; do
  log_info "Processing context: $ctx"

  out_ctx=$ctx
  if [ "$OBFUSCATE_CLUSTER_NAMES" = true ]; then
    out_ctx=$(echo "$ctx" | sha256sum | awk '{print $1}')
  fi

  # Initialize context object
  jq --arg ctx "$out_ctx" '.[$ctx] = {"namespaces": {}, "nodes": 0}' cluster_info.json > tmp.json && mv tmp.json cluster_info.json

  # Cache namespaces with istio injection
  namespaces=$(kubectl --context="$ctx" get ns -o json | \
    jq -r '.items[] | select((.metadata.labels["istio-injection"] == "enabled") or (.metadata.labels["istio.io/rev"] != null)) | .metadata.name')

  if [ -z "$namespaces" ]; then
    log_warn "No namespaces with istio injection found in context $ctx"
    continue
  fi

  # Process each namespace
  while IFS= read -r ns_name; do    
    process_namespace_data "$ns_name" "$ctx" "$out_ctx"
  done <<< "$namespaces"

  # Process node information (single call)
  node_count=$(kubectl --context="$ctx" get nodes --no-headers 2>/dev/null | wc -l)
  jq --arg ctx "$out_ctx" --argjson count "$node_count" \
    '.[$ctx].nodes = $count' cluster_info.json > tmp.json && mv tmp.json cluster_info.json
done

log_info "Data collection complete. Output file: cluster_info.json"
