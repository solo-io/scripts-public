#!/bin/sh
# Example: CONTEXT="mycluster" ./gather-cluster-info.sh [--hide-names|-hn] [--continue|-c] [--help|-h]

#######################################################################
# This script gathers only minimal information about the cluster
# for a generalized overview of its resources,
# without gathering specific details such as the region, instance cost, etc.
#######################################################################

# log colors
INFO='\033[0;34m'
WARN='\033[0;33m'
ERROR='\033[0;31m'
RESET='\033[0m'

# Progress bar variables
PROGRESS_WIDTH=50
TOTAL_NAMESPACES=0
CURRENT_NAMESPACE=0

help() {
  echo "Usage: $0 [--hide-names|-hn] [--help|-h] [--continue|-c]"
  echo "  --hide-names|-hn: Hide the names of the cluster and namespaces using a hash."
  echo "  --help|-h: Show this help message."
  echo "  --continue|-c: If the script was interrupted, continue processing from the last saved state."
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
  [ $TOTAL_NAMESPACES -gt 0 ] && progress=$(echo "scale=2; $CURRENT_NAMESPACE * 100 / $TOTAL_NAMESPACES" | bc)
  
  # Ensure we don't exceed 100%
  if [ $(echo "$progress > 100" | bc -l) -eq 1 ]; then
    progress=100
  fi
  
  draw_progress_bar $progress $PROGRESS_WIDTH
}

# Check for CONTEXT or use current context
if [ -z "$CONTEXT" ]; then
  CONTEXT=$(kubectl config current-context 2>/dev/null)
  if [ -z "$CONTEXT" ]; then
    log_error "No current kubectl context found and CONTEXT environment variable not set."
    exit 1
  fi
fi

OBFUSCATE_NAMES=false
CONTINUE_PROCESSING=false

# check for optional flags
while [ $# -gt 0 ]; do
  case "$1" in
    --hide-names|-hn)
      OBFUSCATE_NAMES=true
      ;;
    --help|-h)
      help
      ;;
    --continue|-c)
      CONTINUE_PROCESSING=true
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
  log_error "The following commands are required but not found in the current environment: $missing_commands"
  exit 1
fi

# if not continuing, (re)initialize the cluster_info.json file, else keep the existing file
if [ "$CONTINUE_PROCESSING" = false ]; then
  echo '{"name": "", "namespaces": {}, "nodes": {}, "has_metrics": false}' > cluster_info.json
else
  # check if cluster_info.json exists when continuing
  if [ ! -f "cluster_info.json" ]; then
    log_error "cluster_info.json does not exist to continue processing"
    exit 1
  fi
fi

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
  local has_metrics="$3"

  # check if continuing, if so, skip if node already exists
  if [ "$CONTINUE_PROCESSING" = true ]; then
    if jq -e ".nodes[\"$node_name\"]" cluster_info.json > /dev/null 2>&1; then
      return 0
    fi
  fi

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
    jq --arg node "$out_node_name" --argjson data "$node_data" \
      '.nodes[$node] = $data' cluster_info.json > tmp.json && mv tmp.json cluster_info.json
  else
    log_warn "Empty node data generated for node $node_name"
    return 1
  fi
}

# Check if system supports parallel processing
MAX_PARALLEL=8  # Default number of parallel processes
if command -v nproc > /dev/null; then
  CORES=$(nproc)
  MAX_PARALLEL=$((CORES > 8 ? 8 : CORES))
  log_info "System has $CORES cores, using $MAX_PARALLEL parallel processes for namespace processing"
else
  log_info "Using default of $MAX_PARALLEL parallel processes for namespace processing"
fi

# temporary directory to store namespace processing results
TEMP_DIR=$(mktemp -d)
if [ $? -ne 0 ]; then
  log_error "Failed to create temporary directory for parallel processing"
  exit 1
fi

# Setup cleanup trap
trap 'rm -rf "$TEMP_DIR"' EXIT

# Function to process a namespace and saves to a temporary file
process_namespace_parallel() {
  local ns_name="$1"
  local ctx="$2"
  local has_metrics="$3"
  local temp_dir="$4"
  local output_file="$temp_dir/$ns_name.json"

  # check if continuing, if so, skip if namespace already exists
  if [ "$CONTINUE_PROCESSING" = true ]; then
    if jq -e ".namespaces[\"$ns_name\"]" cluster_info.json > /dev/null 2>&1; then
      return 0
    fi
  fi
  
  # Check if namespace has Istio injection
  is_istio_injected=$(kubectl --context="$ctx" get ns "$ns_name" -o json | \
    jq -r '(.metadata.labels["istio-injection"] == "enabled") or (.metadata.labels["istio.io/rev"] != null)')
  
  out_ns_name=$ns_name
  if [ "$OBFUSCATE_NAMES" = true ]; then
    out_ns_name=$(echo "$ns_name" | sha256sum | awk '{print $1}')
  fi

  pods_json=$(kubectl --context="$ctx" -n "$ns_name" get pods -o json 2>/dev/null | jq -c '.items')
  if [ -z "$pods_json" ] || [ "$pods_json" = "null" ]; then
    echo "{\"status\": \"error\", \"message\": \"No pods found for namespace $ns_name\"}" > "$output_file"
    return 1
  fi

  if [ "$has_metrics" = true ]; then
    pods_json_metrics=$(kubectl --context="$ctx" -n "$ns_name" get pods.metrics -o json 2>/dev/null | jq -c '.items')
    if [ -z "$pods_json_metrics" ] || [ "$pods_json_metrics" = "null" ]; then
      echo "No metrics found for pods in namespace $ns_name" >> "$temp_dir/warnings.log"
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
    echo "{\"status\": \"error\", \"message\": \"Failed to get pod count for namespace $ns_name\"}" > "$output_file"
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

  # Istio containers resources (only if namespace has Istio injection)
  if [ "$is_istio_injected" = "true" ] && [ "$istio_containers" -gt 0 ]; then
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
    ns_name: $ns_name,
    out_ns_name: $out_ns_name,
    pods: $pods,
    is_istio_injected: $is_istio_injected,
    resources: {
      regular: {
        containers: $reg_containers,
        request: {
          cpu: $reg_cpu,
          memory_gb: $reg_mem
        }
      }
    }
  }'

  # If namespace has Istio injection, add Istio resources
  if [ "$is_istio_injected" = "true" ]; then
    jq_filter='{
      ns_name: $ns_name,
      out_ns_name: $out_ns_name,
      pods: $pods,
      is_istio_injected: $is_istio_injected,
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
  fi

  # If metrics are available, add actual usage to the filter
  if [ "$has_metrics" = true ]; then
    if [ "$is_istio_injected" = "true" ]; then
      jq_filter='{
        ns_name: $ns_name,
        out_ns_name: $out_ns_name,
        pods: $pods,
        is_istio_injected: $is_istio_injected,
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
    else
      jq_filter='{
        ns_name: $ns_name,
        out_ns_name: $out_ns_name,
        pods: $pods,
        is_istio_injected: $is_istio_injected,
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
          }
        }
      }'
    fi
  fi

  # Use jq to construct the metrics object and save to temporary file
  jq -n \
    --arg ns_name "$ns_name" \
    --arg out_ns_name "$out_ns_name" \
    --argjson pods "$pod_count" \
    --argjson is_istio_injected "$is_istio_injected" \
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
    "$jq_filter" > "$output_file"

  if [ $? -ne 0 ]; then
    echo "{\"status\": \"error\", \"message\": \"Failed to construct metrics JSON for namespace $ns_name\"}" > "$output_file"
    return 1
  fi
}

# Get count of namespaces
TOTAL_NAMESPACES=$(kubectl --context="$CONTEXT" get ns -o json | jq -r '.items[] | .metadata.name' | wc -l)
log_info "Found a total of $TOTAL_NAMESPACES namespace(s) to process in context $CONTEXT"

out_ctx=$CONTEXT
if [ "$OBFUSCATE_NAMES" = true ]; then
  out_ctx=$(echo "$CONTEXT" | sha256sum | awk '{print $1}')
fi

# Set the cluster name in the JSON
jq --arg name "$out_ctx" '.name = $name' cluster_info.json > tmp.json && mv tmp.json cluster_info.json

# Check if metrics API is available for this cluster
has_metrics=false
if kubectl --context="$CONTEXT" top pod -A >/dev/null 2>&1; then
  has_metrics=true
  log_info "Metrics API available for cluster $CONTEXT"
else
  log_warn "Metrics API not available for cluster $CONTEXT"
fi

# Update the has_metrics field
jq --argjson has_metrics "$has_metrics" '.has_metrics = $has_metrics' cluster_info.json > tmp.json && mv tmp.json cluster_info.json

# get list of nodes
nodes=$(kubectl --context="$CONTEXT" get nodes -o json | jq -r '.items[] | .metadata.name')
if [ -z "$nodes" ]; then
  log_warn "No nodes found for cluster $CONTEXT"
else
  # process each node
  for node in $nodes; do
    process_node_data "$node" "$CONTEXT" "$has_metrics"
  done
fi

# Cache namespaces with istio injection
namespaces=$(kubectl --context="$CONTEXT" get ns -o json | \
  jq -r '.items[] | .metadata.name')

if [ -z "$namespaces" ]; then
  log_warn "No namespaces found in context $CONTEXT"
else
  # Reset namespace counter
  CURRENT_NAMESPACE=0
  TOTAL_NAMESPACES=$(echo "$namespaces" | wc -l)
  update_progress

  # Process each namespace in parallel with controlled concurrency
  running=0
  touch "$TEMP_DIR/warnings.log"

  while IFS= read -r ns_name; do
    # Wait if we've reached the maximum number of parallel processes
    while [ $running -ge $MAX_PARALLEL ]; do
      # Wait for a child process to finish
      wait -n 2>/dev/null || true
      # Count remaining background jobs
      running=$(jobs -p | wc -l)
    done

    process_namespace_parallel "$ns_name" "$CONTEXT" "$has_metrics" "$TEMP_DIR" &
    running=$((running + 1))
    
    # For a more accurate progress bar, increment after each job is launched
    CURRENT_NAMESPACE=$((CURRENT_NAMESPACE + 1))
    update_progress
  done <<< "$namespaces"

  # Wait for all background jobs to complete
  wait

  # Process warnings
  if [ -s "$TEMP_DIR/warnings.log" ]; then
    while IFS= read -r warning; do
      log_warn "$warning"
      log_info "If this was a transient error, you can re-run the script with the --continue flag to only process the namespaces that failed"
    done < "$TEMP_DIR/warnings.log"
  fi

  # Process results and incorporate into main JSON file
  for result_file in "$TEMP_DIR"/*.json; do
    if [ -f "$result_file" ]; then
      # Check if file contains an error message
      is_error=$(jq -r '.status // "success"' "$result_file")
      
      if [ "$is_error" = "error" ]; then
        error_msg=$(jq -r '.message' "$result_file")
        log_warn "$error_msg"
        log_info "If this was a transient error, you can re-run the script with the --continue flag to only process the namespaces that failed"
      else
        ns_name=$(jq -r '.ns_name' "$result_file")
        out_ns_name=$(jq -r '.out_ns_name' "$result_file")
        
        # Remove the internal fields we added for processing
        jq 'del(.ns_name) | del(.out_ns_name)' "$result_file" > "$result_file.tmp"
        
        # Add to the final cluster json
        jq --arg ns "$out_ns_name" --slurpfile data "$result_file.tmp" \
          '.namespaces[$ns] = $data[0]' cluster_info.json > tmp.json && mv tmp.json cluster_info.json
      fi
    fi
  done
fi

echo # New line after progress bar
log_info "Data collection complete. Output file: cluster_info.json"
