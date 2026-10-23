#!/usr/bin/env bash
# =============================================================================
# start-awslab.sh - Linux launcher for the AWS DFIR lab (bash + AWS CLI).
#
# The Linux counterpart of Start-AwsLab.ps1. Run it on the machine you drive the
# lab from (e.g. the mini PC); it starts the instances, opens both security
# groups to THIS machine's public IP, waits for WinRM, mounts the member
# server's log share, and prints a connection summary.
#
# Like the PowerShell launcher, it finds instances by security-group membership
# (no hard-coded IDs) and only manages rules it tagged 'AWSLab-launcher'.
#
# Requires: awscli v2 (configured creds), jq, curl. For --mount: cifs-utils and
# permission to mount (see "Mounting" in README-linux.md).
# =============================================================================
set -euo pipefail

# --- defaults (override with flags) -----------------------------------------
REGION="ap-southeast-2"
SG_IDS=("sg-02df021a36003f4f1" "sg-0549668744af8e82d")
RULE_TAG="AWSLab-launcher"
NAMES=()                                  # -n/--name; empty = all lab instances
SHARE_HOST="member01"                     # Name tag of the member server
MOUNT=1                                    # mount the log share (use --no-mount to skip)
MOUNT_POINT="${HOME}/lab-logs"
CRED_FILE="${HOME}/.awslab/share.cred"    # CIFS credentials file (chmod 600)
TIMEOUT_MINS=15
STATE_PATH="$(dirname "$(readlink -f "$0")")/lab-state.json"
PROFILE=""                                 # --profile <aws profile>

usage() {
    cat <<'USAGE'
Usage: start-awslab.sh [options]
  -n, --name NAME[,NAME...]   Name tags or instance IDs to start (default: all lab instances)
      --region REGION         AWS region (default: ap-southeast-2)
      --profile NAME          AWS CLI profile
      --share-host NAME       Member-server Name tag hosting the share (default: member01)
      --mount-point PATH      Where to mount the share (default: ~/lab-logs)
      --cred-file PATH        CIFS credentials file (default: ~/.awslab/share.cred)
      --no-mount              Don't mount the log share
      --timeout MINUTES       Wait budget per phase: start, then WinRM (default: 15)
  -h, --help                  This help
USAGE
}

# --- arg parsing -------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        -n|--name)      IFS=',' read -r -a NAMES <<< "$2"; shift 2 ;;
        --region)       REGION="$2"; shift 2 ;;
        --profile)      PROFILE="$2"; shift 2 ;;
        --share-host)   SHARE_HOST="$2"; shift 2 ;;
        --mount-point)  MOUNT_POINT="$2"; shift 2 ;;
        --cred-file)    CRED_FILE="$2"; shift 2 ;;
        --no-mount)     MOUNT=0; shift ;;
        --timeout)      TIMEOUT_MINS="$2"; shift 2 ;;
        -h|--help)      usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage; exit 2 ;;
    esac
done

[[ -n "${BASH_VERSION:-}" ]] || { echo "Run with bash (not sh/ash): bash start-awslab.sh ..." >&2; exit 1; }
command -v aws  >/dev/null || { echo "awscli not found. Install AWS CLI v2." >&2; exit 1; }
command -v jq   >/dev/null || { echo "jq not found. Install jq." >&2; exit 1; }
command -v curl >/dev/null || { echo "curl not found. Install curl." >&2; exit 1; }

AWS=(aws --region "$REGION" --output json)
[[ -n "$PROFILE" ]] && AWS+=(--profile "$PROFILE")

step()  { printf '==> %s\n' "$*"; }
deadline=$(( $(date +%s) + TIMEOUT_MINS * 60 ))
check_timeout() { (( $(date +%s) > deadline )) && { echo "Timed out after ${TIMEOUT_MINS}m waiting for $*." >&2; exit 1; }; return 0; }

# Join SG ids for the filter: Values=sg-a,sg-b
SG_CSV=$(IFS=,; echo "${SG_IDS[*]}")

# Return lab instances as TSV: id \t name \t state \t platform \t public \t private
lab_instances() {
    "${AWS[@]}" ec2 describe-instances \
        --filters "Name=instance.group-id,Values=${SG_CSV}" \
                  "Name=instance-state-name,Values=pending,running,stopping,stopped" \
        | jq -r '
            .Reservations[].Instances[] |
            [ .InstanceId,
              ((.Tags // [] | map(select(.Key=="Name")) | .[0].Value) // .InstanceId),
              .State.Name,
              (.Platform // "linux"),
              (.PublicIpAddress // ""),
              (.PrivateIpAddress // "") ] | @tsv'
}

# Keep only rows whose name or id matches one of NAMES (glob). Reads/writes TSV on stdin/stdout.
name_filter() {
    if [[ ${#NAMES[@]} -eq 0 ]]; then cat; return; fi
    local id name rest
    while IFS=$'\t' read -r id name rest; do
        for pat in "${NAMES[@]}"; do
            # shellcheck disable=SC2053
            if [[ "$name" == $pat || "$id" == $pat ]]; then
                printf '%s\t%s\t%s\n' "$id" "$name" "$rest"; break
            fi
        done
    done
}

# --- 1. find + start ---------------------------------------------------------
step "Finding lab instances in $REGION"
mapfile -t ROWS < <(lab_instances | name_filter)
if [[ ${#ROWS[@]} -eq 0 ]]; then
    if [[ ${#NAMES[@]} -gt 0 ]]; then
        echo "No lab instance matches: ${NAMES[*]}" >&2
        echo "Available:" >&2; lab_instances | cut -f2 | sed 's/^/  /' >&2
    else
        echo "No instances found in ${SG_CSV}. Check region, profile and SG IDs." >&2
    fi
    exit 1
fi
printf '    %-24s %-20s %s\n' "NAME" "ID" "STATE"
for r in "${ROWS[@]}"; do IFS=$'\t' read -r id name state _ <<< "$r"; printf '    %-24s %-20s %s\n' "$name" "$id" "$state"; done

IDS=(); for r in "${ROWS[@]}"; do IDS+=("$(cut -f1 <<< "$r")"); done

step "Starting instances and waiting for running"
"${AWS[@]}" ec2 start-instances --instance-ids "${IDS[@]}" >/dev/null
while :; do
    pending=$("${AWS[@]}" ec2 describe-instances --instance-ids "${IDS[@]}" \
        | jq -r '[ .Reservations[].Instances[] | select(.State.Name!="running") ] | length')
    [[ "$pending" -eq 0 ]] && break
    check_timeout "instances to reach 'running'"
    sleep 5
done
echo "    all running"

# --- 2. public IP ------------------------------------------------------------
step "Resolving your public IP"
MYIP=$(curl -fsS https://checkip.amazonaws.com | tr -d '[:space:]')
[[ "$MYIP" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || { echo "Unexpected public IP: '$MYIP'" >&2; exit 1; }
CIDR="${MYIP}/32"
echo "    $CIDR"

# --- 3. update both security groups -----------------------------------------
step "Updating security groups"
for sg in "${SG_IDS[@]}"; do
    # Our tagged rules (Description == RULE_TAG), as "ruleId<TAB>cidr"
    mapfile -t tagged < <(
        "${AWS[@]}" ec2 describe-security-group-rules \
            --filters "Name=group-id,Values=${sg}" \
        | jq -r --arg tag "$RULE_TAG" '
            .SecurityGroupRules[] |
            select(.IsEgress==false and .Description==$tag) |
            [ .SecurityGroupRuleId, .CidrIpv4 ] | @tsv')

    have_current=0
    for t in "${tagged[@]:-}"; do
        [[ -z "$t" ]] && continue
        IFS=$'\t' read -r rid rcidr <<< "$t"
        if [[ "$rcidr" == "$CIDR" ]]; then
            have_current=1
        else
            "${AWS[@]}" ec2 revoke-security-group-ingress \
                --group-id "$sg" --security-group-rule-ids "$rid" >/dev/null
            echo "    $sg  revoked old: $rcidr"
        fi
    done

    if [[ "$have_current" -eq 1 ]]; then
        echo "    $sg  already allows $CIDR"
    else
        # Tag the rule via its description. Tolerate an existing (untagged) duplicate:
        # AWS dedupes by rule content, not description, so a hand-made rule for this IP
        # would otherwise abort the run.
        if err=$("${AWS[@]}" ec2 authorize-security-group-ingress --group-id "$sg" \
                    --ip-permissions "IpProtocol=-1,IpRanges=[{CidrIp=${CIDR},Description=${RULE_TAG}}]" \
                    2>&1 >/dev/null); then
            echo "    $sg  allowed all traffic from $CIDR"
        elif grep -q 'InvalidPermission.Duplicate' <<< "$err"; then
            echo "    $sg  already allows $CIDR (existing untagged rule)"
        else
            echo "$err" >&2; exit 1
        fi
    fi
done

# --- 4. wait for WinRM on Windows hosts -------------------------------------
step "Waiting for WinRM (5985) on Windows hosts"
mapfile -t ROWS < <(lab_instances | name_filter)      # refresh: public IPs changed
tcp_open() { timeout 3 bash -c ">/dev/tcp/$1/$2" 2>/dev/null; }

# Fresh budget for this step, so a slow instance start doesn't eat the WinRM wait.
# Poll every host each pass (not one after another) and report as each comes up.
declare -A WAIT_IP=() WAIT_NAME=()
for r in "${ROWS[@]}"; do
    IFS=$'\t' read -r id name state platform public private <<< "$r"
    [[ "$platform" == "windows" ]] || continue
    [[ -z "$public" ]] && { echo "    $name has no public IP; skipping"; continue; }
    WAIT_IP[$id]="$public"; WAIT_NAME[$id]="$name"
done
GONE=()
winrm_deadline=$(( $(date +%s) + TIMEOUT_MINS * 60 ))
while (( ${#WAIT_IP[@]} )); do
    for id in "${!WAIT_IP[@]}"; do
        if tcp_open "${WAIT_IP[$id]}" 5985; then
            echo "    ${WAIT_NAME[$id]}  WinRM up"; unset "WAIT_IP[$id]"
        fi
    done
    (( ${#WAIT_IP[@]} )) || break
    # A box that stopped or was terminated mid-wait will never answer; drop it now
    # instead of burning the whole timeout on it.
    while IFS=$'\t' read -r id st reason; do
        [[ -v "WAIT_IP[$id]" && "$st" != "running" ]] || continue
        echo "WARN: ${WAIT_NAME[$id]} ($id) is now $st; it won't come up. $reason" >&2
        GONE+=("${WAIT_NAME[$id]}"); unset "WAIT_IP[$id]"
    done < <("${AWS[@]}" ec2 describe-instances --instance-ids "${!WAIT_IP[@]}" \
             | jq -r '.Reservations[].Instances[] | [.InstanceId, .State.Name, ((.StateTransitionReason // "") + " " + (.StateReason.Message // ""))] | @tsv')
    (( ${#WAIT_IP[@]} )) || break
    (( $(date +%s) > winrm_deadline )) && break
    sleep 10
done

# Don't abort the whole launch on one stuck box: say why it looks stuck, then carry on
# so the summary, state file and the other hosts still work.
for id in "${!WAIT_IP[@]}"; do
    name="${WAIT_NAME[$id]}"; ip="${WAIT_IP[$id]}"
    echo "WARN: $name : no WinRM on $ip:5985 after ${TIMEOUT_MINS} min." >&2
    "${AWS[@]}" ec2 describe-instance-status --instance-ids "$id" \
        | jq -r --arg n "$name" '.InstanceStatuses[0] // {} | "    \($n)  EC2 status checks: system=\(.SystemStatus.Status // "n/a")  instance=\(.InstanceStatus.Status // "n/a")"' || true
    if tcp_open "$ip" 3389; then
        echo "    $name  RDP (3389) answers, so Windows is up: WinRM service/listener or its firewall rule is off. RDP in and run: Enable-PSRemoting -Force"
    else
        echo "    $name  RDP (3389) doesn't answer either: still booting, hung, or the SG/NACL blocks you. Last console lines:"
        "${AWS[@]}" ec2 get-console-output --instance-id "$id" --query Output --output text 2>/dev/null \
            | tr -d '\r' | grep -v '^\s*$' | tail -n 5 | sed 's/^/        /' || echo "        (no console output yet)"
    fi
done
if (( ${#WAIT_IP[@]} )); then
    stuck=(); for id in "${!WAIT_IP[@]}"; do stuck+=("${WAIT_NAME[$id]}"); done
    echo "WARN: continuing without WinRM on: ${stuck[*]}. Re-run later or raise --timeout." >&2
fi
if (( ${#GONE[@]} )); then
    echo "WARN: lost during launch: ${GONE[*]}. If terminated, rebuild with the PowerShell launcher: ./Start-AwsLab.ps1 -RebuildIfMissing" >&2
    mapfile -t ROWS < <(lab_instances | name_filter)   # keep vanished boxes out of the summary and state file
fi

# --- 5. summary + state ------------------------------------------------------
step "Lab is up"
printf '    %-24s %-8s %-16s %-16s %s\n' "NAME" "OS" "PRIVATE" "PUBLIC" "ACCESS"
json_items=()
for r in "${ROWS[@]}"; do
    IFS=$'\t' read -r id name state platform public private <<< "$r"
    if [[ "$platform" == "windows" ]]; then os="Windows"; access="WinRM 5985"; else os="Linux"; access="SSH 22"; fi
    printf '    %-24s %-8s %-16s %-16s %s\n' "$name" "$os" "${private:--}" "${public:--}" "$access"
    json_items+=("$(jq -n --arg n "$name" --arg i "$id" --arg o "$os" \
        --arg pr "$private" --arg pu "$public" --arg a "$access" \
        '{Name:$n,InstanceId:$i,Os:$o,PrivateIp:$pr,PublicIp:$pu,Access:$a}')")
done
printf '%s\n' "$(jq -n --arg t "$(date -Iseconds)" --arg r "$REGION" --arg ip "$MYIP" \
    --argjson items "$(printf '%s\n' "${json_items[@]}" | jq -s '.')" \
    '{LaunchedAt:$t,Region:$r,MyIp:$ip,Instances:$items}')" > "$STATE_PATH"
echo "    state written to $STATE_PATH"

# connect hints
echo "Connect:"
for r in "${ROWS[@]}"; do
    IFS=$'\t' read -r id name state platform public private <<< "$r"
    [[ -z "$public" ]] && continue
    if [[ "$platform" == "windows" ]]; then
        echo "  $name:  evil-winrm -i $public -u Administrator    # or: xfreerdp /v:$public /u:Administrator"
    else
        echo "  $name:  ssh kali@$public"
    fi
done

# --- 6. mount the member server's log share ---------------------------------
if [[ "$MOUNT" -eq 1 ]]; then
    share_ip=""
    for r in "${ROWS[@]}"; do
        IFS=$'\t' read -r id name state platform public private <<< "$r"
        [[ "$name" == "$SHARE_HOST" ]] && share_ip="$public"
    done
    if [[ -z "$share_ip" ]]; then
        echo "WARN: share host '$SHARE_HOST' not among started instances; skipping mount." >&2
    elif [[ ! -f "$CRED_FILE" ]]; then
        echo "WARN: no credentials file at $CRED_FILE; skipping mount (see README-linux.md)." >&2
    else
        step "Mounting //$share_ip/LabLogs at $MOUNT_POINT"
        mkdir -p "$MOUNT_POINT"
        # Already mounted from this same share (member01 kept its IP) and still answering?
        # Keep it: no unmount, no sudo prompt.
        if mountpoint -q "$MOUNT_POINT" \
           && [[ "$(findmnt -n -o SOURCE --target "$MOUNT_POINT" 2>/dev/null)" == "//${share_ip}/LabLogs" ]] \
           && timeout 5 ls "$MOUNT_POINT" >/dev/null 2>&1; then
            echo "    already mounted; leaving it"
        else
            # Public IP changes each launch, so unmount a stale mount at this point first.
            mountpoint -q "$MOUNT_POINT" && sudo umount "$MOUNT_POINT" 2>/dev/null || true
            if sudo mount -t cifs "//${share_ip}/LabLogs" "$MOUNT_POINT" \
                   -o "credentials=${CRED_FILE},vers=3.0,uid=$(id -u),gid=$(id -g)" 2>/tmp/awslab-mount.err; then
                echo "    mounted at $MOUNT_POINT"
            else
                echo "WARN: mount failed: $(cat /tmp/awslab-mount.err)" >&2
                echo "WARN: if it timed out, your ISP may block outbound SMB (445); logs still collect over WinRM." >&2
            fi
        fi
    fi
fi
