# Anubis Middleware for Traefik (Kubernetes)

This folder contains the manifests to deploy Anubis and integrate it as a Traefik forwardAuth middleware.

## Files
- `deployment.yaml`: Deploys the Anubis container with secure settings and secret key.
- `service.yaml`: Exposes Anubis on port 8080.
- `middleware.yaml`: Traefik Middleware resource for forwardAuth.

## Usage
1. **Create the secret for Anubis:**
   ```sh
   kubectl create secret generic anubis-key \
     --namespace default \
     --from-literal=ED25519_PRIVATE_KEY_HEX=$(openssl rand -hex 32)
   ```
2. **Apply the manifests:**
   ```sh
   kubectl apply -f deployment.yaml
   kubectl apply -f service.yaml
   kubectl apply -f middleware.yaml
   ```
3. **Reference the middleware in your IngressRoute:**
   ```yaml
   middlewares:
     - name: anubis
       namespace: default
   ```

See the main README for more details.