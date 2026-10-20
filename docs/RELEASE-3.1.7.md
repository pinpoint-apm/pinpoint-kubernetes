# Chart 3.1.7

Metadata-only release; Pinpoint stays on 3.1.1 and the companion storage chart
is 0.1.5. Templates, values and dependencies are unchanged, so upgrading does
not change any Kubernetes resource.

- The chart icon pointed to a chat-group QR code. Both charts now use the
  Pinpoint symbol (`mini-logo.png` from the upstream `v3.1.1` tag), which Helm
  tools and Artifact Hub display.
- The maintainer contact lists the current e-mail address and GitHub profile.

Validation: `bash scripts/helm-validate.sh`, including a check that both charts
declare an HTTPS icon.
