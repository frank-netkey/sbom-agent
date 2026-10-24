# Input: output of `docker container inspect <ids...>` (array).
# Output: one JSON object per distinct service identity.
#
# Identity precedence:
#   1. label sbom.name                       (explicit override)
#   2. label coolify.resourceName [/ compose service]
#   3. compose project/service
#   4. container name with Coolify's trailing deployment timestamp removed
# Opt out with label sbom.scan=false. Pin to an existing DT project with
# sbom.dtrack.project=<uuid>. Extra tags: sbom.tags=a,b
def lbl($l; $k): ($l[$k] // "");

[ .[]
  | (.Config.Labels // {}) as $l
  | select(lbl($l; "sbom.scan") != "false")
  | select((.Image // "") != "")
  | (.Name | ltrimstr("/")) as $name
  | {
      container:    .Id,
      name:         $name,
      image_id:     .Image,
      image_ref:    (.Config.Image // ""),
      project_uuid: lbl($l; "sbom.dtrack.project"),
      tags:         lbl($l; "sbom.tags"),
      identity: (
        if lbl($l; "sbom.name") != "" then $l["sbom.name"]
        elif lbl($l; "coolify.resourceName") != "" then
          $l["coolify.resourceName"]
          + (if lbl($l; "com.docker.compose.service") != "" then "/" + $l["com.docker.compose.service"] else "" end)
        elif lbl($l; "com.docker.compose.project") != "" and lbl($l; "com.docker.compose.service") != "" then
          $l["com.docker.compose.project"] + "/" + $l["com.docker.compose.service"]
        else ($name | sub("-[0-9]{12,}$"; ""))
        end)
    }
]
| unique_by(.identity)
| .[]
