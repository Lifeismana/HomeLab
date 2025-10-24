#!/bin/bash

if [ -z "$containers_json" ]; then
  echo "Is wud okay?"
  exit 1
fi

FILTERED_JSON=$(jq '
  map(
    {
      REMOTE_TAG: .result.tag,
      LOCAL_TAG: .image.tag.value,
      IMAGE_NAME: .image.name
    }
  ) | unique_by(.IMAGE_NAME)
' <<< "$containers_json")

JSON_PAYLOAD=$(jq -n --argjson data "$FILTERED_JSON" \
  '{"ref": "main", "inputs": {"json": $data | tostring}}')

curl -s -L \
  -X POST \
  -H "Accept: application/vnd.github+json" \
  -H "Authorization: Bearer $GITHUB_BEARER_TOKEN" \
  -H "X-GitHub-Api-Version: 2022-11-28" \
  $GITHUB_WOKFLOW_URL \
  -d "$JSON_PAYLOAD"