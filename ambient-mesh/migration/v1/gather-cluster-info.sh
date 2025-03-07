#!/bin/sh
# Example: CONTEXTS="cluster1 cluster2" ./gather-cluster-info.sh [--hide-names|-hn] [--help|-h]

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

# Progress bar variables
PROGRESS_WIDTH=50
TOTAL_CLUSTERS=0
TOTAL_NAMESPACES=0
CURRENT_CLUSTER=0
CURRENT_NAMESPACE=0
CURRENT_CLUSTER_NAMESPACES=0

help() {
  echo "Usage: $0 [--hide-names|-hn] [--help|-h]"
  echo "  --hide-names|-hn: Hide the names of the clusters and namespaces using a hash"
  echo "  --help|-h: Show this help message"
  exit 1
}

log_info() {
  echo "${INFO}[INFO] $1${RESET}"
}

log_warn() {
  echo "${WARN}[WARN] $1${RESET}"
}

log_error() {
  echo "${ERROR}[ERROR] $1${RESET}"
}

# Function to draw progress bar
draw_progress_bar() {
  local percent=$1
  local width=$2
  local filled=$(printf "%.0f" $(echo "$percent * $width / 100" | bc -l))
  local empty=$((width - filled))
  
  # Clear the current line first
  printf "\r\033[K"
  printf "["
  printf "%${filled}s" | tr ' ' '#'
  printf "%${empty}s" | tr ' ' '-'
  printf "] %.1f%%" "$percent"
}

# Function to update progress
update_progress() {
  local progress=0
  [ $CURRENT_CLUSTER_NAMESPACES -gt 0 ] && progress=$(echo "scale=2; $CURRENT_NAMESPACE * 100 / $CURRENT_CLUSTER_NAMESPACES" | bc)
  
  # Ensure we don't exceed 100%
  if [ $(echo "$progress > 100" | bc -l) -eq 1 ]; then
    progress=100
  fi
  
  draw_progress_bar $progress $PROGRESS_WIDTH
}

# check contexts input
# TODO: Update - v1/MVP will only support a single context
if [ -z "$CONTEXTS" ]; then
  log_error "Please set the CONTEXTS environment variable to a space-separated list of kube contexts."
  exit 1
fi

OBFUSCATE_NAMES=false

# check for optional flags
while [ $# -gt 0 ]; do
  case "$1" in
    --hide-names|-hn)
      OBFUSCATE_NAMES=true
      ;;
    --help|-h)
      help
      ;;
    *)
      log_error "Unknown argument: $1"
      exit 1
      ;;
  esac
  shift
done

# verify environment has expected tools
expected_commands="kubectl jq wc awk sha256sum bc"
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
  elif test("^[0-9]+Ti$") then
    (.[0:-2] | tonumber) * 1024 * 1024 * 1024 * 1024
  elif test("^[0-9]+Pi$") then
    (.[0:-2] | tonumber) * 1024 * 1024 * 1024 * 1024 * 1024
  elif test("^[0-9]+Ei$") then
    (.[0:-2] | tonumber) * 1024 * 1024 * 1024 * 1024 * 1024 * 1024
  else
    tonumber
  end;'

parse_cpu_cmd='def parse_cpu:
  if test("^[0-9]+n$") then
    (.[0:-1] | tonumber) / 1000000000
  elif test("^[0-9]+u$") then
    (.[0:-1] | tonumber) / 1000000
  elif test("^[0-9]+m$") then
    (.[0:-1] | tonumber) / 1000
  else
    tonumber
  end;'

process_node_data() {
  local node_name="$1"
  local ctx="$2"
  local out_ctx="$3"
  local has_metrics="$4"

  out_node_name=$node_name
  if [ "$OBFUSCATE_NAMES" = true ]; then
    out_node_name=$(echo "$node_name" | sha256sum | awk '{print $1}')
  fi

  # cache node information
  local node_info=$(kubectl --context="$ctx" get node "$node_name" -o json)
  
  # get the instance type, region, and zone
  local instance_type=$(jq -r '.metadata.labels["kubernetes.io/instance-type"] // "unknown"' <<< "$node_info")
  local region=$(jq -r '.metadata.labels["topology.kubernetes.io/region"] // "unknown"' <<< "$node_info")
  local zone=$(jq -r '.metadata.labels["topology.kubernetes.io/zone"] // "unknown"' <<< "$node_info")

  # get the node cpu and memory capacity
  local node_cpu_capacity=$(jq -r '.status.capacity.cpu // "0"' <<< "$node_info")
  local node_mem_capacity=$(jq -r '.status.capacity.memory // "0"' <<< "$node_info")

  # Parse CPU and memory values by converting to string first
  local parsed_cpu_capacity=$(echo "\"$node_cpu_capacity\"" | jq "${parse_cpu_cmd} parse_cpu // 0")
  local parsed_mem_capacity=$(echo "\"$node_mem_capacity\"" | jq "${parse_mem_cmd} parse_mem / (1024 * 1024 * 1024) // 0")

  # Initialize usage values
  local parsed_cpu_usage=0
  local parsed_mem_usage=0

  if [ "$has_metrics" = true ]; then
    local node_metrics_info=$(kubectl --context="$ctx" get nodes.metrics "$node_name" -o json)
    local node_cpu_usage=$(jq -r '.usage.cpu // "0"' <<< "$node_metrics_info")
    local node_mem_usage=$(jq -r '.usage.memory // "0"' <<< "$node_metrics_info")

    # Parse usage values by converting to string first
    parsed_cpu_usage=$(echo "\"$node_cpu_usage\"" | jq "${parse_cpu_cmd} parse_cpu // 0")
    parsed_mem_usage=$(echo "\"$node_mem_usage\"" | jq "${parse_mem_cmd} parse_mem / (1024 * 1024 * 1024) // 0")
  fi

  # Construct the final JSON object with error checking
  local node_data
  local jq_filter

  # Build the base jq filter
  jq_filter='{
    instance_type: $instance_type,
    region: $region,
    zone: $zone,
    resources: {
      capacity: {
        cpu: $cpu_capacity,
        memory_gb: $mem_capacity
      }
    }
  }'

  # If metrics are available, add actual usage to the filter
  if [ "$has_metrics" = true ]; then
    jq_filter='{
      instance_type: $instance_type,
      region: $region,
      zone: $zone,
      resources: {
        capacity: {
          cpu: $cpu_capacity,
          memory_gb: $mem_capacity
        },
        actual: {
          cpu: $cpu_usage,
          memory_gb: $mem_usage
        }
      }
    }'
  fi

  # Use jq to construct the node data object
  node_data=$(jq -n \
    --arg instance_type "$instance_type" \
    --arg region "$region" \
    --arg zone "$zone" \
    --argjson cpu_capacity "$parsed_cpu_capacity" \
    --argjson mem_capacity "$parsed_mem_capacity" \
    --argjson cpu_usage "$parsed_cpu_usage" \
    --argjson mem_usage "$parsed_mem_usage" \
    "$jq_filter")

  if [ $? -ne 0 ]; then
    log_warn "Failed to construct node data JSON for node $node_name"
    return 1
  fi

  # Add node data to the main JSON file
  if [ -n "$node_data" ]; then
    jq --arg ctx "$out_ctx" --arg node "$out_node_name" --argjson data "$node_data" \
      '.[$ctx].nodes[$node] = $data' cluster_info.json > tmp.json && mv tmp.json cluster_info.json
  else
    log_warn "Empty node data generated for node $node_name"
    return 1
  fi
}

# Function to process namespace data from cached JSON
process_namespace_data() {
  local ns_name="$1"
  local ctx="$2"
  local out_ctx="$3"
  local has_metrics="$4"

  out_ns_name=$ns_name
  if [ "$OBFUSCATE_NAMES" = true ]; then
    out_ns_name=$(echo "$ns_name" | sha256sum | awk '{print $1}')
  fi

  pods_json=$(kubectl --context="$ctx" -n "$ns_name" get pods -o json 2>/dev/null | jq -c '.items')
  # if the pods_json is empty or null, return 1
  if [ -z "$pods_json" ] || [ "$pods_json" = "null" ]; then
    log_warn "No pods found for namespace $ns_name"
    return 1
  fi

  if [ "$has_metrics" = true ]; then
    pods_json_metrics=$(kubectl --context="$ctx" -n "$ns_name" get pods.metrics -o json 2>/dev/null | jq -c '.items')
    if [ -z "$pods_json_metrics" ] || [ "$pods_json_metrics" = "null" ]; then
      log_warn "No metrics found for pods in namespace $ns_name"
    fi
  fi

  # Process metrics in multiple steps to ensure proper JSON handling
  local regular_containers=0
  local istio_containers=0
  local pod_count=0
  local regular_cpu=0
  local regular_mem=0
  local istio_cpu=0
  local istio_mem=0
  # actual usage based on metrics API, only used if metrics API is available
  local regular_cpu_actual=0
  local regular_mem_actual=0
  local istio_cpu_actual=0
  local istio_mem_actual=0

  pod_count=$(jq -r 'length' <<< "$pods_json")
  if [ $? -ne 0 ] || [ -z "$pod_count" ]; then
    log_warn "Failed to get pod count for namespace $ns_name"
    return 1
  fi

  regular_containers=$(jq -r '[.[] | .spec.containers[]? | select(.name != "istio-proxy")] | length' <<< "$pods_json")
  istio_containers=$(jq -r '[.[] | .spec.containers[]? | select(.name == "istio-proxy")] | length' <<< "$pods_json")

  # Regular containers resources
  if [ "$regular_containers" -gt 0 ]; then
    regular_cpu=$(jq "${parse_cpu_cmd} ([.[] | .spec.containers[]? | select(.name != \"istio-proxy\") | .resources.requests.cpu? | select(. != null) | parse_cpu] | add // 0)" <<< "$pods_json")
    regular_mem=$(jq "${parse_mem_cmd} ([.[] | .spec.containers[]? | select(.name != \"istio-proxy\") | .resources.requests.memory? | select(. != null) | parse_mem] | add // 0) / (1024 * 1024 * 1024)" <<< "$pods_json")
    
    # Get actual usage if metrics API is available
    if [ "$has_metrics" = true ] && [ -n "$pods_json_metrics" ]; then
      regular_cpu_actual=$(jq "${parse_cpu_cmd} ([.[] | .containers[]? | select(.name != \"istio-proxy\") | .usage.cpu? | select(. != null) | parse_cpu] | add // 0)" <<< "$pods_json_metrics")
      regular_mem_actual=$(jq "${parse_mem_cmd} ([.[] | .containers[]? | select(.name != \"istio-proxy\") | .usage.memory? | select(. != null) | parse_mem] | add // 0) / (1024 * 1024 * 1024)" <<< "$pods_json_metrics")
    fi
  fi

  # Istio containers resources
  if [ "$istio_containers" -gt 0 ]; then
    istio_cpu=$(jq "${parse_cpu_cmd} ([.[] | .spec.containers[]? | select(.name == \"istio-proxy\") | .resources.requests.cpu? | select(. != null) | parse_cpu] | add // 0)" <<< "$pods_json")
    istio_mem=$(jq "${parse_mem_cmd} ([.[] | .spec.containers[]? | select(.name == \"istio-proxy\") | .resources.requests.memory? | select(. != null) | parse_mem] | add // 0) / (1024 * 1024 * 1024)" <<< "$pods_json")
    
    # Get actual usage if metrics API is available
    if [ "$has_metrics" = true ] && [ -n "$pods_json_metrics" ]; then
      istio_cpu_actual=$(jq "${parse_cpu_cmd} ([.[] | .containers[]? | select(.name == \"istio-proxy\") | .usage.cpu? | select(. != null) | parse_cpu] | add // 0)" <<< "$pods_json_metrics")
      istio_mem_actual=$(jq "${parse_mem_cmd} ([.[] | .containers[]? | select(.name == \"istio-proxy\") | .usage.memory? | select(. != null) | parse_mem] | add // 0) / (1024 * 1024 * 1024)" <<< "$pods_json_metrics")
    fi
  fi

  # Construct the final JSON object with error checking
  local metrics
  local jq_filter

  # Build the base jq filter
  jq_filter='{
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
  }'

  # If metrics are available, add actual usage to the filter
  if [ "$has_metrics" = true ]; then
    jq_filter='{
      pods: $pods,
      resources: {
        regular: {
          containers: $reg_containers,
          request: {
            cpu: $reg_cpu,
            memory_gb: $reg_mem
          },
          actual: {
            cpu: $reg_cpu_actual,
            memory_gb: $reg_mem_actual
          }
        },
        istio: {
          containers: $istio_containers,
          request: {
            cpu: $istio_cpu,
            memory_gb: $istio_mem
          },
          actual: {
            cpu: $istio_cpu_actual,
            memory_gb: $istio_mem_actual
          }
        }
      }
    }'
  fi

  # Use jq to construct the metrics object
  metrics=$(jq -n \
    --argjson pods "$pod_count" \
    --argjson reg_containers "$regular_containers" \
    --argjson reg_cpu "$regular_cpu" \
    --argjson reg_mem "$regular_mem" \
    --argjson reg_cpu_actual "$regular_cpu_actual" \
    --argjson reg_mem_actual "$regular_mem_actual" \
    --argjson istio_containers "$istio_containers" \
    --argjson istio_cpu "$istio_cpu" \
    --argjson istio_mem "$istio_mem" \
    --argjson istio_cpu_actual "$istio_cpu_actual" \
    --argjson istio_mem_actual "$istio_mem_actual" \
    "$jq_filter")

  if [ $? -ne 0 ]; then
    log_warn "Failed to construct metrics JSON for namespace $ns_name"
    return 1
  fi

  # Add namespace data to the main JSON file
  if [ -n "$metrics" ]; then
    jq --arg ctx "$out_ctx" --arg ns "$out_ns_name" --argjson data "$metrics" \
      '.[$ctx].namespaces[$ns] = $data' cluster_info.json > tmp.json && mv tmp.json cluster_info.json
  else
    log_warn "Empty metrics generated for namespace $ns_name"
    return 1
  fi
}

# Count total clusters and namespaces
TOTAL_CLUSTERS=$(echo "$CONTEXTS" | wc -w)
for ctx in $CONTEXTS; do
  ns_count=$(kubectl --context="$ctx" get ns -o json | \
    jq -r '[.items[] | select((.metadata.labels["istio-injection"] == "enabled") or (.metadata.labels["istio.io/rev"] != null)) | .metadata.name] | length')
  TOTAL_NAMESPACES=$((TOTAL_NAMESPACES + ns_count))
done

log_info "Found $TOTAL_CLUSTERS clusters with a total of $TOTAL_NAMESPACES namespaces to process"

for ctx in $CONTEXTS; do
  echo
  log_info "Processing context: $ctx"
  
  out_ctx=$ctx
  if [ "$OBFUSCATE_NAMES" = true ]; then
    out_ctx=$(echo "$ctx" | sha256sum | awk '{print $1}')
  fi

  # Check if metrics API is available for this cluster
  has_metrics=false
  if kubectl --context="$ctx" top pod -A >/dev/null 2>&1; then
    has_metrics=true
    log_info "Metrics API available for cluster $ctx"
  else
    log_warn "Metrics API not available for cluster $ctx"
  fi

  # Initialize context object
  jq --arg ctx "$out_ctx" --argjson has_metrics "$has_metrics" \
    '.[$ctx] = {"namespaces": {}, "nodes": {}, "has_metrics": $has_metrics}' cluster_info.json > tmp.json && mv tmp.json cluster_info.json

  # Process node information (just the count, at least for now)
  # node_count=$(kubectl --context="$ctx" get nodes --no-headers 2>/dev/null | wc -l)
  
  # get list of nodes
  nodes=$(kubectl --context="$ctx" get nodes -o json | jq -r '.items[] | .metadata.name')
  if [ -z "$nodes" ]; then
    log_warn "No nodes found for cluster $ctx"
    CURRENT_CLUSTER=$((CURRENT_CLUSTER + 1))
    continue
  fi
  
  # process each node
  for node in $nodes; do
    process_node_data "$node" "$ctx" "$out_ctx" "$has_metrics"
  done

  # Cache namespaces with istio injection
  namespaces=$(kubectl --context="$ctx" get ns -o json | \
    jq -r '.items[] | select((.metadata.labels["istio-injection"] == "enabled") or (.metadata.labels["istio.io/rev"] != null)) | .metadata.name')

  if [ -z "$namespaces" ]; then
    log_warn "No namespaces with istio injection found in context $ctx"
    CURRENT_CLUSTER=$((CURRENT_CLUSTER + 1))
    continue
  fi

  # Reset namespace counter for this cluster
  CURRENT_NAMESPACE=0
  CURRENT_CLUSTER_NAMESPACES=$(echo "$namespaces" | wc -l)
  update_progress

  # Process each namespace
  while IFS= read -r ns_name; do
    process_namespace_data "$ns_name" "$ctx" "$out_ctx" "$has_metrics"
    CURRENT_NAMESPACE=$((CURRENT_NAMESPACE + 1))
    update_progress
  done <<< "$namespaces"

  CURRENT_CLUSTER=$((CURRENT_CLUSTER + 1))
done

echo # New line after progress bar
log_info "Data collection complete. Output file: cluster_info.json"
