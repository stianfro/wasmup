# wasmup

A minimal, production-ready example of WASM filters for Envoy Gateway.

This project demonstrates how to build, package, and deploy a Proxy-Wasm filter written in Rust that adds a custom header (`x-wasm-custom: FOO`) to HTTP responses using Envoy Gateway on Kubernetes.

## Features

- **Rust WASM Filter** - Simple header injection using the Proxy-Wasm SDK
- **OCI Packaging** - WASM module packaged as a container image
- **HTTP Delivery** - Alternative HTTP-based module loading
- **Automated CI/CD** - GitHub Actions for building and releasing
- **Just Commands** - Developer-friendly task automation
- **Production Ready** - Tested on real Kubernetes clusters with load balancers

## Prerequisites

- [Rust](https://rustup.rs/) with `wasm32-wasip1` target
- [kubectl](https://kubernetes.io/docs/tasks/tools/)
- [just](https://github.com/casey/just#installation)
- A Kubernetes cluster (GKE, EKS, AKS, kind, etc.)
- Optional: [Docker](https://docs.docker.com/get-docker/) for building OCI images

### Install Rust WASM target

```bash
rustup target add wasm32-wasip1
```

## Quick Start

### Option 1: Automated setup (kind)

```bash
# Create kind cluster, install Envoy Gateway, deploy everything
just all
```

This will create a kind cluster and deploy all components. Note that in kind, you'll need to use port-forwarding to test since LoadBalancer services remain pending.

### Option 2: Deploy to existing cluster

```bash
# Install Envoy Gateway
just install-envoy-gateway

# Deploy test infrastructure
just deploy-test

# Apply WASM extension policy
just apply-wasm

# Test the filter
just test
```

## How It Works

### WASM Filter Implementation

The filter is implemented in Rust using the [proxy-wasm](https://github.com/proxy-wasm/proxy-wasm-rust-sdk) SDK. The implementation requires two key components:

1. **Root Context** - Manages the filter lifecycle and creates HTTP contexts
2. **HTTP Context** - Handles individual HTTP requests/responses

```rust
use proxy_wasm::traits::{Context, HttpContext, RootContext};
use proxy_wasm::types::{Action, ContextType};

struct Root;
impl Context for Root {}
impl RootContext for Root {
    // Required: Specify the context type
    fn get_type(&self) -> Option<ContextType> {
        Some(ContextType::HttpContext)
    }

    fn create_http_context(&self, _id: u32) -> Option<Box<dyn HttpContext>> {
        Some(Box::new(Filter))
    }
}

struct Filter;
impl Context for Filter {}
impl HttpContext for Filter {
    fn on_http_response_headers(&mut self, _num: usize, _eos: bool) -> Action {
        self.set_http_response_header("x-wasm-custom", Some("FOO"));
        Action::Continue
    }
}

proxy_wasm::main! {{
    proxy_wasm::set_root_context(|_vm_id| Box::new(Root));
}}
```

**Important**: The `get_type()` method is required in the Root context to specify that it creates HTTP contexts. Without this, the WASM module will panic at runtime.

### Building the WASM Module

```bash
just build
```

This compiles the Rust code to WASM targeting `wasm32-wasip1` and produces `plugin.wasm`.

### OCI Packaging

The WASM module can be packaged as a minimal OCI image:

```dockerfile
FROM scratch
COPY plugin.wasm /plugin.wasm
```

Build and push:
```bash
just build-image
just push-image
```

### Envoy Gateway Integration

The WASM filter is attached using an `EnvoyExtensionPolicy` resource:

```yaml
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyExtensionPolicy
metadata:
  name: wasm-add-header
  namespace: wasmup
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

Once deployed, test the WASM filter:

```bash
# Get the Gateway address
export GATEWAY_HOST=$(kubectl get gateway/eg -n wasmup -o jsonpath='{.status.addresses[0].value}')

# Send a request
curl -i -H "Host: www.example.com" "http://$GATEWAY_HOST/get"
```

Expected output:
```
HTTP/1.1 200 OK
...
x-wasm-custom: FOO
...
```

### Testing with port-forward (kind)

If using kind, the LoadBalancer service will remain pending. Use port-forwarding:

```bash
# Terminal 1
just port-forward

# Terminal 2
just test-local
```

## Configuration Options

### WASM Module Source

**OCI Image** (recommended for production):
```yaml
code:
  type: Image
  image:
    url: ghcr.io/stianfro/wasmup:v0.1.0
```

**HTTP URL** (simpler for testing):
```yaml
code:
  type: HTTP
  http:
    url: https://raw.githubusercontent.com/stianfro/wasmup/main/plugin.wasm
    sha256: 78ba0947209f5dcabcd15b25d44916358e863499c3012a9eb69a8d980efa6dab
```

### Policy Scope

**HTTPRoute scope** (specific routes only):
```yaml
targetRefs:
- group: gateway.networking.k8s.io
  kind: HTTPRoute
  name: backend
```

**Gateway scope** (all routes):
```yaml
targetRefs:
- group: gateway.networking.k8s.io
  kind: Gateway
  name: eg
```

### Failure Policy

Control behavior when the WASM module fails:

```yaml
wasm:
- name: add-header
  failOpen: true  # true = allow traffic, false = block with 5xx
```

## Available Commands

Run `just --list` to see all available commands:

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

## CI/CD

### Automated Builds

GitHub Actions automatically builds and publishes on every push to `main`:

1. Builds the WASM module
2. Builds and pushes the OCI image to ghcr.io
3. Tags with branch name and commit SHA

### Releases

Create a release by pushing a tag:

```bash
git tag v0.2.0
git push origin v0.2.0
```

This creates a GitHub release with the WASM artifact and publishes a versioned OCI image.

## Troubleshooting

### WASM module not loading

Check the Envoy proxy logs:
```bash
kubectl logs -n envoy-gateway-system -l gateway.envoyproxy.io/owning-gateway-name=eg -c envoy
```

Common issues:
- Missing `get_type()` method in Root context → Runtime panic
- Incorrect `rootID` → Module won't be loaded
- Network issues fetching remote modules

### Policy not accepted

Check the policy status:
```bash
kubectl describe envoyextensionpolicy -n wasmup wasm-add-header
```

Look for:
- Syntax errors in the policy YAML
- Invalid target references
- Image pull failures (check image URL and auth)
- SHA256 mismatch (for HTTP sources)

### Custom header not appearing

1. Verify the policy is applied and accepted:
   ```bash
   kubectl get envoyextensionpolicy -n wasmup
   ```

2. Check that the WASM module loaded successfully in Envoy logs

3. Wait 10-30 seconds for configuration to propagate to Envoy proxies

4. Restart Envoy pods if needed:
   ```bash
   kubectl rollout restart -n envoy-gateway-system deployment -l gateway.envoyproxy.io/owning-gateway-name=eg
   ```

### Image pull errors

For private registries:
- Ensure the image is publicly accessible, or
- Configure imagePullSecrets in the Envoy Gateway system namespace

For HTTP sources:
- Verify the URL is accessible from the cluster
- Ensure SHA256 matches: `sha256sum plugin.wasm`

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

## Resources

- [Envoy Gateway WASM Extensions](https://gateway.envoyproxy.io/docs/tasks/extensibility/wasm/)
- [Proxy-Wasm Rust SDK](https://github.com/proxy-wasm/proxy-wasm-rust-sdk)
- [Envoy Gateway API Extensions](https://gateway.envoyproxy.io/docs/api/extension_types/)
- [Proxy-Wasm Specification](https://github.com/proxy-wasm/spec)

## License

MIT
