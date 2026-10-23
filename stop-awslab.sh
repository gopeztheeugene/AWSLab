#!/usr/bin/env bash
# =============================================================================
# stop-awslab.sh - step 4 (reset) for the AWS DFIR lab (bash + AWS CLI).
#
# The Linux counterpart of Stop-AwsLab.ps1. Terminates the attacked DC + member
# pair and cleans up; --preserve-disk EBS-snapshots their volumes first (tagged
# with topic + date). Kali and the VPN server have no golden AMI, so they're
# stopped, never terminated. No relaunch here: step 1 rebuilds from the golden
# AMIs.
#
# Refuses to terminate anything unless each box has an available golden AMI
# with its Launch* tags, i.e. unless step 1 could bring it back.
#
# Requires: awscli v2 (configured creds), jq.
# =============================================================================
set -euo pipefail

# --- defaults (override with flags) -----------------------------------------
REGION="ap-southeast-2"
SG_IDS=("sg-02df021a36003f4f1" "sg-0549668744af8e82d")
RULE_TAG="AWSLab-launcher"
RESET_NAMES=("dc" "member01")             # golden-backed pair to terminate
PRESERVE=0                                 # --preserve-disk
TOPIC=""                                   # --topic, required with --preserve-disk
PROJECT="AWSLab"
MOUNT_POINT="${HOME}/lab-logs"
TIMEOUT_MINS=30
STATE_PATH="$(dirname "$(readlink -f "$0")")/lab-state.json"
PROFILE=""                                 # --profile <aws profile>
DRY_RUN=0
ASSUME_YES=0

usage() {
    cat <<'USAGE'
Usage: stop-awslab.sh [options]
      --preserve-disk         Snapshot the attacked volumes before terminating
      --topic NAME            Attack topic for the snapshot tags (required with --preserve-disk)
      --reset-name NAME[,..]  Boxes to terminate (default: dc,member01)
      --region REGION         AWS region (default: ap-southeast-2)
      --profile NAME          AWS CLI profile
      --mount-point PATH      Log share mount to remove (default: ~/lab-logs)
      --timeout MINUTES       Overall wait budget (default: 30)
      --dry-run               Show the plan; change nothing
  -y, --yes                   Don't ask for confirmation
  -h, --help                  This help
USAGE
}

# --- arg parsing -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --preserve-disk) PRESERVE=1; shift ;;
        --topic)         TOPIC="$2"; shift 2 ;;
        --reset-name)    IFS=',' read -r -a RESET_NAMES <<< "$2"; shift 2 ;;
        --region)        REGION="$2"; shift 2 ;;
        --profile)       PROFILE="$2"; shift 2 ;;
        --mount-point)   MOUNT_POINT="$2"; shift 2 ;;
        --timeout)       TIMEOUT_MINS="$2"; shift 2 ;;
        --dry-run)       DRY_RUN=1; shift ;;
        -y|--yes)        ASSUME_YES=1; shift ;;
        -h|--help)       usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

[[ -n "${BASH_VERSION:-}" ]] || { echo "Run with bash (not sh/ash): bash stop-awslab.sh ..." >&2; exit 1; }
command -v aws >/dev/null || { echo "awscli not found. Install AWS CLI v2." >&2; exit 1; }
command -v jq  >/dev/null || { echo "jq not found. Install jq." >&2; exit 1; }
if [[ "$PRESERVE" -eq 1 && -z "$TOPIC" ]]; then
    echo "--preserve-disk needs --topic, for the snapshot tags (e.g. --topic kerberoast)." >&2; exit 2
fi

AWS=(aws --region "$REGION" --output json)
[[ -n "$PROFILE" ]] && AWS+=(--profile "$PROFILE")

step()  { printf '==> %s\n' "$*"; }
deadline=$(( $(date +%s) + TIMEOUT_MINS * 60 ))
check_timeout() { (( $(date +%s) > deadline )) && { echo "Timed out after ${TIMEOUT_MINS}m waiting for $*." >&2; exit 1; }; return 0; }

SG_CSV=$(IFS=,; echo "${SG_IDS[*]}")

is_reset_name() { local n; for n in "${RESET_NAMES[@]}"; do [[ "$1" == "$n" ]] && return 0; done; return 1; }

# Live lab instances (terminated ignored) as TSV: id \t name \t state
lab_instances() {
    "${AWS[@]}" ec2 describe-instances \
        --filters "Name=instance.group-id,Values=${SG_CSV}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        | jq -r '
            .Reservations[].Instances[] |
            [ .InstanceId,
              ((.Tags // [] | map(select(.Key=="Name")) | .[0].Value) // .InstanceId),
              .State.Name ] | @tsv'
}

# --- 1. find the lab instances ----------------------------------------------
step "Finding lab instances in $REGION"
mapfile -t ROWS < <(lab_instances)
[[ ${#ROWS[@]} -gt 0 ]] || { echo "No live instances in ${SG_CSV}. Nothing to reset." >&2; exit 1; }

TERM_IDS=(); TERM_NAMES=(); STOP_IDS=(); STOP_NAMES=()
for r in "${ROWS[@]}"; do
    IFS=$'\t' read -r id name state <<< "$r"
    if is_reset_name "$name"; then
        action="terminate"; TERM_IDS+=("$id"); TERM_NAMES+=("$name")
    elif [[ "$state" == "running" || "$state" == "pending" ]]; then
        action="stop"; STOP_IDS+=("$id"); STOP_NAMES+=("$name")
    else
        action="leave (already stopped)"
    fi
    printf '    %-24s %-20s %-9s -> %s\n' "$name" "$id" "$state" "$action"
done

# Duplicate Name tags would mean terminating something unexpected; stop and let a human look.
dupes=$(printf '%s\n' "${TERM_NAMES[@]:-}" | sort | uniq -d)
[[ -z "$dupes" ]] || { echo "More than one live instance named: $dupes. Sort that out by hand first." >&2; exit 1; }
for n in "${RESET_NAMES[@]}"; do
    printf '%s\n' "${TERM_NAMES[@]:-}" | grep -qxF "$n" || echo "WARN: not present (already reset?): $n" >&2
done

# --- 2. golden AMI check ------------------------------------------------------
# Terminating is only safe if step 1 can rebuild: an available golden AMI per
# box, with the Launch* tags the rebuild reads.
if [[ ${#TERM_IDS[@]} -gt 0 ]]; then
    step "Checking golden AMIs"
    amis=$("${AWS[@]}" ec2 describe-images --owners self \
        --filters "Name=tag:Baseline,Values=golden" "Name=state,Values=available")
    for n in "${TERM_NAMES[@]}"; do
        ami=$(jq -c --arg n "$n" '
            [ .Images[] | .t = (.Tags // [] | from_entries) | select(.t.LaunchName==$n) ]
            | sort_by(.CreationDate) | last // empty' <<< "$amis")
        if [[ -z "$ami" ]]; then
            echo "No available golden AMI with LaunchName=$n. Step 1 couldn't rebuild it, so nothing was terminated." >&2
            echo "Capture one with New-GoldenBaseline.ps1 (or add the Launch* tags to the existing AMI)." >&2
            exit 1
        fi
        for need in LaunchInstanceType LaunchSubnetId LaunchKeyName LaunchSecurityGroupIds; do
            if [[ -z "$(jq -r --arg k "$need" '.t[$k] // empty' <<< "$ami")" ]]; then
                echo "Golden AMI $(jq -r .ImageId <<< "$ami") for '$n' is missing tag '$need', so step 1 couldn't rebuild it. Nothing was terminated." >&2
                exit 1
            fi
        done
        echo "    $n  -> $(jq -r '.ImageId + "  (" + (.t.BaselineId // "?") + ")"' <<< "$ami")"
    done
fi

# --- confirm ------------------------------------------------------------------
echo "Plan:"
if [[ ${#TERM_IDS[@]} -gt 0 ]]; then
    if [[ "$PRESERVE" -eq 1 ]]; then disks="snapshot disks first"; else disks="disks deleted"; fi
    echo "    terminate ${TERM_NAMES[*]} ($disks)"
fi
[[ ${#STOP_IDS[@]} -gt 0 ]] && echo "    stop ${STOP_NAMES[*]}"
echo "    revoke ${RULE_TAG} SG rules, unmount $MOUNT_POINT, remove lab-state.json"
[[ "$DRY_RUN" -eq 1 ]] && { echo "Dry run: nothing changed."; exit 0; }
if [[ "$ASSUME_YES" -ne 1 ]]; then
    read -r -p "Type 'reset' to continue: " answer
    [[ "$answer" == "reset" ]] || { echo "Aborted; nothing changed."; exit 1; }
fi

# EBS volumes on the boxes being reset, captured now: they detach on termination.
VOLS=()
if [[ ${#TERM_IDS[@]} -gt 0 ]]; then
    # id \t name \t device \t volume, for every EBS volume on the boxes being reset
    mapfile -t VOLS < <(
        "${AWS[@]}" ec2 describe-instances --instance-ids "${TERM_IDS[@]}" \
        | jq -r '
            .Reservations[].Instances[] |
            .InstanceId as $id |
            ((.Tags // [] | map(select(.Key=="Name")) | .[0].Value) // .InstanceId) as $name |
            .BlockDeviceMappings[] | select(.Ebs) |
            [ $id, $name, .DeviceName, .Ebs.VolumeId ] | @tsv')
fi

# --- 3. snapshot the attacked disks (--preserve-disk) ------------------------
SNAP_IDS=()
if [[ "$PRESERVE" -eq 1 && ${#TERM_IDS[@]} -gt 0 ]]; then
    step "Snapshotting attached volumes (Topic=$TOPIC)"
    today=$(date +%F)
    for v in "${VOLS[@]}"; do
        IFS=$'\t' read -r id name dev vol <<< "$v"
        tags=$(jq -cn --arg p "$PROJECT" --arg t "$TOPIC" --arg d "$today" --arg n "$name" --arg i "$id" --arg dev "$dev" '
            [{ResourceType:"snapshot", Tags:[
                {Key:"Name",           Value:"\($p)-\($t)-\($n)-\($d)"},
                {Key:"Project",        Value:$p},
                {Key:"Purpose",        Value:"forensic"},
                {Key:"Topic",          Value:$t},
                {Key:"Date",           Value:$d},
                {Key:"SourceName",     Value:$n},
                {Key:"SourceInstance", Value:$i},
                {Key:"SourceDevice",   Value:$dev} ]}]')
        snap=$("${AWS[@]}" ec2 create-snapshot --volume-id "$vol" \
                --description "$PROJECT forensic: $TOPIC $name $dev $today" \
                --tag-specifications "$tags" | jq -r .SnapshotId)
        echo "    $name $dev $vol -> $snap"
        SNAP_IDS+=("$snap")
    done

    # Wait for completion before terminating: the volumes are deleted with the instances.
    while [[ ${#SNAP_IDS[@]} -gt 0 ]]; do
        snaps=$("${AWS[@]}" ec2 describe-snapshots --snapshot-ids "${SNAP_IDS[@]}")
        failed=$(jq -r '[.Snapshots[] | select(.State=="error") | .SnapshotId] | join(", ")' <<< "$snaps")
        [[ -z "$failed" ]] || { echo "Snapshot failed: $failed. Nothing was terminated." >&2; exit 1; }
        pending=$(jq -r '[.Snapshots[] | select(.State!="completed") | "\(.SnapshotId) \(.Progress)"] | join(", ")' <<< "$snaps")
        [[ -z "$pending" ]] && break
        check_timeout "snapshots ($pending)"
        sleep 15
    done
    [[ ${#SNAP_IDS[@]} -gt 0 ]] && echo "    all snapshots completed"
fi

# --- 4. terminate the pair, stop the rest ------------------------------------
if [[ ${#TERM_IDS[@]} -gt 0 ]]; then
    step "Terminating"
    "${AWS[@]}" ec2 terminate-instances --instance-ids "${TERM_IDS[@]}" >/dev/null
    for n in "${TERM_NAMES[@]}"; do echo "    terminating $n"; done
fi
if [[ ${#STOP_IDS[@]} -gt 0 ]]; then
    step "Stopping the other lab boxes"
    "${AWS[@]}" ec2 stop-instances --instance-ids "${STOP_IDS[@]}" >/dev/null
    for n in "${STOP_NAMES[@]}"; do echo "    stopping $n"; done
fi

# Wait until terminated (releases the private IPs the rebuild reuses) and stopped.
WAIT_IDS=("${TERM_IDS[@]}" "${STOP_IDS[@]}")
if [[ ${#WAIT_IDS[@]} -gt 0 ]]; then
    step "Waiting for terminated / stopped"
    while :; do
        busy=$("${AWS[@]}" ec2 describe-instances --instance-ids "${WAIT_IDS[@]}" \
            | jq -r '[ .Reservations[].Instances[] | select(.State.Name!="terminated" and .State.Name!="stopped")
                       | "\((.Tags // [] | map(select(.Key=="Name")) | .[0].Value) // .InstanceId) (\(.State.Name))" ] | join(", ")')
        [[ -z "$busy" ]] && break
        check_timeout "$busy"
        sleep 10
    done
    echo "    done"
fi

# --- 5. clean up ---------------------------------------------------------------
step "Cleaning up"

# Volumes that outlived their instance (DeleteOnTermination off). Reported, not deleted.
if [[ ${#TERM_IDS[@]} -gt 0 ]]; then
    vol_csv=$(printf '%s\n' "${VOLS[@]:-}" | cut -f4 | paste -sd,)
    left=""
    [[ -n "$vol_csv" ]] && left=$("${AWS[@]}" ec2 describe-volumes \
        --filters "Name=volume-id,Values=${vol_csv}" "Name=status,Values=available" \
        | jq -r '[.Volumes[].VolumeId] | join(", ")')
    [[ -n "$left" ]] && echo "WARN: volumes left behind (DeleteOnTermination off; still billed): $left" >&2
fi

for sg in "${SG_IDS[@]}"; do
    mapfile -t tagged < <(
        "${AWS[@]}" ec2 describe-security-group-rules --filters "Name=group-id,Values=${sg}" \
        | jq -r --arg tag "$RULE_TAG" '
            .SecurityGroupRules[] | select(.IsEgress==false and .Description==$tag) |
            [ .SecurityGroupRuleId, .CidrIpv4 ] | @tsv')
    if [[ ${#tagged[@]} -gt 0 && -n "${tagged[0]}" ]]; then
        rids=(); cidrs=()
        for t in "${tagged[@]}"; do IFS=$'\t' read -r rid rcidr <<< "$t"; rids+=("$rid"); cidrs+=("$rcidr"); done
        "${AWS[@]}" ec2 revoke-security-group-ingress --group-id "$sg" --security-group-rule-ids "${rids[@]}" >/dev/null
        echo "    $sg  revoked: ${cidrs[*]}"
    else
        echo "    $sg  no launcher rules"
    fi
done

if mountpoint -q "$MOUNT_POINT" 2>/dev/null; then
    # Lazy unmount: the server is gone, so a normal umount can hang on the dead CIFS session.
    sudo umount -l "$MOUNT_POINT" && echo "    unmounted $MOUNT_POINT" || echo "WARN: couldn't unmount $MOUNT_POINT" >&2
fi

if [[ -f "$STATE_PATH" ]]; then
    rm -f "$STATE_PATH"
    echo "    removed $STATE_PATH"
fi

# --- 6. summary -----------------------------------------------------------------
step "Lab reset"
[[ ${#TERM_IDS[@]} -gt 0 ]] && echo "    terminated: ${TERM_NAMES[*]}"
[[ ${#STOP_IDS[@]} -gt 0 ]] && echo "    stopped:    ${STOP_NAMES[*]}"
[[ ${#SNAP_IDS[@]} -gt 0 ]] && echo "    snapshots:  ${SNAP_IDS[*]}  (Topic=$TOPIC)"
echo "    bring it back with step 1 (rebuild from the golden AMIs)"
