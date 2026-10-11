#!/usr/bin/env bash
set -euo pipefail
shopt -s nullglob dotglob

staging_dir="$RUNNER_TEMP/osac-artifacts"
source_logs="$RUNNER_TEMP/netris-infra-logs"

cleanup_stage() {
    rm -rf -- "$staging_dir/reports" "$source_logs" "$staging_dir/lab"
    rm -rf -- "$staging_dir/mgmt-cluster/bmaas" "$staging_dir/mgmt-cluster/node"
    for pods_dir in "$staging_dir/mgmt-cluster/namespaces/"*/pods; do
        rm -rf -- "$pods_dir"
    done
}
trap cleanup_stage ERR

mkdir -p "$staging_dir"
if [[ -d reports ]]; then
    cp -a reports "$staging_dir/reports"
fi

rm -rf -- "$source_logs"
if [[ -d infra/netris/logs ]]; then
    cp -a infra/netris/logs "$source_logs"
fi

if [[ -d "$source_logs" ]]; then
    find "$source_logs" -type d \( -name must-gather -o -name inspect \) \
        -prune -print -exec rm -rf -- {} +
    remaining=$(find "$source_logs" -type d \( -name must-gather -o -name inspect \) -print -quit)
    if [[ -n "$remaining" ]]; then
        echo "::error::Refusing to stage raw must-gather/inspect diagnostics: $remaining"
        cleanup_stage
        exit 1
    fi

    # Keep the management-cluster gatherer's per-container logs as the
    # canonical copy when the generic gather step already ran earlier.
    if [[ -d "$source_logs/mgmt-cluster/namespaces" ]]; then
        for pods_dir in "$source_logs/mgmt-cluster/namespaces/"*/pods; do
            [[ -d "$pods_dir" ]] || continue
            namespace=$(basename "$(dirname "$pods_dir")")
            rm -f -- "$staging_dir/mgmt-cluster/namespaces/$namespace"/pod-*.log
        done
    fi

    for source in "$source_logs"/*; do
        [[ -e "$source" || -L "$source" ]] || continue
        case "$(basename "$source")" in
            mgmt-cluster)
                mkdir -p "$staging_dir/mgmt-cluster"
                if [[ -d "$source" ]]; then
                    cp -a "$source/." "$staging_dir/mgmt-cluster/"
                else
                    cp -a "$source" "$staging_dir/mgmt-cluster/"
                fi
                ;;
            bmaas)
                mkdir -p "$staging_dir/mgmt-cluster/bmaas"
                cp -a "$source/." "$staging_dir/mgmt-cluster/bmaas/"
                ;;
            lab)
                mkdir -p "$staging_dir/lab"
                cp -a "$source/." "$staging_dir/lab/"
                ;;
            *)
                mkdir -p "$staging_dir/lab"
                cp -a "$source" "$staging_dir/lab/"
                ;;
        esac
    done
fi

rm -rf -- "$source_logs"
trap - ERR
