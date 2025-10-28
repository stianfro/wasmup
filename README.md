# wasmup

A minimal proof of concept demonstrating WASM filters for Envoy Gateway.

This project implements a simple Proxy-Wasm filter in Rust that adds a custom header (`x-wasm-custom: FOO`) to HTTP responses, packages it as an OCI image, and demonstrates deployment to Envoy Gateway.

> **⚠️ Important**: WASM extensions have a known issue in kind clusters due to cache initialization failures. This PoC successfully builds, packages, and deploys all components, but the WASM filter will not execute in kind. **For full functionality, deploy to a production Kubernetes cluster** (GKE, EKS, AKS, etc.). See [Known Limitations](#known-limitations) for details.

## Features

- **Rust WASM Filter**: Simple header injection using the Proxy-Wasm SDK
- **OCI Packaging**: WASM module packaged as a container image
- **Automated Builds**: GitHub Actions for CI/CD
- **Local Testing**: Complete local testing setup with kind
- **Just Commands**: Developer-friendly task automation

## Prerequisites

- [Rust](https://rustup.rs/) with `wasm32-wasip1` target
- [Docker](https://docs.docker.com/get-docker/)
- [kind](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [just](https://github.com/casey/just#installation)

### Install Rust WASM target

```bash
rustup target add wasm32-wasip1
```

## Quick Start

### Full automated setup

```bash
# Create kind cluster, install Envoy Gateway, deploy everything
just all
```

This will:
1. Create a local kind cluster
2. Install Envoy Gateway
3. Deploy test infrastructure (namespace, backend, gateway, route)
4. Apply the WASM extension policy (will show as invalid due to kind limitation)

**Note**: Due to the kind limitation, the WASM filter won't actually execute. To test functionality, deploy to a production cluster.

### Step by step

```bash
# 1. Build the WASM module
just build

# 2. Create local kind cluster
just kind-create

# 3. Install Envoy Gateway
just install-envoy-gateway

# 4. Deploy test infrastructure
just deploy-test

# 5. Apply WASM extension policy
just apply-wasm

# 6. Test the filter
just test
```

## Available Commands

Run `just` to see all available commands:

```bash
just --list
```

### Build Commands

- `just build` - Build the WASM module
- `just build-image` - Build the OCI image
- `just push-image` - Push to ghcr.io/stianfro/wasmup

### Cluster Commands

- `just kind-create` - Create a local kind cluster
- `just kind-delete` - Delete the kind cluster
- `just install-envoy-gateway` - Install Envoy Gateway

### Deployment Commands

- `just deploy-test` - Deploy test infrastructure
- `just apply-wasm` - Apply WASM extension policy
- `just remove-wasm` - Remove WASM extension policy
- `just clean` - Clean up all deployed resources

### Testing Commands

- `just test` - Test the WASM filter
- `just port-forward` - Port-forward Gateway to localhost:8080
- `just test-local` - Test via localhost (use with port-forward)

### Development Commands

- `just update` - Rebuild, push, and update WASM in cluster
- `just all` - Full setup from scratch

## Project Structure

```
.
├── src/
│   └── lib.rs              # WASM filter implementation
├── k8s/
│   ├── namespace.yaml      # Namespace definition
│   ├── backend.yaml        # Test backend (httpbin)
│   ├── gateway.yaml        # Envoy Gateway
│   ├── httproute.yaml      # HTTP route configuration
│   ├── wasm-policy-route.yaml    # WASM policy (HTTPRoute scope)
│   └── wasm-policy-gateway.yaml  # WASM policy (Gateway scope)
├── .github/
│   └── workflows/
│       ├── build.yaml      # Build and push on push/PR
│       └── release.yaml    # Create releases on tags
├── Cargo.toml              # Rust dependencies
├── Dockerfile              # OCI image definition
├── justfile                # Task automation
└── README.md
```

## How It Works

### WASM Filter

The filter is implemented in Rust using the [proxy-wasm](https://github.com/proxy-wasm/proxy-wasm-rust-sdk) SDK. It intercepts HTTP response headers and adds a custom header:

```rust
fn on_http_response_headers(&mut self, _num: usize, _eos: bool) -> Action {
    let _ = proxy_wasm::hostcalls::set_http_response_header("x-wasm-custom", Some("FOO"));
    Action::Continue
}
```

### OCI Packaging

The compiled WASM module is packaged as a minimal OCI image:

```dockerfile
FROM scratch
COPY plugin.wasm /plugin.wasm
```

### Envoy Gateway Integration

The WASM filter is attached to Envoy Gateway using an `EnvoyExtensionPolicy`:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: wasm-add-header
spec:
  targetRefs:
  - group: gateway.networking.k8s.io
    kind: HTTPRoute
    name: backend
  wasm:
  - name: add-header
    rootID: add_header_root
    failOpen: true
    code:
      type: Image
      image:
        url: ghcr.io/stianfro/wasmup:v0.1.0
```

## Testing

### Testing in kind (Limited)

Due to the WASM cache initialization issue, the filter won't execute in kind:

```bash
just test
```

You'll receive HTTP 200 responses from the backend, but **without** the custom `x-wasm-custom: FOO` header.

### Testing in Production Cluster (Full Functionality)

Deploy to a real Kubernetes cluster to see the WASM filter in action:

```bash
# Apply the manifests
kubectl apply -f k8s/

# Wait for resources to be ready
kubectl wait --timeout=2m -n wasmup gateway/eg --for=condition=Programmed

# Get the Gateway address and test
export GATEWAY_HOST=$(kubectl get gateway/eg -n wasmup -o jsonpath='{.status.addresses[0].value}')
curl -i -H "Host: www.example.com" "http://$GATEWAY_HOST/get"
```

Expected output on production cluster:
```
HTTP/1.1 200 OK
...
x-wasm-custom: FOO
...
```

## CI/CD

### Automated Builds

On every push to `main`, GitHub Actions will:
1. Build the WASM module
2. Build and push the OCI image to ghcr.io
3. Tag with branch name and commit SHA

### Releases

Create a release by pushing a tag:

```bash
git tag v0.1.0
git push origin v0.1.0
```

This will:
1. Build and push the OCI image with the version tag
2. Create a GitHub release with the WASM artifact

## Configuration Options

### Scope

The WASM filter can be scoped to:

- **HTTPRoute**: Affects only specific routes (use `k8s/wasm-policy-route.yaml`)
- **Gateway**: Affects all routes on the gateway (use `k8s/wasm-policy-gateway.yaml`)

### Failure Policy

Set `failOpen: true` to allow traffic to pass through if the WASM module fails:

```yaml
wasm:
- name: add-header
  failOpen: true  # false = block with 5xx on failure
```

### Alternative Sources

Instead of OCI images, you can source WASM modules via HTTP:

```yaml
code:
  type: HTTP
  http:
    url: https://example.com/plugin.wasm
    sha256: <sha256sum>
```

## Cleanup

### Remove WASM policy only
```bash
just remove-wasm
```

### Clean up all resources
```bash
just clean
```

### Delete cluster
```bash
just kind-delete
```

## Troubleshooting

### WASM module not loading

Check the Envoy Gateway logs:
```bash
kubectl logs -n envoy-gateway-system deployment/envoy-gateway
```

Check the Envoy proxy logs:
```bash
kubectl logs -n wasmup deployment/<envoy-deployment>
```

### Custom header not appearing

1. Verify the policy is applied:
   ```bash
   kubectl get envoyextensionpolicy -n wasmup
   ```

2. Check policy status:
   ```bash
   kubectl describe envoyextensionpolicy -n wasmup wasm-add-header
   ```

3. Wait a few seconds for the policy to propagate

### Image pull errors

If using a private registry, ensure:
1. The image is public, or
2. Configure image pull secrets in the Envoy Gateway namespace

### WASM cache not initialized

If you see `Wasm: wasm cache is not initialized` in the EnvoyExtensionPolicy status:

This is a known issue with Envoy Gateway in certain environments (particularly kind clusters). The WASM cache directory fails to initialize due to permission or storage configuration issues.

**Workarounds**:
1. Use a production Kubernetes cluster instead of kind
2. Use HTTP source instead of OCI images (we use this in our manifests):
   ```yaml
   code:
     type: HTTP
     http:
       url: https://raw.githubusercontent.com/stianfro/wasmup/main/plugin.wasm
       sha256: <sha256sum>
   ```
3. Deploy Envoy Gateway with custom storage configuration

The issue is tracked in the Envoy Gateway project and affects WASM functionality but not general gateway operation.

## Known Limitations

- **WASM in kind**: The WASM extension feature has known issues in kind clusters due to cache initialization. Test in a real Kubernetes cluster for full functionality.
- **LoadBalancer pending**: In kind, LoadBalancer services stay in Pending state. Use port-forwarding or NodePort for local testing.

## Resources

- [Envoy Gateway WASM Extensions](https://gateway.envoyproxy.io/docs/tasks/extensibility/wasm/)
- [Proxy-Wasm Rust SDK](https://github.com/proxy-wasm/proxy-wasm-rust-sdk)
- [Envoy Gateway API Extensions](https://gateway.envoyproxy.io/docs/api/extension_types/)

## License

MIT
