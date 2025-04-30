# Kubernetes Log Monitor

A robust monitoring solution for detecting and alerting on errors in Kubernetes cluster logs. This application monitors pods and deployments across namespaces, detects error patterns in logs, and sends immediate notifications to Slack when issues are found.

## Features

- **Real-time Error Detection**: Continuously monitors Kubernetes logs for error patterns
- **Multi-namespace Support**: Monitor specific namespaces or all namespaces in your cluster
- **Deployment & Pod Monitoring**: Target specific deployments/pods or monitor everything
- **Instant Slack Notifications**: Get immediate alerts when errors are detected
- **Detailed Error Context**: Includes stack traces and surrounding context with notifications
- **Interactive CLI**: Easily configure monitoring and view logs/errors directly
- **REST API**: Programmatically control the monitoring process
- **Customizable Error Patterns**: Define what patterns trigger alerts
- **Adjustable Check Intervals**: Set how frequently logs are checked

## Components

- **main.py**: Core monitoring application that runs in your Kubernetes cluster
- **log.sh**: Interactive CLI tool for configuring and controlling the monitor
- **test-error-logs.sh**: Script for testing the error detection capabilities
- **deployment.yaml**: Kubernetes deployment configuration for the monitor
- **Dockerfile**: Container configuration for building the monitoring image
- **requirements.txt**: Python dependencies for the application

## Installation

### Prerequisites

- Kubernetes cluster with proper RBAC permissions
- kubectl configured to access your cluster
- Slack webhook URL for notifications

### Deployment Steps

1. **Clone the repository**

```bash
git clone repo_url
cd automation-logs
```

2. **Configure Slack webhook**

Edit `main.py` and `deployment.yaml`  to set your Slack webhook URL:

```python
SLACK_WEBHOOK_URL = "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"
```

3. **Build and push the Docker image**

```bash
docker build -t your-registry/kubernetes-log-monitor:latest .
docker push your-registry/kubernetes-log-monitor:latest
```

4. **Update deployment configuration**

Edit `deployment.yaml` to use your Docker image and configure any environment variables.

5. **Deploy to Kubernetes**

```bash
kubectl apply -f deployment.yaml
```

## Usage

### Using the CLI

The `log.sh` script provides an interactive CLI for controlling the monitoring process:

```bash
./log.sh
```

Available commands:

- `select`: Configure which namespaces and deployments/pods to monitor
- `check`: Trigger an immediate log check
- `test`: Send a test notification to Slack
- `logs`: View logs for a specific pod
- `errors`: Filter and display error logs for a pod
- `config`: Show current monitoring configuration
- `start`: Start the monitoring process
- `stop`: Pause the monitoring process
- `help`: Show available commands
- `exit`: Exit the CLI

### Navigation

- At any prompt, you can enter `b` or `back` to return to the previous menu
- Follow the interactive prompts to configure monitoring or view logs

### Testing Error Detection

The included `test-error-logs.sh` script can generate test error logs to verify your setup:

```bash
./test-error-logs.sh
```

## API Reference

The monitoring application exposes a REST API on port 8080:

- `GET /api/config`: Get current monitoring configuration
- `POST /api/config`: Update monitoring configuration
- `GET /api/namespaces`: List available namespaces
- `GET /api/deployments?namespace={namespace}`: List deployments in a namespace
- `POST /api/start`: Start monitoring
- `POST /api/stop`: Stop monitoring
- `POST /api/check-now`: Trigger immediate check
- `POST /api/test-notification`: Send test notification to Slack

## Architecture

- The monitor runs as a pod within your Kubernetes cluster
- It accesses the Kubernetes API to retrieve logs from pods
- Error detection runs at configurable intervals (default: 5 minutes)
- Detected errors are immediately sent to Slack
- The CLI connects to the monitor via port-forwarding

## Configuration Options

Key environment variables for `deployment.yaml`:

- `SLACK_WEBHOOK_URL`: Slack webhook for notifications
- `DEFAULT_NAMESPACES`: Comma-separated list of namespaces to monitor (default: "default")
- `DEFAULT_DEPLOYMENTS`: Comma-separated list of deployments to monitor (default: "all")
- `ERROR_PATTERNS`: Comma-separated list of error patterns (default: "error,exception,fail,critical")
- `CHECK_INTERVAL`: Seconds between checks (default: 300)
- `LOG_MINUTES`: Minutes of logs to check (default: 5)
- `MAX_ERROR_LINES`: Maximum error lines in notification (default: 20)
- `DEBUG`: Enable debug logging (default: "false")
- `API_PORT`: Port for API server (default: 8080)

## Troubleshooting

### Common Issues

1. **No Slack notifications**
   - Verify your Slack webhook URL is correct
   - Check if the monitor pod has internet access
   - Run `test` command to test Slack connectivity

2. **Monitor not finding errors**
   - Verify error patterns match your application's error format
   - Check if the monitor has permissions to access pod logs
   - Run `errors` command to manually check for errors

3. **CLI connection issues**
   - Ensure port-forwarding is working correctly
   - Verify the monitor pod is running
   - Check network policies that might block port-forwarding

## Contributing

Contributions are welcome! Please feel free to submit a Pull Request.

## License

This project is licensed under the MIT License - see the LICENSE file for details.
