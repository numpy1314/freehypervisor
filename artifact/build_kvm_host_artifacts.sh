#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ARTIFACT_DIR="${ROOT_DIR}/artifact"
OUT_DIR="${OUT_DIR:-/tmp}"

mkdir -p "${OUT_DIR}"

cc -std=c11 -Wall -Wextra -Werror \
  "${ARTIFACT_DIR}/hhal_linux.c" \
  "${ARTIFACT_DIR}/hhal_linux_smoke_test.c" \
  "${ARTIFACT_DIR}/hhal_linux_x86_helpers.c" \
  -I"${ARTIFACT_DIR}" \
  -o "${OUT_DIR}/hhal_linux_smoke_test"

cc -std=c11 -Wall -Wextra -Werror \
  "${ARTIFACT_DIR}/hhal_linux.c" \
  "${ARTIFACT_DIR}/hhal_linux_extended_state_test.c" \
  "${ARTIFACT_DIR}/hhal_linux_x86_helpers.c" \
  -I"${ARTIFACT_DIR}" \
  -o "${OUT_DIR}/hhal_linux_extended_state_test"

cc -std=c11 -Wall -Wextra -Werror \
  "${ARTIFACT_DIR}/hhal_linux.c" \
  "${ARTIFACT_DIR}/hhal_linux_irq_routing_test.c" \
  "${ARTIFACT_DIR}/hhal_linux_x86_helpers.c" \
  -I"${ARTIFACT_DIR}" \
  -o "${OUT_DIR}/hhal_linux_irq_routing_test"

cc -std=c11 -Wall -Wextra -Werror \
  "${ARTIFACT_DIR}/hhal_linux.c" \
  "${ARTIFACT_DIR}/hhal_linux_irq_delivery_guest.c" \
  "${ARTIFACT_DIR}/hhal_linux_x86_helpers.c" \
  -I"${ARTIFACT_DIR}" \
  -pthread \
  -o "${OUT_DIR}/hhal_linux_irq_delivery_guest"

cc -std=c11 -Wall -Wextra -Werror \
  "${ARTIFACT_DIR}/hhal_linux.c" \
  "${ARTIFACT_DIR}/hhal_linux_signal_mask_test.c" \
  "${ARTIFACT_DIR}/hhal_linux_x86_helpers.c" \
  -I"${ARTIFACT_DIR}" \
  -o "${OUT_DIR}/hhal_linux_signal_mask_test"

cc -std=c11 -Wall -Wextra -Werror \
  "${ARTIFACT_DIR}/hhal_linux.c" \
  "${ARTIFACT_DIR}/hhal_linux_minimal_guest.c" \
  "${ARTIFACT_DIR}/hhal_linux_x86_helpers.c" \
  -I"${ARTIFACT_DIR}" \
  -o "${OUT_DIR}/hhal_linux_minimal_guest"

printf 'Built:\n'
printf '  %s\n' "${OUT_DIR}/hhal_linux_smoke_test"
printf '  %s\n' "${OUT_DIR}/hhal_linux_extended_state_test"
printf '  %s\n' "${OUT_DIR}/hhal_linux_irq_routing_test"
printf '  %s\n' "${OUT_DIR}/hhal_linux_irq_delivery_guest"
printf '  %s\n' "${OUT_DIR}/hhal_linux_signal_mask_test"
printf '  %s\n' "${OUT_DIR}/hhal_linux_minimal_guest"
