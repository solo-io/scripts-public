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
      exit 0
      ;;
    --continue|-c)
      CONTINUE_PROCESSING=true
      ;;
    *)
      log_error "Unknown argument: $1"
      help
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

# Function to draw progress bar
draw_progress_bar() {
  _draw_progress_bar_percent="$1"
  _draw_progress_bar_width="$2"
  _draw_progress_bar_filled=$(printf "%.0f" "$(echo "$_draw_progress_bar_percent * $_draw_progress_bar_width / 100" | bc -l)")
  _draw_progress_bar_empty=$((_draw_progress_bar_width - _draw_progress_bar_filled))
  
  # Clear the current line first
  printf "\r\033[K"
  printf "["
  printf "%${_draw_progress_bar_filled}s" | tr ' ' '#'
  printf "%${_draw_progress_bar_empty}s" | tr ' ' '-'
  printf "] %.1f%%" "$_draw_progress_bar_percent"
}

# Function to update progress
update_progress() {
  _update_progress_progress=0
  [ "$TOTAL_NAMESPACES" -gt 0 ] && _update_progress_progress=$(echo "scale=2; $CURRENT_NAMESPACE * 100 / $TOTAL_NAMESPACES" | bc)
  
  # Ensure we don't exceed 100%
  if [ "$(echo "$_update_progress_progress > 100" | bc -l)" -eq 1 ]; then
    _update_progress_progress=100
  fi
  
  draw_progress_bar "$_update_progress_progress" "$PROGRESS_WIDTH"
}

# Check for CONTEXT or use current context
if [ -z "$CONTEXT" ]; then
  CONTEXT=$(kubectl config current-context 2>/dev/null)
  if [ -z "$CONTEXT" ]; then
    log_error "No current kubectl context found and CONTEXT environment variable not set."
    exit 1
  fi
fi

# if not continuing, (re)initialize the cluster_info.json file, else keep the existing file
if [ "$CONTINUE_PROCESSING" = false ]; then
  echo '{"name": "", "namespaces": {}, "nodes": {}, "has_metrics": false}' > cluster_info.json
else
  # check if cluster_info.json exists when continuing
  if [ ! -f "cluster_info.json" ]; then
    log_warn "cluster_info.json does not exist to continue processing. Starting fresh."
    CONTINUE_PROCESSING=false
    echo '{"name": "", "namespaces": {}, "nodes": {}, "has_metrics": false}' > cluster_info.json
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
  _process_node_data_node_name="$1"
  _process_node_data_ctx="$2"
  _process_node_data_has_metrics="$3"

  # Apply name obfuscation if needed
  _process_node_data_out_node_name=$_process_node_data_node_name
  if [ "$OBFUSCATE_NAMES" = true ]; then
    _process_node_data_out_node_name=$(echo "$_process_node_data_node_name" | sha256sum | awk '{print $1}')
  fi

  # check if continuing, if so, skip if node already exists
  if [ "$CONTINUE_PROCESSING" = true ]; then
    if jq -e ".nodes[\"$_process_node_data_out_node_name\"]" cluster_info.json > /dev/null 2>&1; then
      return 0
    fi
  fi

  # cache node information
  _process_node_data_node_info=$(kubectl --context="$_process_node_data_ctx" get node "$_process_node_data_node_name" -o json)
  
  # get the instance type, region, and zone
  _process_node_data_instance_type=$(jq -r '.metadata.labels["kubernetes.io/instance-type"] // "unknown"' << EOF
$_process_node_data_node_info
EOF
)
  _process_node_data_region=$(jq -r '.metadata.labels["topology.kubernetes.io/region"] // "unknown"' << EOF
$_process_node_data_node_info
EOF
)
  _process_node_data_zone=$(jq -r '.metadata.labels["topology.kubernetes.io/zone"] // "unknown"' << EOF
$_process_node_data_node_info
EOF
)

  # get the node cpu and memory capacity
  _process_node_data_node_cpu_capacity=$(jq -r '.status.capacity.cpu // "0"' << EOF
$_process_node_data_node_info
EOF
)
  _process_node_data_node_mem_capacity=$(jq -r '.status.capacity.memory // "0"' << EOF
$_process_node_data_node_info
EOF
)

  # Parse CPU and memory values by converting to string first
  _process_node_data_parsed_cpu_capacity=$(echo "\"$_process_node_data_node_cpu_capacity\"" | jq "${parse_cpu_cmd} parse_cpu // 0")
  _process_node_data_parsed_mem_capacity=$(echo "\"$_process_node_data_node_mem_capacity\"" | jq "${parse_mem_cmd} parse_mem / (1024 * 1024 * 1024) // 0")

  # Initialize usage values
  _process_node_data_parsed_cpu_usage=0
  _process_node_data_parsed_mem_usage=0

  if [ "$_process_node_data_has_metrics" = true ]; then
    _process_node_data_node_metrics_info=$(kubectl --context="$_process_node_data_ctx" get nodes.metrics "$_process_node_data_node_name" -o json)
    _process_node_data_node_cpu_usage=$(jq -r '.usage.cpu // "0"' << EOF
$_process_node_data_node_metrics_info
EOF
)
    _process_node_data_node_mem_usage=$(jq -r '.usage.memory // "0"' << EOF
$_process_node_data_node_metrics_info
EOF
)

    # Parse usage values by converting to string first
    _process_node_data_parsed_cpu_usage=$(echo "\"$_process_node_data_node_cpu_usage\"" | jq "${parse_cpu_cmd} parse_cpu // 0")
    _process_node_data_parsed_mem_usage=$(echo "\"$_process_node_data_node_mem_usage\"" | jq "${parse_mem_cmd} parse_mem / (1024 * 1024 * 1024) // 0")
  fi

  # Build the base jq filter
  # shellcheck disable=SC2016
  _process_node_data_jq_filter='{
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
  # shellcheck disable=SC2016
  if [ "$_process_node_data_has_metrics" = true ]; then
    _process_node_data_jq_filter='{
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
  _process_node_data_node_data=$(jq -n \
    --arg instance_type "$_process_node_data_instance_type" \
    --arg region "$_process_node_data_region" \
    --arg zone "$_process_node_data_zone" \
    --argjson cpu_capacity "$_process_node_data_parsed_cpu_capacity" \
    --argjson mem_capacity "$_process_node_data_parsed_mem_capacity" \
    --argjson cpu_usage "$_process_node_data_parsed_cpu_usage" \
    --argjson mem_usage "$_process_node_data_parsed_mem_usage" \
    "$_process_node_data_jq_filter")

  if [ -z "$_process_node_data_node_data" ]; then
    log_warn "Empty node data generated for node $_process_node_data_node_name"
    return 1
  fi

  # Add node data to the main JSON file
  jq --arg node "$_process_node_data_out_node_name" --argjson data "$_process_node_data_node_data" \
    '.nodes[$node] = $data' cluster_info.json > tmp.json && mv tmp.json cluster_info.json
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
if ! [ -d "$TEMP_DIR" ]; then
  log_error "Failed to create temporary directory for parallel processing"
  exit 1
fi

# Convert to absolute path for maximum safety
TEMP_DIR=$(cd "$TEMP_DIR" && pwd)
log_info "Using temporary directory: $TEMP_DIR"

# some small safety checks before doing rm -rf on the temp directory
trap '[ -n "$TEMP_DIR" ] && [ -d "$TEMP_DIR" ] && rm -rf "$TEMP_DIR"' EXIT

# Function to process a namespace and saves to a temporary file
process_namespace_parallel() {
  _process_namespace_parallel_ns_name="$1"
  _process_namespace_parallel_ctx="$2"
  _process_namespace_parallel_has_metrics="$3"
  _process_namespace_parallel_temp_dir="$4"
  _process_namespace_parallel_output_file="$_process_namespace_parallel_temp_dir/$_process_namespace_parallel_ns_name.json"

  # Apply name obfuscation if needed
  _process_namespace_parallel_out_ns_name=$_process_namespace_parallel_ns_name
  if [ "$OBFUSCATE_NAMES" = true ]; then
    _process_namespace_parallel_out_ns_name=$(echo "$_process_namespace_parallel_ns_name" | sha256sum | awk '{print $1}')
  fi

  # check if continuing, if so, skip if namespace already exists
  if [ "$CONTINUE_PROCESSING" = true ]; then
    if jq -e ".namespaces[\"$_process_namespace_parallel_out_ns_name\"]" cluster_info.json > /dev/null 2>&1; then
      return 0
    fi
  fi
  
  # Check if namespace has Istio injection
  _process_namespace_parallel_is_istio_injected=$(kubectl --context="$_process_namespace_parallel_ctx" get ns "$_process_namespace_parallel_ns_name" -o json | \
    jq -r '(.metadata.labels["istio-injection"] == "enabled") or (.metadata.labels["istio.io/rev"] != null)')
  
  _process_namespace_parallel_out_ns_name=$_process_namespace_parallel_ns_name
  if [ "$OBFUSCATE_NAMES" = true ]; then
    _process_namespace_parallel_out_ns_name=$(echo "$_process_namespace_parallel_ns_name" | sha256sum | awk '{print $1}')
  fi

  _process_namespace_parallel_pods_json=$(kubectl --context="$_process_namespace_parallel_ctx" -n "$_process_namespace_parallel_ns_name" get pods -o json 2>/dev/null | jq -c '.items')
  if [ -z "$_process_namespace_parallel_pods_json" ] || [ "$_process_namespace_parallel_pods_json" = "null" ]; then
    echo "{\"status\": \"error\", \"message\": \"No pods found for namespace $_process_namespace_parallel_ns_name\"}" > "$_process_namespace_parallel_output_file"
    return 1
  fi

  if [ "$_process_namespace_parallel_has_metrics" = true ]; then
    _process_namespace_parallel_pods_json_metrics=$(kubectl --context="$_process_namespace_parallel_ctx" -n "$_process_namespace_parallel_ns_name" get pods.metrics -o json 2>/dev/null | jq -c '.items')
    if [ -z "$_process_namespace_parallel_pods_json_metrics" ] || [ "$_process_namespace_parallel_pods_json_metrics" = "null" ]; then
      echo "No metrics found for pods in namespace $_process_namespace_parallel_ns_name" >> "$_process_namespace_parallel_temp_dir/warnings.log"
    fi
  fi

  # Process metrics in multiple steps to ensure proper JSON handling
  _process_namespace_parallel_regular_containers=0
  _process_namespace_parallel_istio_containers=0
  _process_namespace_parallel_pod_count=0
  _process_namespace_parallel_regular_cpu=0
  _process_namespace_parallel_regular_mem=0
  _process_namespace_parallel_istio_cpu=0
  _process_namespace_parallel_istio_mem=0
  # actual usage based on metrics API, only used if metrics API is available
  _process_namespace_parallel_regular_cpu_actual=0
  _process_namespace_parallel_regular_mem_actual=0
  _process_namespace_parallel_istio_cpu_actual=0
  _process_namespace_parallel_istio_mem_actual=0

  _process_namespace_parallel_pod_count=$(jq -r 'length' << EOF
$_process_namespace_parallel_pods_json
EOF
)
  if [ -z "$_process_namespace_parallel_pod_count" ]; then
    echo "{\"status\": \"error\", \"message\": \"Failed to get pod count for namespace $_process_namespace_parallel_ns_name\"}" > "$_process_namespace_parallel_output_file"
    return 1
  fi

  _process_namespace_parallel_regular_containers=$(jq -r '[.[] | .spec.containers[]? | select(.name != "istio-proxy")] | length' << EOF
$_process_namespace_parallel_pods_json
EOF
)
  _process_namespace_parallel_istio_containers=$(jq -r '[.[] | .spec.containers[]? | select(.name == "istio-proxy")] | length' << EOF
$_process_namespace_parallel_pods_json
EOF
)

  # Regular containers resources
  if [ "$_process_namespace_parallel_regular_containers" -gt 0 ]; then
    _process_namespace_parallel_regular_cpu=$(jq "${parse_cpu_cmd} ([.[] | .spec.containers[]? | select(.name != \"istio-proxy\") | .resources.requests.cpu? | select(. != null) | parse_cpu] | add // 0)" << EOF
$_process_namespace_parallel_pods_json
EOF
)
    _process_namespace_parallel_regular_mem=$(jq "${parse_mem_cmd} ([.[] | .spec.containers[]? | select(.name != \"istio-proxy\") | .resources.requests.memory? | select(. != null) | parse_mem] | add // 0) / (1024 * 1024 * 1024)" << EOF
$_process_namespace_parallel_pods_json
EOF
)
    
    # Get actual usage if metrics API is available
    if [ "$_process_namespace_parallel_has_metrics" = true ] && [ -n "$_process_namespace_parallel_pods_json_metrics" ]; then
      _process_namespace_parallel_regular_cpu_actual=$(jq "${parse_cpu_cmd} ([.[] | .containers[]? | select(.name != \"istio-proxy\") | .usage.cpu? | select(. != null) | parse_cpu] | add // 0)" << EOF
$_process_namespace_parallel_pods_json_metrics
EOF
)
      _process_namespace_parallel_regular_mem_actual=$(jq "${parse_mem_cmd} ([.[] | .containers[]? | select(.name != \"istio-proxy\") | .usage.memory? | select(. != null) | parse_mem] | add // 0) / (1024 * 1024 * 1024)" << EOF
$_process_namespace_parallel_pods_json_metrics
EOF
)
    fi
  fi

  # Istio containers resources (only if namespace has Istio injection)
  if [ "$_process_namespace_parallel_is_istio_injected" = "true" ] && [ "$_process_namespace_parallel_istio_containers" -gt 0 ]; then
    _process_namespace_parallel_istio_cpu=$(jq "${parse_cpu_cmd} ([.[] | .spec.containers[]? | select(.name == \"istio-proxy\") | .resources.requests.cpu? | select(. != null) | parse_cpu] | add // 0)" << EOF
$_process_namespace_parallel_pods_json
EOF
)
    _process_namespace_parallel_istio_mem=$(jq "${parse_mem_cmd} ([.[] | .spec.containers[]? | select(.name == \"istio-proxy\") | .resources.requests.memory? | select(. != null) | parse_mem] | add // 0) / (1024 * 1024 * 1024)" << EOF
$_process_namespace_parallel_pods_json
EOF
)
    
    # Get actual usage if metrics API is available
    if [ "$_process_namespace_parallel_has_metrics" = true ] && [ -n "$_process_namespace_parallel_pods_json_metrics" ]; then
      _process_namespace_parallel_istio_cpu_actual=$(jq "${parse_cpu_cmd} ([.[] | .containers[]? | select(.name == \"istio-proxy\") | .usage.cpu? | select(. != null) | parse_cpu] | add // 0)" << EOF
$_process_namespace_parallel_pods_json_metrics
EOF
)
      _process_namespace_parallel_istio_mem_actual=$(jq "${parse_mem_cmd} ([.[] | .containers[]? | select(.name == \"istio-proxy\") | .usage.memory? | select(. != null) | parse_mem] | add // 0) / (1024 * 1024 * 1024)" << EOF
$_process_namespace_parallel_pods_json_metrics
EOF
)
    fi
  fi

  # Construct the final JSON object with error checking
  # Build the base jq filter
  # shellcheck disable=SC2016
  _process_namespace_parallel_jq_filter='{
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
  # shellcheck disable=SC2016
  if [ "$_process_namespace_parallel_is_istio_injected" = "true" ]; then
    _process_namespace_parallel_jq_filter='{
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
  # shellcheck disable=SC2016
  if [ "$_process_namespace_parallel_has_metrics" = true ]; then
    if [ "$_process_namespace_parallel_is_istio_injected" = "true" ]; then
      _process_namespace_parallel_jq_filter='{
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
      _process_namespace_parallel_jq_filter='{
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
    --arg ns_name "$_process_namespace_parallel_ns_name" \
    --arg out_ns_name "$_process_namespace_parallel_out_ns_name" \
    --argjson pods "$_process_namespace_parallel_pod_count" \
    --argjson is_istio_injected "$_process_namespace_parallel_is_istio_injected" \
    --argjson reg_containers "$_process_namespace_parallel_regular_containers" \
    --argjson reg_cpu "$_process_namespace_parallel_regular_cpu" \
    --argjson reg_mem "$_process_namespace_parallel_regular_mem" \
    --argjson reg_cpu_actual "$_process_namespace_parallel_regular_cpu_actual" \
    --argjson reg_mem_actual "$_process_namespace_parallel_regular_mem_actual" \
    --argjson istio_containers "$_process_namespace_parallel_istio_containers" \
    --argjson istio_cpu "$_process_namespace_parallel_istio_cpu" \
    --argjson istio_mem "$_process_namespace_parallel_istio_mem" \
    --argjson istio_cpu_actual "$_process_namespace_parallel_istio_cpu_actual" \
    --argjson istio_mem_actual "$_process_namespace_parallel_istio_mem_actual" \
    "$_process_namespace_parallel_jq_filter" > "$_process_namespace_parallel_output_file" || {
      echo "{\"status\": \"error\", \"message\": \"Failed to construct metrics JSON for namespace $_process_namespace_parallel_ns_name\"}" > "$_process_namespace_parallel_output_file"
      return 1
    }
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

  # Process each namespace in parallel with controlled concurrency for portability (because `wait -n` is not supported on all platforms)
  counter=0
  touch "$TEMP_DIR/warnings.log"

  while IFS= read -r ns_name; do
    process_namespace_parallel "$ns_name" "$CONTEXT" "$has_metrics" "$TEMP_DIR" &
    counter=$((counter + 1))
  
    CURRENT_NAMESPACE=$((CURRENT_NAMESPACE + 1))
    update_progress
  
    # Once the maximum number of parallel jobs are launched, manually wait for them to finish
    # this is noticably slower than using `wait -n` but it is more portable
    if [ "$counter" -ge "$MAX_PARALLEL" ]; then
      wait
      counter=0
    fi
  done << EOF
$namespaces
EOF

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
