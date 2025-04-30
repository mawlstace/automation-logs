#!/bin/bash
# Kubernetes Log Monitor CLI tool with Back option at every step

# Configuration
API_PORT=8080
NAMESPACE="log-monitoring"
SERVICE_NAME="log-monitor-api"
API_URL="http://localhost:$API_PORT"

# Set up port forwarding
setup_port_forwarding() {
  echo "Setting up port forwarding..."
  # Check if port forwarding is already active
  if [ -f /tmp/log-monitor-portforward.pid ]; then
    PF_PID=$(cat /tmp/log-monitor-portforward.pid)
    if ps -p $PF_PID > /dev/null; then
      echo "Port forwarding already active (PID: $PF_PID)"
      return 0
    fi
  fi
  
  kubectl port-forward -n $NAMESPACE svc/$SERVICE_NAME $API_PORT:$API_PORT &
  PF_PID=$!
  echo $PF_PID > /tmp/log-monitor-portforward.pid
  echo "Port forwarding started with PID: $PF_PID"
  sleep 2
  
  # Verify port forwarding is working
  if ! curl -s "$API_URL" > /dev/null; then
    echo "Port forwarding failed. Please check if the service is running."
    kill $PF_PID 2>/dev/null
    rm -f /tmp/log-monitor-portforward.pid
    return 1
  fi
  
  return 0
}

# Clean up on exit
cleanup() {
  if [ -f /tmp/log-monitor-portforward.pid ]; then
    PF_PID=$(cat /tmp/log-monitor-portforward.pid)
    echo "Cleaning up port forwarding (PID: $PF_PID)..."
    kill $PF_PID &> /dev/null
    rm -f /tmp/log-monitor-portforward.pid
  fi
}

trap cleanup EXIT

# Check if the API is accessible
check_api() {
  if ! kubectl get svc $SERVICE_NAME -n $NAMESPACE &> /dev/null; then
    echo "Log monitor service not found."
    echo "Make sure the log monitor is deployed in namespace '$NAMESPACE'."
    return 1
  fi
  
  # Set up port forwarding
  setup_port_forwarding || return 1
  
  # Check if API is responding
  if ! curl -s "$API_URL" > /dev/null; then
    echo "API is not responding. Check if the service is running correctly."
    return 1
  fi
  
  return 0
}

# Function to read user input with back option
read_with_back() {
  local prompt="$1"
  local var_name="$2"
  
  while true; do
    read -p "$prompt (or 'back' to go back): " input
    if [ "$input" = "back" ]; then
      return 1
    elif [ -n "$input" ]; then
      eval "$var_name='$input'"
      return 0
    else
      echo "Please enter a valid input or 'back'"
    fi
  done
}

# Function to select a namespace
select_namespace() {
  while true; do
    echo "==== SELECT NAMESPACE ===="
    echo "Fetching available namespaces..."
    
    NAMESPACES_JSON=$(curl -s "$API_URL/api/namespaces")
    if [ -z "$NAMESPACES_JSON" ]; then
      echo "Failed to fetch namespaces. Check if the monitor is running."
      return 1
    fi
    
    # Parse the JSON response to extract namespaces
    NAMESPACES=$(echo "$NAMESPACES_JSON" | grep -o '"namespaces":\[[^]]*\]' | sed 's/"namespaces":\[//;s/\]//' | tr ',' '\n' | sed 's/"//g')
    
    echo "Available namespaces:"
    echo "0) All namespaces"
    echo "b) Back to main menu"
    i=1
    for ns in $NAMESPACES; do
      echo "$i) $ns"
      i=$((i+1))
    done
    
    read -p "Select a namespace (number, or 'b' for back): " NS_CHOICE
    
    if [ "$NS_CHOICE" = "b" ] || [ "$NS_CHOICE" = "back" ]; then
      return 1
    elif [ "$NS_CHOICE" -eq 0 ]; then
      SELECTED_NS="all"
      echo "Selected namespace: $SELECTED_NS"
      return 0
    else
      SELECTED_NS=$(echo "$NAMESPACES" | sed -n "${NS_CHOICE}p")
      if [ -n "$SELECTED_NS" ]; then
        echo "Selected namespace: $SELECTED_NS"
        return 0
      else
        echo "Invalid selection. Please try again."
      fi
    fi
  done
}

# Function to select target type (deployment or pod)
select_target_type() {
  while true; do
    echo "==== SELECT TARGET TYPE ===="
    echo "What would you like to monitor?"
    echo "1) Deployments"
    echo "2) Pods"
    echo "b) Back to namespace selection"
    
    read -p "Select option (1, 2, or 'b' for back): " TARGET_CHOICE
    
    if [ "$TARGET_CHOICE" = "b" ] || [ "$TARGET_CHOICE" = "back" ]; then
      return 1
    elif [ "$TARGET_CHOICE" -eq 1 ]; then
      TARGET_TYPE="deployment"
      echo "Selected to monitor deployments"
      return 0
    elif [ "$TARGET_CHOICE" -eq 2 ]; then
      TARGET_TYPE="pod"
      echo "Selected to monitor pods"
      return 0
    else
      echo "Invalid selection. Please try again."
    fi
  done
}

# Function to select a deployment
select_deployment() {
  while true; do
    echo "==== SELECT DEPLOYMENT ===="
    if [ "$SELECTED_NS" == "all" ]; then
      echo "Since 'All namespaces' is selected, you can monitor all deployments."
      echo "0) All deployments"
      echo "b) Back to target type selection"
      
      read -p "Select option (0 for all, or 'b' for back): " DEP_CHOICE
      
      if [ "$DEP_CHOICE" = "b" ] || [ "$DEP_CHOICE" = "back" ]; then
        return 1
      elif [ "$DEP_CHOICE" -eq 0 ]; then
        SELECTED_DEP="all"
        echo "Selected all deployments"
        return 0
      else
        echo "Invalid choice. Please try again."
      fi
    else
      echo "Fetching deployments in namespace $SELECTED_NS..."
      DEPLOYMENTS_JSON=$(curl -s "$API_URL/api/deployments?namespace=$SELECTED_NS")
      
      if [ -z "$DEPLOYMENTS_JSON" ]; then
        echo "Failed to fetch deployments. Check if the namespace exists."
        return 1
      fi
      
      # Parse the JSON response to extract deployments
      DEPLOYMENTS=$(echo "$DEPLOYMENTS_JSON" | grep -o '"deployments":\[[^]]*\]' | sed 's/"deployments":\[//;s/\]//' | tr ',' '\n' | sed 's/"//g')
      
      if [ -z "$DEPLOYMENTS" ]; then
        echo "No deployments found in namespace $SELECTED_NS."
        echo "Would you like to monitor all deployments instead?"
        echo "y) Yes, monitor all deployments"
        echo "n) No, go back to namespace selection"
        echo "b) Back to target type selection"
        
        read -p "Select option (y, n, or 'b' for back): " ALL_DEPS
        
        if [ "$ALL_DEPS" = "b" ] || [ "$ALL_DEPS" = "back" ]; then
          return 1
        elif [[ "$ALL_DEPS" =~ ^[Yy] ]]; then
          SELECTED_DEP="all"
          return 0
        else
          return 1
        fi
      fi
      
      echo "Available deployments in $SELECTED_NS:"
      echo "0) All deployments"
      echo "b) Back to target type selection"
      i=1
      for dep in $DEPLOYMENTS; do
        echo "$i) $dep"
        i=$((i+1))
      done
      
      read -p "Select a deployment (number, or 'b' for back): " DEP_CHOICE
      
      if [ "$DEP_CHOICE" = "b" ] || [ "$DEP_CHOICE" = "back" ]; then
        return 1
      elif [ "$DEP_CHOICE" -eq 0 ]; then
        SELECTED_DEP="all"
        echo "Selected all deployments"
        return 0
      else
        SELECTED_DEP=$(echo "$DEPLOYMENTS" | sed -n "${DEP_CHOICE}p")
        if [ -n "$SELECTED_DEP" ]; then
          echo "Selected deployment: $SELECTED_DEP"
          return 0
        else
          echo "Invalid selection. Please try again."
        fi
      fi
    fi
  done
}

# Function to select a pod
select_pod() {
  while true; do
    echo "==== SELECT POD ===="
    if [ "$SELECTED_NS" == "all" ]; then
      echo "Since 'All namespaces' is selected, we can't select individual pods."
      echo "Selecting all pods across all namespaces."
      echo "0) All pods"
      echo "b) Back to target type selection"
      
      read -p "Select option (0 for all, or 'b' for back): " POD_CHOICE
      
      if [ "$POD_CHOICE" = "b" ] || [ "$POD_CHOICE" = "back" ]; then
        return 1
      elif [ "$POD_CHOICE" -eq 0 ]; then
        SELECTED_POD="all"
        return 0
      else
        echo "Invalid selection. Please try again."
      fi
    else
      echo "Fetching pods in namespace $SELECTED_NS..."
      PODS=$(kubectl get pods -n $SELECTED_NS -o jsonpath='{.items[*].metadata.name}')
      
      if [ -z "$PODS" ]; then
        echo "No pods found in namespace $SELECTED_NS."
        echo "Please select another namespace."
        return 1
      fi
      
      echo "Available pods in $SELECTED_NS:"
      echo "0) All pods"
      echo "b) Back to target type selection"
      i=1
      for pod in $PODS; do
        echo "$i) $pod"
        i=$((i+1))
      done
      
      read -p "Select a pod (number, or 'b' for back): " POD_CHOICE
      
      if [ "$POD_CHOICE" = "b" ] || [ "$POD_CHOICE" = "back" ]; then
        return 1
      elif [ "$POD_CHOICE" -eq 0 ]; then
        SELECTED_POD="all"
        echo "Selected all pods"
        return 0
      else
        SELECTED_POD=$(echo "$PODS" | tr ' ' '\n' | sed -n "${POD_CHOICE}p")
        if [ -n "$SELECTED_POD" ]; then
          echo "Selected pod: $SELECTED_POD"
          return 0
        else
          echo "Invalid selection. Please try again."
        fi
      fi
    fi
  done
}

# Function to update configuration for deployments
update_deployment_config() {
  echo "==== UPDATING CONFIGURATION ===="
  
  # Ask for confirmation
  echo "Confirm monitor settings:"
  echo "Namespace: $SELECTED_NS"
  echo "Deployment: $SELECTED_DEP"
  echo "c) Confirm and update"
  echo "b) Back to deployment selection"
  
  read -p "Select option (c to confirm, 'b' for back): " CONFIRM
  
  if [ "$CONFIRM" = "b" ] || [ "$CONFIRM" = "back" ]; then
    return 1
  fi
  
  # Simpler configuration update that should work with existing API
  CONFIG="{\"namespaces\":[\"$SELECTED_NS\"],\"deployments\":[\"$SELECTED_DEP\"]}"
  
  RESPONSE=$(curl -s -X POST "$API_URL/api/config" \
    -H "Content-Type: application/json" \
    -d "$CONFIG")
  
  if echo "$RESPONSE" | grep -q '"status":"success"'; then
    echo "Configuration updated successfully!"
    echo "Now monitoring namespace: $SELECTED_NS, deployment: $SELECTED_DEP"
  else
    echo "Failed to update configuration. Trying alternative format..."
    
    # Try alternative format if the first one fails
    CONFIG="{\"namespaces\":[\"$SELECTED_NS\"],\"deployments\":[\"$SELECTED_DEP\"],\"error_patterns\":[\"error\",\"exception\",\"fail\",\"critical\"]}"
    
    RESPONSE=$(curl -s -X POST "$API_URL/api/config" \
      -H "Content-Type: application/json" \
      -d "$CONFIG")
      
    if echo "$RESPONSE" | grep -q '"status":"success"'; then
      echo "Configuration updated successfully!"
      echo "Now monitoring namespace: $SELECTED_NS, deployment: $SELECTED_DEP"
    else
      echo "Failed to update configuration:"
      echo "$RESPONSE"
      return 1
    fi
  fi
  
  return 0
}

# Function to update configuration for pods
update_pod_config() {
  echo "==== UPDATING CONFIGURATION ===="
  
  # Ask for confirmation
  echo "Confirm monitor settings:"
  echo "Namespace: $SELECTED_NS"
  echo "Pod: $SELECTED_POD"
  echo "c) Confirm and update"
  echo "b) Back to pod selection"
  
  read -p "Select option (c to confirm, 'b' for back): " CONFIRM
  
  if [ "$CONFIRM" = "b" ] || [ "$CONFIRM" = "back" ]; then
    return 1
  fi
  
  # For pods, use the deployments approach since that's what the backend supports
  if [ "$SELECTED_POD" == "all" ]; then
    CONFIG="{\"namespaces\":[\"$SELECTED_NS\"],\"deployments\":[\"all\"]}"
    echo "Monitoring all pods in namespace: $SELECTED_NS"
  else
    # Note: This is a workaround since the backend doesn't explicitly support pods
    # We're setting deployments to "all" to monitor all deployments in the namespace
    # which effectively monitors all pods
    CONFIG="{\"namespaces\":[\"$SELECTED_NS\"],\"deployments\":[\"all\"]}"
    echo "Monitoring pod: $SELECTED_POD in namespace: $SELECTED_NS"
    echo "(Note: Currently monitoring all pods in the namespace. Check for $SELECTED_POD in notifications.)"
  fi
  
  RESPONSE=$(curl -s -X POST "$API_URL/api/config" \
    -H "Content-Type: application/json" \
    -d "$CONFIG")
  
  if echo "$RESPONSE" | grep -q '"status":"success"'; then
    echo "Configuration updated successfully!"
  else
    echo "Failed to update configuration:"
    echo "$RESPONSE"
    return 1
  fi
  
  return 0
}

# Function to trigger an immediate check
trigger_check() {
  echo "==== TRIGGERING LOG CHECK ===="
  
  echo "Triggering an immediate log check..."
  RESPONSE=$(curl -s -X POST "$API_URL/api/check-now")
  
  if echo "$RESPONSE" | grep -q '"status":"success"'; then
    echo "Log check triggered successfully!"
    echo "Any errors found will be sent to Slack automatically."
  else
    echo "Failed to trigger log check:"
    echo "$RESPONSE"
    return 1
  fi
}

# Function to test Slack notification
test_slack() {
  echo "==== TESTING SLACK NOTIFICATION ===="
  
  echo "Sending test notification to Slack..."
  RESPONSE=$(curl -s -X POST "$API_URL/api/test-notification")
  
  if echo "$RESPONSE" | grep -q '"status":"success"'; then
    echo "Test notification sent successfully!"
    echo "Check your Slack channel for the notification."
  else
    echo "Failed to send test notification:"
    echo "$RESPONSE"
    return 1
  fi
}

# Function to show logs for a pod without following
show_pod_logs() {
  while true; do
    echo "==== SELECT NAMESPACE ===="
    echo "Fetching available namespaces..."
    
    NAMESPACES_JSON=$(curl -s "$API_URL/api/namespaces")
    NAMESPACES=$(echo "$NAMESPACES_JSON" | grep -o '"namespaces":\[[^]]*\]' | sed 's/"namespaces":\[//;s/\]//' | tr ',' '\n' | sed 's/"//g')
    
    echo "Available namespaces:"
    i=1
    echo "b) Back to main menu"
    for ns in $NAMESPACES; do
      echo "$i) $ns"
      i=$((i+1))
    done
    
    read -p "Select a namespace (number, or 'b' for back): " NS_CHOICE
    
    if [ "$NS_CHOICE" = "b" ] || [ "$NS_CHOICE" = "back" ]; then
      return 1
    fi
    
    SELECTED_NS=$(echo "$NAMESPACES" | sed -n "${NS_CHOICE}p")
    if [ -z "$SELECTED_NS" ]; then
      echo "Invalid selection. Please try again."
      continue
    fi
    echo "Selected namespace: $SELECTED_NS"
    
    while true; do
      echo "==== SELECT POD ===="
      echo "Fetching pods in namespace $SELECTED_NS..."
      PODS=$(kubectl get pods -n $SELECTED_NS -o jsonpath='{.items[*].metadata.name}')
      
      if [ -z "$PODS" ]; then
        echo "No pods found in namespace $SELECTED_NS."
        break  # Go back to namespace selection
      fi
      
      echo "Available pods in $SELECTED_NS:"
      echo "b) Back to namespace selection"
      i=1
      for pod in $PODS; do
        echo "$i) $pod"
        i=$((i+1))
      done
      
      read -p "Select a pod (number, or 'b' for back): " POD_CHOICE
      
      if [ "$POD_CHOICE" = "b" ] || [ "$POD_CHOICE" = "back" ]; then
        break  # Go back to namespace selection
      fi
      
      SELECTED_POD=$(echo "$PODS" | tr ' ' '\n' | sed -n "${POD_CHOICE}p")
      if [ -z "$SELECTED_POD" ]; then
        echo "Invalid selection. Please try again."
        continue
      fi
      echo "Selected pod: $SELECTED_POD"
      
      while true; do
        echo "==== SELECT CONTAINER ===="
        CONTAINERS=$(kubectl get pod $SELECTED_POD -n $SELECTED_NS -o jsonpath='{.spec.containers[*].name}')
        
        if [ -z "$CONTAINERS" ]; then
          echo "No containers found in pod $SELECTED_POD."
          break  # Go back to pod selection
        fi
        
        # If there's only one container, select it automatically
        CONTAINER_COUNT=$(echo "$CONTAINERS" | wc -w)
        if [ "$CONTAINER_COUNT" -eq 1 ]; then
          SELECTED_CONTAINER=$CONTAINERS
          echo "Automatically selected container: $SELECTED_CONTAINER"
        else
          echo "Available containers in $SELECTED_POD:"
          echo "b) Back to pod selection"
          i=1
          for container in $CONTAINERS; do
            echo "$i) $container"
            i=$((i+1))
          done
          
          read -p "Select a container (number, or 'b' for back): " CONTAINER_CHOICE
          
          if [ "$CONTAINER_CHOICE" = "b" ] || [ "$CONTAINER_CHOICE" = "back" ]; then
            break  # Go back to pod selection
          fi
          
          SELECTED_CONTAINER=$(echo "$CONTAINERS" | tr ' ' '\n' | sed -n "${CONTAINER_CHOICE}p")
          if [ -z "$SELECTED_CONTAINER" ]; then
            echo "Invalid selection. Please try again."
            continue
          fi
          echo "Selected container: $SELECTED_CONTAINER"
        fi
        
        while true; do
          echo "==== LOG OPTIONS ===="
          echo "1) Show most recent logs (last 10 minutes)"
          echo "2) Show logs from last hour"
          echo "3) Show logs since specific time"
          echo "4) Show only last N lines"
          echo "b) Back to container selection"
          
          read -p "Select an option (1-4, or 'b' for back): " LOG_OPTION
          
          if [ "$LOG_OPTION" = "b" ] || [ "$LOG_OPTION" = "back" ]; then
            break  # Go back to container selection
          fi
          
          LOG_CMD="kubectl logs $SELECTED_POD -c $SELECTED_CONTAINER -n $SELECTED_NS"
          
          case $LOG_OPTION in
            1)
              # Last 10 minutes
              LOG_CMD="$LOG_CMD --since=10m"
              ;;
            2)
              # Last hour
              LOG_CMD="$LOG_CMD --since=1h"
              ;;
            3)
              # Since specific time
              echo "Enter time (e.g. '15m' for 15 minutes, '2h' for 2 hours, or 'b' for back):"
              read TIME_SINCE
              
              if [ "$TIME_SINCE" = "b" ] || [ "$TIME_SINCE" = "back" ]; then
                continue  # Go back to log options
              fi
              
              LOG_CMD="$LOG_CMD --since=$TIME_SINCE"
              ;;
            4)
              # Last N lines
              echo "Enter number of lines (or 'b' for back):"
              read NUM_LINES
              
              if [ "$NUM_LINES" = "b" ] || [ "$NUM_LINES" = "back" ]; then
                continue  # Go back to log options
              fi
              
              LOG_CMD="$LOG_CMD --tail=$NUM_LINES"
              ;;
            *)
              echo "Invalid option. Please try again."
              continue
              ;;
          esac
          
          echo "==== CONTAINER LOGS ===="
          echo "Retrieving logs for $SELECTED_POD/$SELECTED_CONTAINER in namespace $SELECTED_NS..."
          echo "-------------------------------------"
          
          # Execute without -f (follow) so it will complete and return to prompt
          eval $LOG_CMD
          echo "-------------------------------------"
          echo "Log retrieval complete."
          echo "1) Show more logs with different options"
          echo "2) Select a different pod/container"
          echo "3) Back to main menu"
          read -p "Select an option (1-3): " NEXT_STEP
          case $NEXT_STEP in
            1)
              continue  # Stay in log options
              ;;
            2)
              break 3  # Go back to pod selection
              ;;
            3|*)
              return 0  # Back to main menu
              ;;
          esac
        done
      done
    done
  done
}

# Function to show errors for a pod
show_pod_errors() {
  while true; do
    echo "==== SELECT NAMESPACE ===="
    echo "Fetching available namespaces..."
    
    NAMESPACES_JSON=$(curl -s "$API_URL/api/namespaces")
    NAMESPACES=$(echo "$NAMESPACES_JSON" | grep -o '"namespaces":\[[^]]*\]' | sed 's/"namespaces":\[//;s/\]//' | tr ',' '\n' | sed 's/"//g')
    
    echo "Available namespaces:"
    echo "b) Back to main menu"
    i=1
    for ns in $NAMESPACES; do
      echo "$i) $ns"
      i=$((i+1))
    done
    
    read -p "Select a namespace (number, or 'b' for back): " NS_CHOICE
    
    if [ "$NS_CHOICE" = "b" ] || [ "$NS_CHOICE" = "back" ]; then
      return 1
    fi
    
    SELECTED_NS=$(echo "$NAMESPACES" | sed -n "${NS_CHOICE}p")
    if [ -z "$SELECTED_NS" ]; then
      echo "Invalid selection. Please try again."
      continue
    fi
    echo "Selected namespace: $SELECTED_NS"
    
    while true; do
      echo "==== SELECT POD ===="
      echo "Fetching pods in namespace $SELECTED_NS..."
      PODS=$(kubectl get pods -n $SELECTED_NS -o jsonpath='{.items[*].metadata.name}')
      
      if [ -z "$PODS" ]; then
        echo "No pods found in namespace $SELECTED_NS."
        break  # Go back to namespace selection
      fi
      
      echo "Available pods in $SELECTED_NS:"
      echo "b) Back to namespace selection"
      i=1
      for pod in $PODS; do
        echo "$i) $pod"
        i=$((i+1))
      done
      
      read -p "Select a pod (number, or 'b' for back): " POD_CHOICE
      
      if [ "$POD_CHOICE" = "b" ] || [ "$POD_CHOICE" = "back" ]; then
        break  # Go back to namespace selection
      fi
      
      SELECTED_POD=$(echo "$PODS" | tr ' ' '\n' | sed -n "${POD_CHOICE}p")
      if [ -z "$SELECTED_POD" ]; then
        echo "Invalid selection. Please try again."
        continue
      fi
      echo "Selected pod: $SELECTED_POD"
      
      while true; do
        echo "==== SELECT CONTAINER ===="
        CONTAINERS=$(kubectl get pod $SELECTED_POD -n $SELECTED_NS -o jsonpath='{.spec.containers[*].name}')
        
        if [ -z "$CONTAINERS" ]; then
          echo "No containers found in pod $SELECTED_POD."
          break  # Go back to pod selection
        fi
        
        # If there's only one container, select it automatically
        CONTAINER_COUNT=$(echo "$CONTAINERS" | wc -w)
        if [ "$CONTAINER_COUNT" -eq 1 ]; then
          SELECTED_CONTAINER=$CONTAINERS
          echo "Automatically selected container: $SELECTED_CONTAINER"
        else
          echo "Available containers in $SELECTED_POD:"
          echo "b) Back to pod selection"
          i=1
          for container in $CONTAINERS; do
            echo "$i) $container"
            i=$((i+1))
          done
          
          read -p "Select a container (number, or 'b' for back): " CONTAINER_CHOICE
          
          if [ "$CONTAINER_CHOICE" = "b" ] || [ "$CONTAINER_CHOICE" = "back" ]; then
            break  # Go back to pod selection
          fi
          
          SELECTED_CONTAINER=$(echo "$CONTAINERS" | tr ' ' '\n' | sed -n "${CONTAINER_CHOICE}p")
          if [ -z "$SELECTED_CONTAINER" ]; then
            echo "Invalid selection. Please try again."
            continue
          fi
          echo "Selected container: $SELECTED_CONTAINER"
        fi
        
        while true; do
          echo "==== ERROR PATTERNS TO SEARCH ===="
          echo "1) Use default patterns (error, exception, fail, critical)"
          echo "2) Enter custom pattern"
          echo "b) Back to container selection"
          
          read -p "Select an option (1-2, or 'b' for back): " PATTERN_OPTION
          
          if [ "$PATTERN_OPTION" = "b" ] || [ "$PATTERN_OPTION" = "back" ]; then
            break  # Go back to container selection
          fi
          
          if [ "$PATTERN_OPTION" -eq 1 ]; then
            PATTERN="error|exception|fail|critical"
          elif [ "$PATTERN_OPTION" -eq 2 ]; then
            echo "Enter custom pattern (or 'b' for back):"
            read CUSTOM_PATTERN
            
            if [ "$CUSTOM_PATTERN" = "b" ] || [ "$CUSTOM_PATTERN" = "back" ]; then
              continue  # Go back to pattern selection
            fi
            
            PATTERN="$CUSTOM_PATTERN"
          else
            echo "Invalid option. Please try again."
            continue
          fi
          
          echo "==== LOG TIMEFRAME ===="
          echo "1) Last 10 minutes"
          echo "2) Last hour"
          echo "3) Last 24 hours"
          echo "4) Custom timeframe"
          echo "b) Back to pattern selection"
          
          read -p "Select an option (1-4, or 'b' for back): " TIME_OPTION
          
          if [ "$TIME_OPTION" = "b" ] || [ "$TIME_OPTION" = "back" ]; then
            continue  # Go back to pattern selection
          fi
          
          TIME_SINCE="10m"  # Default
          
          case $TIME_OPTION in
            1)
              TIME_SINCE="10m"
              ;;
            2)
              TIME_SINCE="1h"
              ;;
            3)
              TIME_SINCE="24h"
              ;;
            4)
              echo "Enter custom timeframe (e.g. '15m', '2h', '3d', or 'b' for back):"
              read CUSTOM_TIME
              
              if [ "$CUSTOM_TIME" = "b" ] || [ "$CUSTOM_TIME" = "back" ]; then
                continue  # Go back to time selection
              fi
              
              TIME_SINCE="$CUSTOM_TIME"
              ;;
            *)
              echo "Invalid option. Using default (10 minutes)."
              ;;
          esac
          
          echo "==== ERRORS IN LOGS ===="
          echo "Showing errors for $SELECTED_POD/$SELECTED_CONTAINER in namespace $SELECTED_NS..."
          echo "Searching for pattern: $PATTERN"
          echo "Timeframe: Last $TIME_SINCE"
          echo "-------------------------------------"
          
          # Get logs and filter for errors
          ERROR_OUTPUT=$(kubectl logs $SELECTED_POD -c $SELECTED_CONTAINER -n $SELECTED_NS --since=$TIME_SINCE | grep -i -E "$PATTERN" --color=always)
          echo "$ERROR_OUTPUT"
          
          ERROR_COUNT=$(echo "$ERROR_OUTPUT" | grep -v '^$' | wc -l)
          echo "-------------------------------------"
          echo "Found $ERROR_COUNT matching error(s)"
          echo "1) Change search pattern or timeframe"
          echo "2) Select a different pod/container"
          echo "3) Back to main menu"
          read -p "Select an option (1-3): " NEXT_STEP
                case $NEXT_STEP in
                    1)
                    continue  # Stay in pattern selection
                    ;;
                    2)
                    break 3  # Go back to pod selection directly
                    ;;
                    3|*)
                    return 0  # Back to main menu
                    ;;
                esac
                done
            done
            done
        done
        }



# Function to display current configuration
show_config() {
echo "==== CURRENT CONFIGURATION ===="

CONFIG_JSON=$(curl -s "$API_URL/api/config")
if [ -z "$CONFIG_JSON" ]; then
    echo "Failed to fetch configuration."
    return 1
fi

# Extract and display the config
NAMESPACES=$(echo "$CONFIG_JSON" | grep -o '"namespaces":\[[^]]*\]' | sed 's/"namespaces":\[//;s/\]//' | tr ',' '\n' | sed 's/"//g')
DEPLOYMENTS=$(echo "$CONFIG_JSON" | grep -o '"deployments":\[[^]]*\]' | sed 's/"deployments":\[//;s/\]//' | tr ',' '\n' | sed 's/"//g')
ERROR_PATTERNS=$(echo "$CONFIG_JSON" | grep -o '"error_patterns":\[[^]]*\]' | sed 's/"error_patterns":\[//;s/\]//' | tr ',' '\n' | sed 's/"//g')
CHECK_INTERVAL=$(echo "$CONFIG_JSON" | grep -o '"check_interval":[0-9]*' | sed 's/"check_interval"://')
LOG_MINUTES=$(echo "$CONFIG_JSON" | grep -o '"log_minutes":[0-9]*' | sed 's/"log_minutes"://')
IS_RUNNING=$(echo "$CONFIG_JSON" | grep -o '"is_running":\(true\|false\)' | sed 's/"is_running"://')

echo "Monitor status: $([ "$IS_RUNNING" == "true" ] && echo "Running" || echo "Stopped")"
echo "Monitoring namespaces: $NAMESPACES"
echo "Monitoring deployments: $DEPLOYMENTS"
echo "Error patterns: $ERROR_PATTERNS"
echo "Check interval: $CHECK_INTERVAL seconds"
echo "Log minutes: $LOG_MINUTES"

# read -p "Press Enter to return to main menu..." 
return 0
}

# Function to display help
show_help() {
echo "==== KUBERNETES LOG MONITOR CLI ===="
echo "Available commands:"
echo "  select    - Select namespace and deployment/pod to monitor"
echo "  check     - Trigger an immediate log check"
echo "  test      - Send a test notification to Slack"
echo "  logs      - Show logs for a pod"
echo "  errors    - Show errors in pod logs"
echo "  config    - Show current configuration"
echo "  start     - Start monitoring"
echo "  stop      - Stop monitoring"
echo "  help      - Show this help message"
echo "  exit      - Exit the CLI"

# read -p "Press Enter to return to main menu..." 
return 0
}

# Interactive shell
echo "=== Kubernetes Log Monitor Interactive CLI ==="

# Initialize check variables
check_api || exit 1

echo "Type 'help' for available commands or 'exit' to quit"

while true; do
echo ""
read -p "log-monitor> " CMD

case "$CMD" in
    select)
    # Start the selection chain with back options
    if select_namespace; then
        if select_target_type; then
        if [ "$TARGET_TYPE" == "deployment" ]; then
            if select_deployment; then
            update_deployment_config
            fi
        else
            if select_pod; then
            update_pod_config
            fi
        fi
        fi
    fi
    ;;
    check)
    trigger_check
    ;;
    test)
    test_slack
    ;;
    logs)
    show_pod_logs
    ;;
    errors)
    show_pod_errors
    ;;
    config)
    show_config
    ;;
    start)
    curl -s -X POST "$API_URL/api/start" > /dev/null && echo "Monitoring started"
    ;;
    stop)
    curl -s -X POST "$API_URL/api/stop" > /dev/null && echo "Monitoring stopped"
    ;;
    help)
    show_help
    ;;
    exit|quit)
    echo "Exiting..."
    exit 0
    ;;
    "")
    # Do nothing for empty input
    ;;
    *)
    echo "Unknown command: $CMD"
    echo "Type 'help' for available commands"
    ;;
esac
done
