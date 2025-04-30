import os
import time
import json
import requests
import threading
import traceback
from datetime import datetime, timedelta
from kubernetes import client, config
from flask import Flask, request, jsonify
from flask_cors import CORS

# Load Kubernetes configuration
try:
    config.load_incluster_config()
    print("Loaded in-cluster config")
except:
    print("Failed to load in-cluster config, trying local config")
    config.load_kube_config()

# Environment configuration
SLACK_WEBHOOK_URL = "https://hooks.slack.com/services/YOUR/WEBHOOK/URL" # Replace with your actual webhook URL
DEFAULT_NAMESPACES = os.environ.get("DEFAULT_NAMESPACES", "default").split(",")
DEFAULT_DEPLOYMENTS = os.environ.get("DEFAULT_DEPLOYMENTS", "all").split(",")
ERROR_PATTERNS = os.environ.get("ERROR_PATTERNS", "error,exception,fail,critical").split(",")
CHECK_INTERVAL = int(os.environ.get("CHECK_INTERVAL", "300"))  # 5 minutes in seconds
LOG_MINUTES = int(os.environ.get("LOG_MINUTES", "5"))  # Last 5 minutes of logs
MAX_ERROR_LINES = int(os.environ.get("MAX_ERROR_LINES", "20"))  # Max lines in notification
DEBUG = os.environ.get("DEBUG", "false").lower() == "true"
INTERACTIVE_MODE = os.environ.get("INTERACTIVE_MODE", "false").lower() == "true"
API_PORT = int(os.environ.get("API_PORT", "8080"))

# Runtime configuration (can be updated via API)
config_lock = threading.Lock()
runtime_config = {
    "namespaces": DEFAULT_NAMESPACES.copy(),
    "deployments": DEFAULT_DEPLOYMENTS.copy(),
    "error_patterns": ERROR_PATTERNS.copy(),
    "check_interval": CHECK_INTERVAL,
    "log_minutes": LOG_MINUTES,
    "max_error_lines": MAX_ERROR_LINES,
    "is_running": True
}

# Flask app for API
app = Flask(__name__)
CORS(app)

def log_debug(message):
    """Print debug message if DEBUG is enabled"""
    if DEBUG:
        print(f"[DEBUG] {message}")

def get_all_namespaces():
    """Get list of all namespaces in the cluster"""
    try:
        v1 = client.CoreV1Api()
        namespaces = v1.list_namespace()
        return [ns.metadata.name for ns in namespaces.items]
    except Exception as e:
        print(f"Error getting namespaces: {e}")
        return []

def get_deployments_in_namespace(namespace):
    """Get list of all deployments in a namespace"""
    try:
        apps_v1 = client.AppsV1Api()
        deployments = apps_v1.list_namespaced_deployment(namespace=namespace)
        return [dep.metadata.name for dep in deployments.items]
    except Exception as e:
        print(f"Error getting deployments in namespace {namespace}: {e}")
        return []

def get_pods_for_deployment(namespace, deployment_name):
    """Get pods that belong to a specific deployment"""
    try:
        apps_v1 = client.AppsV1Api()
        deployment = apps_v1.read_namespaced_deployment(name=deployment_name, namespace=namespace)
        
        # Get the label selector from the deployment
        selector = deployment.spec.selector.match_labels
        selector_string = ",".join([f"{k}={v}" for k, v in selector.items()])
        
        # Get pods with this label selector
        v1 = client.CoreV1Api()
        pods = v1.list_namespaced_pod(namespace=namespace, label_selector=selector_string)
        return pods.items
    except Exception as e:
        print(f"Error getting pods for deployment {deployment_name} in namespace {namespace}: {e}")
        return []

def get_logs_since(pod_name, container_name, namespace, minutes=5):
    """Get logs from the specified pod and container for the last X minutes"""
    try:
        v1 = client.CoreV1Api()
        since_seconds = int(minutes * 60)
        log_debug(f"Getting logs for pod {pod_name}, container {container_name}, namespace {namespace}, last {minutes} minutes")
        
        logs = v1.read_namespaced_pod_log(
            name=pod_name,
            namespace=namespace,
            container=container_name,
            since_seconds=since_seconds
        )
        return logs
    except Exception as e:
        print(f"Error getting logs for pod {pod_name}, container {container_name}: {e}")
        return ""

def contains_error(log_text):
    """Check if log contains any error patterns"""
    if not log_text:
        return False, None
        
    with config_lock:
        patterns = runtime_config["error_patterns"]
        
    log_lower = log_text.lower()
    
    for pattern in patterns:
        pattern_lower = pattern.lower()
        if pattern_lower in log_lower:
            log_debug(f"Found error pattern: {pattern}")
            # Find the line with the error pattern
            log_lines = log_text.split('\n')
            error_lines = [line for line in log_lines if pattern_lower in line.lower()]
            return True, error_lines
    
    return False, None

def get_stack_trace(log_text, error_lines):
    """Extract stack trace surrounding error lines"""
    if not log_text or not error_lines:
        return ""
        
    log_lines = log_text.split('\n')
    trace_lines = []
    
    # For each error line, collect surrounding context
    for error_line in error_lines:
        try:
            # Find the index of the error line
            error_index = log_lines.index(error_line)
            
            # Get up to 10 lines before and after
            start_index = max(0, error_index - 10)
            end_index = min(len(log_lines), error_index + 10)
            
            # Add trace with context
            trace_lines.extend([
                "--- ERROR CONTEXT ---",
                f"Error at line {error_index}:",
                *log_lines[start_index:end_index],
                "-------------------"
            ])
        except ValueError:
            # Error line might have been altered or not found
            trace_lines.append(f"ERROR CONTEXT NOT FOUND FOR: {error_line}")
    
    return '\n'.join(trace_lines)

def send_slack_notification(pod_name, container_name, namespace, error_logs, trace_logs=None):
    """Send error notification to Slack with error details and trace"""
    if not SLACK_WEBHOOK_URL:
        print("Slack webhook URL not configured. Skipping notification.")
        return False
    
    # Prepare error logs section
    error_section = {
        "type": "section",
        "text": {
            "type": "mrkdwn",
            "text": f"*Error Logs:*\n```{error_logs[:1000]}```"
        }
    }
    
    # Prepare blocks array with header and fields
    blocks = [
        {
            "type": "header",
            "text": {
                "type": "plain_text",
                "text": "🚨 Kubernetes Error Alert 🚨"
            }
        },
        {
            "type": "section",
            "fields": [
                {
                    "type": "mrkdwn",
                    "text": f"*Pod:* {pod_name}"
                },
                {
                    "type": "mrkdwn",
                    "text": f"*Container:* {container_name}"
                },
                {
                    "type": "mrkdwn",
                    "text": f"*Namespace:* {namespace}"
                },
                {
                    "type": "mrkdwn",
                    "text": f"*Time:* {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
                }
            ]
        },
        error_section
    ]
    
    # Add trace logs section if available
    if trace_logs:
        trace_text = trace_logs[:2000]  # Limit size to avoid Slack message size limits
        blocks.append({
            "type": "section",
            "text": {
                "type": "mrkdwn",
                "text": f"*Stack Trace:*\n```{trace_text}```"
            }
        })
    
    message = {
        "blocks": blocks
    }
    
    try:
        log_debug(f"Sending Slack notification for {pod_name}/{container_name}")
        response = requests.post(
            SLACK_WEBHOOK_URL,
            data=json.dumps(message),
            headers={"Content-Type": "application/json"}
        )
        if response.status_code == 200:
            log_debug("Slack notification sent successfully")
        else:
            log_debug(f"Slack API error: {response.status_code} - {response.text}")
        return response.status_code == 200
    except Exception as e:
        print(f"Error sending Slack notification: {e}")
        return False

def check_deployment_for_errors(namespace, deployment_name):
    """Check all pods in a specific deployment for errors and send notifications immediately"""
    pods = get_pods_for_deployment(namespace, deployment_name)
    
    if not pods:
        print(f"No pods found for deployment {deployment_name} in namespace {namespace}")
        return
    
    print(f"Checking {len(pods)} pods for deployment {deployment_name} in namespace {namespace}")
    
    for pod in pods:
        pod_name = pod.metadata.name
        
        # Skip pods that are not in Running state
        if pod.status.phase != 'Running':
            log_debug(f"Skipping pod {pod_name} in phase {pod.status.phase}")
            continue
        
        # For each container in the pod
        for container in pod.spec.containers:
            container_name = container.name
            
            with config_lock:
                log_minutes = runtime_config["log_minutes"]
                max_error_lines = runtime_config["max_error_lines"]
            
            # Get all logs for the period
            logs = get_logs_since(pod_name, container_name, namespace, log_minutes)
            
            # Check if logs contain errors
            has_errors, error_lines = contains_error(logs)
            
            if has_errors and error_lines:
                print(f"Found errors in pod {pod_name}, container {container_name}")
                
                # Extract error lines for more focused notification
                error_text = '\n'.join(error_lines[:max_error_lines])
                
                # Get full trace with context
                trace_logs = get_stack_trace(logs, error_lines)
                
                # Send notification immediately
                send_result = send_slack_notification(
                    pod_name, 
                    container_name, 
                    namespace, 
                    error_text,
                    trace_logs
                )
                
                if send_result:
                    print(f"Successfully sent Slack notification for {pod_name}/{container_name}")
                else:
                    print(f"Failed to send Slack notification for {pod_name}/{container_name}")

def check_all_deployments_in_namespace(namespace):
    """Check all deployments in a namespace"""
    with config_lock:
        deployments = runtime_config["deployments"]
        
    # Check if monitoring all deployments
    if "all" in deployments:
        deployment_list = get_deployments_in_namespace(namespace)
        for deployment_name in deployment_list:
            check_deployment_for_errors(namespace, deployment_name)
    else:
        # Check only specified deployments
        for deployment_name in deployments:
            check_deployment_for_errors(namespace, deployment_name)

def check_all_namespaces():
    """Check all specified namespaces for errors"""
    with config_lock:
        namespaces = runtime_config["namespaces"]
        
    # Check all namespaces if specified
    if "all" in namespaces:
        namespace_list = get_all_namespaces()
        for namespace in namespace_list:
            check_all_deployments_in_namespace(namespace)
    else:
        # Check only specified namespaces
        for namespace in namespaces:
            check_all_deployments_in_namespace(namespace)

def monitoring_loop():
    """Main monitoring loop that runs continuously every 5 minutes"""
    print(f"Starting Kubernetes log monitor...")
    print(f"Initial configuration:")
    print(f"  - Monitoring namespaces: {', '.join(runtime_config['namespaces'])}")
    print(f"  - Monitoring deployments: {', '.join(runtime_config['deployments'])}")
    print(f"  - Looking for error patterns: {', '.join(runtime_config['error_patterns'])}")
    print(f"  - Checking logs from the last {runtime_config['log_minutes']} minutes")
    print(f"  - Running every {runtime_config['check_interval']} seconds")
    print(f"  - Slack notifications configured: {'Yes' if SLACK_WEBHOOK_URL else 'No'}")
    
    while True:
        try:
            with config_lock:
                is_running = runtime_config["is_running"]
                check_interval = runtime_config["check_interval"]
                
            if not is_running:
                print("Monitoring paused. Sleeping...")
                time.sleep(10)
                continue
                
            start_time = time.time()
            print(f"Starting check at {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}")
            
            # Run the check across all namespaces
            check_all_namespaces()
            
            # Calculate sleep time to maintain consistent check interval
            elapsed = time.time() - start_time
            sleep_time = max(1, check_interval - elapsed)
            print(f"Check completed in {elapsed:.2f}s. Next check in {sleep_time:.2f}s...")
            time.sleep(sleep_time)
        except Exception as e:
            # Catch any unhandled exceptions in the monitoring loop
            error_trace = traceback.format_exc()
            print(f"Error in monitoring loop: {e}")
            print(error_trace)
            
            # Try to send notification about the monitor itself
            if SLACK_WEBHOOK_URL:
                try:
                    message = {
                        "blocks": [
                            {
                                "type": "header",
                                "text": {
                                    "type": "plain_text",
                                    "text": "⚠️ Kubernetes Log Monitor Error ⚠️"
                                }
                            },
                            {
                                "type": "section",
                                "text": {
                                    "type": "mrkdwn",
                                    "text": f"*Error:* {str(e)}\n\n*Trace:*\n```{error_trace[:1500]}```"
                                }
                            }
                        ]
                    }
                    
                    requests.post(
                        SLACK_WEBHOOK_URL,
                        data=json.dumps(message),
                        headers={"Content-Type": "application/json"}
                    )
                except:
                    print("Failed to send monitor error notification")
            
            # Sleep for a bit before trying again
            time.sleep(30)

# API Endpoints
@app.route('/api/config', methods=['GET'])
def get_config():
    """Get current monitoring configuration"""
    with config_lock:
        return jsonify(runtime_config)

@app.route('/api/config', methods=['POST'])
def update_config():
    """Update monitoring configuration"""
    try:
        new_config = request.json
        with config_lock:
            for key, value in new_config.items():
                if key in runtime_config:
                    runtime_config[key] = value
        return jsonify({"status": "success", "config": runtime_config})
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 400

@app.route('/api/namespaces', methods=['GET'])
def list_namespaces():
    """List all available namespaces"""
    namespaces = get_all_namespaces()
    return jsonify({"namespaces": namespaces})

@app.route('/api/deployments', methods=['GET'])
def list_deployments():
    """List deployments in a namespace"""
    namespace = request.args.get('namespace', 'default')
    deployments = get_deployments_in_namespace(namespace)
    return jsonify({"namespace": namespace, "deployments": deployments})

@app.route('/api/start', methods=['POST'])
def start_monitoring():
    """Start monitoring"""
    with config_lock:
        runtime_config["is_running"] = True
    return jsonify({"status": "success", "message": "Monitoring started"})

@app.route('/api/stop', methods=['POST'])
def stop_monitoring():
    """Pause monitoring"""
    with config_lock:
        runtime_config["is_running"] = False
    return jsonify({"status": "success", "message": "Monitoring paused"})

@app.route('/api/check-now', methods=['POST'])
def check_now():
    """Trigger an immediate check"""
    threading.Thread(target=check_all_namespaces).start()
    return jsonify({"status": "success", "message": "Check triggered"})

@app.route('/api/test-notification', methods=['POST'])
def test_notification():
    """Send a test notification to Slack"""
    if not SLACK_WEBHOOK_URL:
        return jsonify({"status": "error", "message": "Slack webhook URL not configured"}), 400
    
    try:
        message = {
            "blocks": [
                {
                    "type": "header",
                    "text": {
                        "type": "plain_text",
                        "text": "🧪 Test Notification"
                    }
                },
                {
                    "type": "section",
                    "text": {
                        "type": "mrkdwn",
                        "text": "This is a test notification from the Kubernetes Log Monitor."
                    }
                },
                {
                    "type": "section",
                    "fields": [
                        {
                            "type": "mrkdwn",
                            "text": f"*Time:* {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}"
                        }
                    ]
                }
            ]
        }
        
        response = requests.post(
            SLACK_WEBHOOK_URL,
            data=json.dumps(message),
            headers={"Content-Type": "application/json"}
        )
        
        if response.status_code == 200:
            return jsonify({"status": "success", "message": "Test notification sent"})
        else:
            return jsonify({"status": "error", "message": f"Slack API error: {response.status_code} - {response.text}"}), 400
    except Exception as e:
        return jsonify({"status": "error", "message": str(e)}), 400
def get_pods_in_namespace(namespace):
    """Get list of all pods in a namespace"""
    try:
        v1 = client.CoreV1Api()
        pods = v1.list_namespaced_pod(namespace=namespace)
        return [pod.metadata.name for pod in pods.items]
    except Exception as e:
        print(f"Error getting pods in namespace {namespace}: {e}")
        return []

def check_pod_for_errors(namespace, pod_name):
    """Check a specific pod for errors"""
    try:
        v1 = client.CoreV1Api()
        pod = v1.read_namespaced_pod(name=pod_name, namespace=namespace)
        
        # Skip pods that are not in Running state
        if pod.status.phase != 'Running':
            log_debug(f"Skipping pod {pod_name} in phase {pod.status.phase}")
            return
        
        print(f"Checking pod {pod_name} in namespace {namespace}")
        
        # For each container in the pod
        for container in pod.spec.containers:
            container_name = container.name
            
            with config_lock:
                log_minutes = runtime_config["log_minutes"]
                max_error_lines = runtime_config["max_error_lines"]
            
            # Get logs for the container
            logs = get_logs_since(pod_name, container_name, namespace, log_minutes)
            
            # Check if logs contain errors
            has_errors, error_lines = contains_error(logs)
            
            if has_errors and error_lines:
                print(f"Found errors in pod {pod_name}, container {container_name}")
                
                # Extract error lines for notification
                error_text = '\n'.join(error_lines[:max_error_lines])
                
                # Get trace with context
                trace_logs = get_stack_trace(logs, error_lines)
                
                # Send notification
                send_result = send_slack_notification(
                    pod_name, 
                    container_name, 
                    namespace, 
                    error_text, 
                    trace_logs
                )
                
                if send_result:
                    print(f"Successfully sent Slack notification for {pod_name}/{container_name}")
                else:
                    print(f"Failed to send Slack notification for {pod_name}/{container_name}")
    except Exception as e:
        print(f"Error checking pod {pod_name} in namespace {namespace}: {e}")

# Add this section to your check_all_namespaces() function

def check_all_namespaces():
    """Check all specified namespaces for errors"""
    with config_lock:
        namespaces = runtime_config["namespaces"]
        deployments = runtime_config["deployments"]
        pods = runtime_config.get("pods", [])  # Get pods from config, default to empty list
        
    # Check all namespaces if specified
    if "all" in namespaces:
        namespace_list = get_all_namespaces()
        for namespace in namespace_list:
            # Check deployments in this namespace
            check_all_deployments_in_namespace(namespace)
            
            # If specific pods are configured, check only those
            if pods and pods != ["all"]:
                for pod_name in pods:
                    check_pod_for_errors(namespace, pod_name)
    else:
        # Check only specified namespaces
        for namespace in namespaces:
            # Check deployments in this namespace
            check_all_deployments_in_namespace(namespace)
            
            # If specific pods are configured, check only those
            if pods and pods != ["all"]:
                for pod_name in pods:
                    check_pod_for_errors(namespace, pod_name)
            # If no specific pods but "all pods" is set, check all pods in namespace
            elif "all" in deployments and (not pods or "all" in pods):
                pod_list = get_pods_in_namespace(namespace)
                for pod_name in pod_list:
                    check_pod_for_errors(namespace, pod_name)

# Update runtime_config initialization to include pods
runtime_config = {
    "namespaces": DEFAULT_NAMESPACES.copy(),
    "deployments": DEFAULT_DEPLOYMENTS.copy(),
    "pods": [],  # Add this new line
    "error_patterns": ERROR_PATTERNS.copy(),
    "check_interval": CHECK_INTERVAL,
    "log_minutes": LOG_MINUTES,
    "max_error_lines": MAX_ERROR_LINES,
    "is_running": True
}
@app.route('/')
def index():
    """API root - provide basic info"""
    return jsonify({
        "name": "Kubernetes Log Monitor",
        "version": "1.1.0",
        "status": "running",
        "api_endpoints": [
            "/api/config",
            "/api/namespaces",
            "/api/deployments",
            "/api/start",
            "/api/stop",
            "/api/check-now",
            "/api/test-notification"
        ]
    })

if __name__ == "__main__":
    # Start the monitoring in a separate thread
    monitoring_thread = threading.Thread(target=monitoring_loop, daemon=True)
    monitoring_thread.start()
    
    # Start the API server
    print(f"Starting API server on port {API_PORT}")
    app.run(host='0.0.0.0', port=API_PORT)
