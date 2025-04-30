#!/bin/bash
# This script creates test pods that generate error logs to verify the log monitor

echo "==== LOG MONITOR TEST SCRIPT ===="
echo "This script will create test pods that generate different types of error logs"
echo "to verify your log monitoring system is working correctly."
echo ""

# Function to check if namespace exists
check_namespace() {
    if ! kubectl get namespace "$1" &> /dev/null; then
        echo "[INFO] Creating namespace $1..."
        kubectl create namespace "$1"
    else
        echo "[INFO] Using existing namespace $1."
    fi
}

# Create test namespace
TEST_NAMESPACE="log-monitor-test"
check_namespace $TEST_NAMESPACE

echo "Creating test pods in namespace: $TEST_NAMESPACE"

# Create pod with standard error logs
echo "[INFO] Creating pod with standard ERROR logs..."
kubectl run error-test-pod --image=busybox -n $TEST_NAMESPACE -- \
    /bin/sh -c 'while true; do echo "ERROR: This is a test error message"; sleep 10; done'

# Create pod with exception logs
echo "[INFO] Creating pod with EXCEPTION logs..."
kubectl run exception-test-pod --image=busybox -n $TEST_NAMESPACE -- \
    /bin/sh -c 'while true; do echo "An unexpected EXCEPTION occurred in module test"; sleep 15; done'

# Create pod with failure logs
echo "[INFO] Creating pod with FAILURE logs..."
kubectl run failure-test-pod --image=busybox -n $TEST_NAMESPACE -- \
    /bin/sh -c 'while true; do echo "Operation FAILED: could not process request"; sleep 20; done'

# Create pod with critical logs
echo "[INFO] Creating pod with CRITICAL logs..."
kubectl run critical-test-pod --image=busybox -n $TEST_NAMESPACE -- \
    /bin/sh -c 'while true; do echo "CRITICAL: System resources approaching limit"; sleep 25; done'

echo ""
echo "Test pods created successfully! They are now generating error logs."
echo ""
echo "To configure the log monitor to watch these pods:"
echo "  1. Run: ./log-monitor-cli.sh select"
echo "  2. Select namespace: $TEST_NAMESPACE"
echo "  3. Select 'All deployments'"
echo ""
echo "To trigger an immediate check:"
echo "  ./log-monitor-cli.sh check"
echo ""
echo "To clean up the test pods when finished:"
echo "  kubectl delete namespace $TEST_NAMESPACE"
