#!/usr/bin/env bash
set -euo pipefail

validator="${WGSL_VALIDATOR:-}"
if [[ -z "${validator}" ]]; then
  if command -v naga >/dev/null 2>&1; then
    validator="naga"
  elif command -v tint >/dev/null 2>&1; then
    validator="tint"
  fi
fi

if [[ -z "${validator}" ]]; then
  echo "WGSL validator not found; install naga or tint, or set WGSL_VALIDATOR." >&2
  exit 0
fi

zwgsl_bin="${ZWGSL_BIN:-zig-out/bin/zwgsl}"
if [[ ! -x "${zwgsl_bin}" ]]; then
  echo "zwgsl binary not found at ${zwgsl_bin}; run zig build first." >&2
  exit 1
fi

tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/zwgsl-wgsl-validation.XXXXXX")"
trap 'rm -rf "${tmp_dir}"' EXIT

validate_one() {
  local input="$1"
  local stage="$2"
  local output="${tmp_dir}/$(basename "${input}").${stage}.wgsl"
  local error_log="${tmp_dir}/$(basename "${input}").${stage}.err"

  if "${zwgsl_bin}" compile --target wgsl --stage "${stage}" "${input}" >"${output}" 2>"${error_log}"; then
    if [[ -s "${output}" ]]; then
      "${validator}" "${output}" >/dev/null
      echo "validated ${input} (${stage})"
    fi
    return
  fi

  if grep -q "selected stage has no output" "${error_log}"; then
    return
  fi

  cat "${error_log}" >&2
  return 1
}

for input in examples/*.zw tests/fixtures/*.zw; do
  [[ -e "${input}" ]] || continue
  validate_one "${input}" vertex
  validate_one "${input}" fragment
  validate_one "${input}" compute
done
