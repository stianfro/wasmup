# WASM PoC for Envoy Gateway

# Variables
IMAGE := "ghcr.io/stianfro/wasmup"
VERSION := "v0.1.0"
CLUSTER_NAME := "wasmup-test"
NAMESPACE := "wasmup"
EG_VERSION := "v1.2.4"

# Default recipe - show available commands
default:
    @just --list

# Build the WASM module
build:
    #!/usr/bin/env bash
    set -euxo pipefail
    echo "Building WASM module..."
    cargo build --release --target wasm32-wasip1
    cp target/wasm32-wasip1/release/wasmup.wasm plugin.wasm
    echo "✓ WASM module built: plugin.wasm"

# Build the OCI image
build-image: build
    #!/usr/bin/env bash
    set -euxo pipefail
    echo "Building OCI image..."
    docker build -t {{IMAGE}}:{{VERSION}} .
    docker tag {{IMAGE}}:{{VERSION}} {{IMAGE}}:latest
    echo "✓ OCI image built: {{IMAGE}}:{{VERSION}}"

# Push the OCI image to registry
push-image: build-image
    #!/usr/bin/env bash
    set -euxo pipefail
    echo "Pushing OCI image to registry..."
    docker push {{IMAGE}}:{{VERSION}}
    docker push {{IMAGE}}:latest
    echo "✓ Image pushed to {{IMAGE}}:{{VERSION}}"

# Create a local kind cluster
kind-create:
    #!/usr/bin/env bash
    set -euxo pipefail
    if kind get clusters | grep -q "^{{CLUSTER_NAME}}$"; then
        echo "Cluster {{CLUSTER_NAME}} already exists"
    else
        echo "Creating kind cluster..."
        kind create cluster --name {{CLUSTER_NAME}}
        echo "✓ Cluster created: {{CLUSTER_NAME}}"
    fi

# Delete the local kind cluster
kind-delete:
    #!/usr/bin/env bash
    set -euxo pipefail
    if kind get clusters | grep -q "^{{CLUSTER_NAME}}$"; then
        echo "Deleting kind cluster..."
        kind delete cluster --name {{CLUSTER_NAME}}
        echo "✓ Cluster deleted: {{CLUSTER_NAME}}"
    else
        echo "Cluster {{CLUSTER_NAME}} does not exist"
    fi

# Install Envoy Gateway in the cluster
install-envoy-gateway:
    #!/usr/bin/env bash
    set -euxo pipefail
    echo "Installing Envoy Gateway {{EG_VERSION}}..."
    # Ignore CRD annotation error - it's a known issue but doesn't prevent functionality
    kubectl apply -f https://github.com/envoyproxy/gateway/releases/download/{{EG_VERSION}}/install.yaml || true
    echo "Waiting for Envoy Gateway to be ready..."
    kubectl wait --timeout=5m -n envoy-gateway-system deployment/envoy-gateway --for=condition=Available
    echo "Creating GatewayClass..."
    kubectl apply -f - <<'EOF'
    apiVersion: gateway.networking.k8s.io/v1
    kind: GatewayClass
    metadata:
      name: eg
    spec:
      controllerName: gateway.envoyproxy.io/gatewayclass-controller
    EOF
    echo "✓ Envoy Gateway installed and ready"

# Deploy test infrastructure (namespace, backend, gateway, route)
deploy-test:
    #!/usr/bin/env bash
    set -euxo pipefail
    echo "Deploying test infrastructure..."
    kubectl apply -f k8s/namespace.yaml
    kubectl apply -f k8s/backend.yaml
    kubectl apply -f k8s/gateway.yaml
    kubectl apply -f k8s/httproute.yaml
    echo "Waiting for backend to be ready..."
    kubectl wait --timeout=2m -n {{NAMESPACE}} deployment/httpbin --for=condition=Available
    echo "Waiting for Gateway to be ready..."
    kubectl wait --timeout=2m -n {{NAMESPACE}} gateway/eg --for=condition=Programmed
    echo "✓ Test infrastructure deployed"

# Apply the WASM extension policy
apply-wasm:
    #!/usr/bin/env bash
    set -euxo pipefail
    echo "Applying WASM extension policy..."
    kubectl apply -f k8s/wasm-policy-route.yaml
    echo "✓ WASM policy applied"

# Remove the WASM extension policy
remove-wasm:
    #!/usr/bin/env bash
    set -euxo pipefail
    echo "Removing WASM extension policy..."
    kubectl delete -f k8s/wasm-policy-route.yaml --ignore-not-found
    echo "✓ WASM policy removed"

# Test the WASM filter (check for custom header)
test:
    #!/usr/bin/env bash
    set -euxo pipefail
    echo "Getting Gateway address..."
    GATEWAY_HOST=$(kubectl get gateway/eg -n {{NAMESPACE}} -o jsonpath='{.status.addresses[0].value}')
    echo "Testing WASM filter at $GATEWAY_HOST..."
    echo ""
    echo "Sending request..."
    curl -i -H "Host: www.example.com" "http://$GATEWAY_HOST/get" | grep -E "(HTTP/|x-wasm-custom:)" || true
    echo ""
    echo "Look for 'x-wasm-custom: FOO' in the response headers above ☝️"

# Port-forward to Gateway for local testing
port-forward:
    #!/usr/bin/env bash
    echo "Port-forwarding Gateway to localhost:8080..."
    kubectl port-forward -n {{NAMESPACE}} service/eg-gateway-eg 8080:80

# Test via port-forward (run in another terminal after 'just port-forward')
test-local:
    #!/usr/bin/env bash
    set -euxo pipefail
    echo "Testing via localhost:8080..."
    curl -i -H "Host: www.example.com" "http://localhost:8080/get" | grep -E "(HTTP/|x-wasm-custom:)" || true
    echo ""
    echo "Look for 'x-wasm-custom: FOO' in the response headers above ☝️"

# Clean up all deployed resources
clean:
    #!/usr/bin/env bash
    set -euxo pipefail
    echo "Cleaning up resources..."
    kubectl delete -f k8s/wasm-policy-route.yaml --ignore-not-found
    kubectl delete -f k8s/httproute.yaml --ignore-not-found
    kubectl delete -f k8s/gateway.yaml --ignore-not-found
    kubectl delete -f k8s/backend.yaml --ignore-not-found
    kubectl delete -f k8s/namespace.yaml --ignore-not-found
    echo "✓ Resources cleaned up"

# Full setup: create cluster, install Envoy Gateway, deploy, apply WASM, test
all: kind-create install-envoy-gateway deploy-test apply-wasm
    @echo ""
    @echo "✓ Full setup complete! Waiting 10s for policy to propagate..."
    @sleep 10
    @just test

# Rebuild and update WASM in cluster
update: push-image
    #!/usr/bin/env bash
    set -euxo pipefail
    echo "Restarting Envoy pods to pick up new image..."
    kubectl rollout restart -n {{NAMESPACE}} deployment -l gateway.envoyproxy.io/owning-gateway-name=eg
    echo "Waiting for rollout..."
    kubectl rollout status -n {{NAMESPACE}} deployment -l gateway.envoyproxy.io/owning-gateway-name=eg
    echo "✓ WASM updated in cluster"
