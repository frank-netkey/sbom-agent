# Completeness summary of an SBOM (guide: "known unknowns" / completeness check).
def all_components: (.components // [])[] | ., all_components;
[all_components] as $c
| ($c | length) as $n
| def pct($k): if $n == 0 then 100 else (($k * 1000 / $n | floor) / 10) end;
  ($c | map(select((.purl // "") != "")) | length) as $purl
| ($c | map(select((.version // "") != "")) | length) as $ver
| ($c | map(select((.hashes // []) | length > 0)) | length) as $hash
| ($c | map(select((.purl // "") == "" and (.cpe // "") == "")) | length) as $noid
| {components: $n, with_purl: $purl, with_version: $ver, with_hash: $hash, no_identifier: $noid,
   purl_pct: pct($purl), version_pct: pct($ver), hash_pct: pct($hash)}
