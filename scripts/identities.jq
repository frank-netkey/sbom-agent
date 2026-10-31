# Input: output of `docker container inspect <ids...>` (array).
# Output: one JSON object per distinct service identity.
#
# Identity precedence:
#   1. label sbom.name                       (explicit override)
#   2. label coolify.resourceName [/ compose service]
#   3. compose project/service
#   4. container name
# Every derived segment is normalized (see below) so a redeploy keeps the same identity.
# Output also has `group`: label sbom.parent, else normalized coolify.resourceName, else
# normalized compose project; "" when absent or equal to the identity (single-container resource).
# Opt out with label sbom.scan=false. Pin to an existing DT project with
# sbom.dtrack.project=<uuid>. Extra tags: sbom.tags=a,b
def lbl($l; $k): ($l[$k] // "");

# Strip Coolify's per-deploy suffixes: a trailing -<12+ digits> and a trailing -YYYYMMDDTHHMMSS[Z].
# The 24-char resource UUIDs are stable and kept.
def normalize: sub("-[0-9]{12,}$"; "") | sub("-[0-9]{8}T[0-9]{6}Z?$"; "");

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
          ($l["coolify.resourceName"] | normalize)
          + (if lbl($l; "com.docker.compose.service") != "" then "/" + ($l["com.docker.compose.service"] | normalize) else "" end)
        elif lbl($l; "com.docker.compose.project") != "" and lbl($l; "com.docker.compose.service") != "" then
          ($l["com.docker.compose.project"] | normalize) + "/" + ($l["com.docker.compose.service"] | normalize)
        else ($name | normalize)
        end),
      group: (
        if lbl($l; "sbom.parent") != "" then $l["sbom.parent"]
        elif lbl($l; "coolify.resourceName") != "" then ($l["coolify.resourceName"] | normalize)
        elif lbl($l; "com.docker.compose.project") != "" then ($l["com.docker.compose.project"] | normalize)
        else "" end)
    }
]
| map(if .group == .identity then .group = "" else . end)
| unique_by(.identity)
| .[]
