FROM python:3.9-slim

WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy application code
COPY . .

# Set execute permissions
RUN chmod +x main.py

# Run the app
CMD ["python", "main.py"]
