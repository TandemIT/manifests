# Job image for .gitea/workflows/deploy.yml: everything deploy.sh needs, so
# a deploy installs nothing. Built and pushed by deploy-image.yml; deploy.yml
# pins the result by digest. The ARGs below are the CI toolchain versions
# (README, Components); setup.sh installs the same ones on a deploy host.
#
# No COPY: deploy-image.yml builds it without a context (docker build -).
FROM debian:bookworm-slim@sha256:3783cc01769c7b2b1b83a5c5ad96c815348e28ed7da68e2e3687004faa906251

# OpenTofu: >= 1.8 (terraform/main.tf); bump with terraform/.terraform.lock.hcl
# in mind. kubectl: within one minor of k3s_version (cluster.auto.tfvars).
ARG TOFU_VERSION=1.13.1
ARG KUBECTL_VERSION=v1.32.3

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]

# ansible-core: the playbooks use ansible.builtin modules only. git: the
# workflow's checkout and deploy.sh/scripts/06. curl: scripts/07.
RUN apt-get update -qq \
 && apt-get install -y -qq --no-install-recommends \
      ansible-core ca-certificates curl git jq openssh-client python3 \
 && rm -rf /var/lib/apt/lists/*

RUN cd /tmp \
 && tofu_url="https://github.com/opentofu/opentofu/releases/download/v${TOFU_VERSION}" \
 && curl -fsSLO "${tofu_url}/tofu_${TOFU_VERSION}_amd64.deb" \
 && curl -fsSL "${tofu_url}/tofu_${TOFU_VERSION}_SHA256SUMS" | grep " tofu_${TOFU_VERSION}_amd64.deb$" | sha256sum -c - \
 && dpkg -i "tofu_${TOFU_VERSION}_amd64.deb" \
 && rm "tofu_${TOFU_VERSION}_amd64.deb" \
 && k8s_url="https://dl.k8s.io/release/${KUBECTL_VERSION}/bin/linux/amd64" \
 && curl -fsSLo kubectl "${k8s_url}/kubectl" \
 && echo "$(curl -fsSL "${k8s_url}/kubectl.sha256")  kubectl" | sha256sum -c - \
 && install -m 755 kubectl /usr/local/bin/kubectl \
 && rm kubectl \
 && tofu version && ansible-playbook --version | head -1 && kubectl version --client
