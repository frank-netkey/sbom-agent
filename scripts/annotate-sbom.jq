# Enrich the SBOM with the "essential elements" it usually lacks and make it traceable to the exact image.
#  - metadata.authors / metadata.lifecycles: who generated it, and the life-cycle phase (CycloneDX >= 1.5)
#  - metadata.properties: image ID, image reference, host, generation time
#  - metadata.component.hashes: the image's repo (manifest) digest, when the image has one
#  - dependencies: a root entry for the image component, so the dependency graph has a root
def props: [
  {name: "sbom-agent:image-id",     value: $image_id},
  {name: "sbom-agent:image-ref",    value: $image_ref},
  {name: "sbom-agent:host",         value: $host},
  {name: "sbom-agent:generated-at", value: $ts}
] | map(select(.value != ""));

def at_least($major; $minor):
  ((.specVersion // "0.0") | split(".") | map(tonumber? // 0)) as $v
  | ($v[0] > $major) or ($v[0] == $major and ($v[1] // 0) >= $minor);

def all_components: (.components // [])[] | ., all_components;

# Components nobody depends on become the root's direct dependencies.
def with_root:
  (.metadata.component["bom-ref"] // "") as $root
  | if $root == "" or (.dependencies // [] | any(.ref == $root)) then .
    else
      ([(.dependencies // [])[] | (.dependsOn // [])[]] | unique) as $depended
      | ([.components[]? | .["bom-ref"] // empty] | map(select(. as $r | $depended | index($r) | not))) as $tops
      | .dependencies = ((.dependencies // []) + [{ref: $root, dependsOn: $tops}])
    end;

.metadata.properties = ((.metadata.properties // []) + props)
| (if $author != "" then .metadata.authors = ((.metadata.authors // []) + [{name: $author}]) else . end)
| (if at_least(1; 5) then .metadata.lifecycles = [{phase: "operations"}] else . end)
| (if ($repo_digest | test("@sha256:[0-9a-f]{64}$")) and .metadata.component != null
   then .metadata.component.hashes =
          ((.metadata.component.hashes // []) + [{alg: "SHA-256", content: ($repo_digest | sub("^.*@sha256:"; ""))}])
   else . end)
| (if .metadata.component != null then with_root else . end)
