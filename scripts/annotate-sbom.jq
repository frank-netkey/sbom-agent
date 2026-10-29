# Record where this SBOM came from, so it can be traced back to the exact image.
#  - metadata.properties: image ID, image reference, host, generation time
#  - metadata.component.hashes: the image's repo (manifest) digest, when the image has one
def props: [
  {name: "sbom-agent:image-id",     value: $image_id},
  {name: "sbom-agent:image-ref",    value: $image_ref},
  {name: "sbom-agent:host",         value: $host},
  {name: "sbom-agent:generated-at", value: $ts}
] | map(select(.value != ""));

.metadata.properties = ((.metadata.properties // []) + props)
| if ($repo_digest | test("@sha256:[0-9a-f]{64}$")) and .metadata.component != null
  then .metadata.component.hashes =
         ((.metadata.component.hashes // []) + [{alg: "SHA-256", content: ($repo_digest | sub("^.*@sha256:"; ""))}])
  else . end
