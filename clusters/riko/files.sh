cat <<EOF >$(dirname "$0")/kustomization.yaml
apiVersion: kustomize.config.k8s.io/v1beta1
kind: Kustomization
patches:
  - patch: |-
      apiVersion: kustomize.toolkit.fluxcd.io/v1
      kind: Kustomization
      metadata:
        name: patch-kustomization
      spec:
        decryption:
          provider: sops
          secretRef:
            name: sops-age
        postBuild:
          substitute:
            TSNET: dolly-ruffe.ts.net
    target:
      kind: Kustomization
      group: kustomize.toolkit.fluxcd.io
      version: v1
resources:
  - flux-system
  - core
EOF

for file in $(ls "$(dirname "$0")/apps" | sort -d); do
  echo "  - apps/$file" >>$(dirname "$0")/kustomization.yaml
done
