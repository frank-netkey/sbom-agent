# Drop .cpe from any component that also has a non-empty .purl, so Dependency-Track
# matches via the ecosystem-specific PURL only. CPE-only components are untouched.
def strip_cpe:
  if type == "object" and ((.purl // "") | tostring | length) > 0
  then del(.cpe)
  else . end;

walk(strip_cpe)
