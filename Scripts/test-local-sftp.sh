#!/usr/bin/env bash
set -euo pipefail

# A real OpenSSH round trip with disposable keys, agent, server, and files.
# Nothing is written to ~/.ssh or a saved BitMatch destination.
ROOT=$(cd "$(dirname "$0")/.." && pwd)
SCRATCH=$(mktemp -d /private/tmp/bitmatch-sftp-smoke.XXXXXX)
SSHD_PID=
AGENT_PID=
RACE_PID=
cleanup() {
  [[ -z "$RACE_PID" ]] || { kill "$RACE_PID" 2>/dev/null || true; wait "$RACE_PID" 2>/dev/null || true; }
  [[ -z "$AGENT_PID" ]] || { kill "$AGENT_PID" 2>/dev/null || true; wait "$AGENT_PID" 2>/dev/null || true; }
  [[ -z "$SSHD_PID" ]] || { kill "$SSHD_PID" 2>/dev/null || true; wait "$SSHD_PID" 2>/dev/null || true; }
  if [[ "$SCRATCH" == /private/tmp/bitmatch-sftp-smoke.* ]]; then
    rm -rf -- "$SCRATCH"
  fi
}
trap cleanup EXIT

chmod 700 "$SCRATCH"
mkdir "$SCRATCH/remote"
touch "$SCRATCH/remote/.bitmatch-disposable-sftp-server"
ssh-keygen -q -t ed25519 -N '' -f "$SCRATCH/host_key"
ssh-keygen -q -t ed25519 -N '' -f "$SCRATCH/client_key"
cp "$SCRATCH/client_key.pub" "$SCRATCH/authorized_keys"
chmod 600 "$SCRATCH/authorized_keys"

PORT=$(python3 -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
read -r KEY_TYPE KEY_DATA _ < "$SCRATCH/host_key.pub"
printf '[127.0.0.1]:%s %s %s\n' "$PORT" "$KEY_TYPE" "$KEY_DATA" > "$SCRATCH/known_hosts"

cat > "$SCRATCH/force-command.sh" <<EOF
#!/bin/sh
case "\$SSH_ORIGINAL_COMMAND" in
  *sftp-server*|internal-sftp) exec /usr/libexec/sftp-server -e -d "$SCRATCH/remote" ;;
  *) cd "$SCRATCH/remote" || exit 1; exec /bin/sh -c "\$SSH_ORIGINAL_COMMAND" ;;
esac
EOF
chmod 700 "$SCRATCH/force-command.sh"
cat > "$SCRATCH/sshd_config" <<EOF
Port $PORT
ListenAddress 127.0.0.1
HostKey $SCRATCH/host_key
PidFile $SCRATCH/sshd.pid
AuthorizedKeysFile $SCRATCH/authorized_keys
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
UsePAM no
StrictModes no
PermitRootLogin no
AllowUsers $(id -un)
AllowTcpForwarding no
AllowAgentForwarding no
X11Forwarding no
PermitTTY no
PermitUserRC no
Subsystem sftp /usr/libexec/sftp-server
ForceCommand $SCRATCH/force-command.sh
LogLevel ERROR
EOF
/usr/sbin/sshd -t -f "$SCRATCH/sshd_config"
/usr/sbin/sshd -D -e -f "$SCRATCH/sshd_config" > "$SCRATCH/sshd.log" 2>&1 &
SSHD_PID=$!

READY=0
for _ in {1..30}; do
  if /usr/bin/ssh -i "$SCRATCH/client_key" -o IdentitiesOnly=yes -o BatchMode=yes \
      -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$SCRATCH/known_hosts" \
      -o GlobalKnownHostsFile=/dev/null -o PasswordAuthentication=no \
      -o KbdInteractiveAuthentication=no -p "$PORT" -l "$(id -un)" \
      -T -- 127.0.0.1 pwd > /dev/null 2>&1; then
    READY=1
    break
  fi
  sleep 0.1
done
if [[ "$READY" != 1 ]]; then
  cat "$SCRATCH/sshd.log" >&2
  echo "Disposable localhost sshd did not start" >&2
  exit 1
fi

/usr/bin/ssh-agent -D -a "$SCRATCH/agent.sock" > "$SCRATCH/agent.log" 2>&1 &
AGENT_PID=$!
for _ in {1..30}; do
  [[ ! -S "$SCRATCH/agent.sock" ]] || break
  sleep 0.1
done
SSH_AUTH_SOCK="$SCRATCH/agent.sock" /usr/bin/ssh-add "$SCRATCH/client_key" > /dev/null

# Exercise the exact bundled helper through a disposable localhost SSH server.
# No test writes to the user's SSH configuration or a saved destination.
RACE_SOURCE="$SCRATCH/race-source.bin"
dd if=/dev/urandom of="$RACE_SOURCE" bs=1048576 count=16 status=none
printf 'VICTIM-UNCHANGED' > "$SCRATCH/remote/victim"
cp "$SCRATCH/remote/victim" "$SCRATCH/victim-expected"
remote_helper() {
  local remote_command
  remote_command=$(python3 -c 'import pathlib,shlex,sys; print("python3 -c " + shlex.quote(pathlib.Path(sys.argv[1]).read_text()) + " " + " ".join(shlex.quote(s) for s in sys.argv[2:]))' "$ROOT/BitMatch/Resources/SFTPRemoteHelper.py" "$@")
  /usr/bin/ssh -i "$SCRATCH/client_key" -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$SCRATCH/known_hosts" \
    -o GlobalKnownHostsFile=/dev/null -o PasswordAuthentication=no \
    -o KbdInteractiveAuthentication=no -p "$PORT" -l "$(id -un)" \
    -T -- 127.0.0.1 "$remote_command"
}

remote_helper check
remote_helper mkdir '["Backups","Jobs"]'
remote_helper upload '["Backups","Jobs","normal"]' < "$RACE_SOURCE"
ln -s /dev/null "$SCRATCH/remote/Backups/Jobs/device-link"
if remote_helper upload '["Backups","Jobs","device-link"]' < "$RACE_SOURCE"; then
  echo 'Exclusive upload followed a preexisting symlink to /dev/null' >&2
  exit 1
fi
ln -s missing-target "$SCRATCH/remote/Backups/Jobs/dangling-link"
if remote_helper upload '["Backups","Jobs","dangling-link"]' < "$RACE_SOURCE"; then
  echo 'Exclusive upload followed a dangling symlink' >&2
  exit 1
fi
[[ ! -e "$SCRATCH/remote/Backups/Jobs/missing-target" ]]
printf 'EXISTING-UNCHANGED' > "$SCRATCH/remote/Backups/Jobs/existing"
if remote_helper upload '["Backups","Jobs","existing"]' < "$RACE_SOURCE"; then
  echo 'Exclusive upload replaced an existing regular file' >&2
  exit 1
fi
[[ "$(cat "$SCRATCH/remote/Backups/Jobs/existing")" == 'EXISTING-UNCHANGED' ]]
remote_helper inspect '["Backups","Jobs","normal"]' >&2
remote_helper download '["Backups","Jobs","normal"]' > "$SCRATCH/downloaded"
cmp "$RACE_SOURCE" "$SCRATCH/downloaded"
remote_helper inspect '["Backups","Jobs","normal"]' > "$SCRATCH/length"
[[ "$(cat "$SCRATCH/length")" == "$(stat -f %z "$RACE_SOURCE")" ]]
remote_helper promote '["Backups","Jobs","normal"]' '["Backups","Jobs","final"]'
[[ "$(remote_helper same '["Backups","Jobs","normal"]' '["Backups","Jobs","final"]')" == '__BITMATCH_SAME__' ]]
[[ "$(remote_helper same '["Backups","Jobs","existing"]' '["Backups","Jobs","final"]')" == '__BITMATCH_DIFFERENT__' ]]
[[ "$(remote_helper same '["Backups","Jobs","missing"]' '["Backups","Jobs","final"]')" == '__BITMATCH_DIFFERENT__' ]]
cmp "$RACE_SOURCE" "$SCRATCH/remote/Backups/Jobs/final"
cmp "$RACE_SOURCE" "$SCRATCH/remote/Backups/Jobs/normal"

if remote_helper download '["Backups","Jobs","device-link"]' > "$SCRATCH/unsafe-download"; then
  echo 'Readback followed a preexisting symlink to /dev/null' >&2; exit 1
fi
mkdir "$SCRATCH/helper-outside"
ln -s "$SCRATCH/helper-outside" "$SCRATCH/remote/Backups/linked-parent"
if remote_helper upload '["Backups","linked-parent","escaped"]' < "$RACE_SOURCE"; then
  echo 'Helper followed ancestor symlink' >&2; exit 1
fi
[[ -z "$(ls -A "$SCRATCH/helper-outside")" ]]
ln -s "$SCRATCH/helper-outside" "$SCRATCH/remote/Backups/Jobs/directory-link"
if remote_helper promote '["Backups","Jobs","normal"]' '["Backups","Jobs","directory-link"]'; then
  echo 'Helper followed final directory symlink' >&2; exit 1
fi
[[ -z "$(ls -A "$SCRATCH/helper-outside")" ]]
if remote_helper promote '["Backups","Jobs","normal"]' '["Backups","Jobs","final"]'; then
  echo 'Helper replaced an existing final' >&2; exit 1
fi
cmp "$RACE_SOURCE" "$SCRATCH/remote/Backups/Jobs/final"

mkfifo "$SCRATCH/helper-upload.fifo"
remote_helper upload '["Backups","Jobs","swapped-upload"]' \
  < "$SCRATCH/helper-upload.fifo" > "$SCRATCH/helper-upload.out" 2> "$SCRATCH/helper-upload.err" &
RACE_PID=$!
exec 9> "$SCRATCH/helper-upload.fifo"
OPENED=0
for _ in {1..100}; do
  if [[ -e "$SCRATCH/remote/Backups/Jobs/swapped-upload" ]]; then OPENED=1; break; fi
  sleep 0.05
done
[[ "$OPENED" == 1 ]] || { echo 'Helper did not open upload FD' >&2; exit 1; }
mv "$SCRATCH/remote/Backups/Jobs/swapped-upload" "$SCRATCH/remote/Backups/Jobs/upload-inode"
ln -s "$SCRATCH/remote/victim" "$SCRATCH/remote/Backups/Jobs/swapped-upload"
cat "$RACE_SOURCE" >&9
exec 9>&-
wait "$RACE_PID"
RACE_PID=
cmp "$RACE_SOURCE" "$SCRATCH/remote/Backups/Jobs/upload-inode"
cmp "$SCRATCH/victim-expected" "$SCRATCH/remote/victim"

mkfifo "$SCRATCH/helper-download.fifo"
remote_helper download '["Backups","Jobs","normal"]' \
  > "$SCRATCH/helper-download.fifo" 2> "$SCRATCH/helper-download.err" &
RACE_PID=$!
exec 8< "$SCRATCH/helper-download.fifo"
dd if=/dev/fd/8 of="$SCRATCH/helper-download.bin" bs=4096 count=1 status=none
mv "$SCRATCH/remote/Backups/Jobs/normal" "$SCRATCH/remote/Backups/Jobs/download-inode"
ln -s "$SCRATCH/remote/victim" "$SCRATCH/remote/Backups/Jobs/normal"
cat <&8 >> "$SCRATCH/helper-download.bin"
exec 8<&-
wait "$RACE_PID"
RACE_PID=
cmp "$RACE_SOURCE" "$SCRATCH/helper-download.bin"
cmp "$SCRATCH/victim-expected" "$SCRATCH/remote/victim"
echo 'Pinned-directory remote helper upload, promotion, and readback probes passed.'

if [[ "${BITMATCH_SFTP_HELPER_ONLY:-0}" == 1 ]]; then
  exit 0
fi

TEST_RUNNER_BITMATCH_LIVE_SFTP_TEST=1 \
TEST_RUNNER_BITMATCH_LIVE_SFTP_PORT="$PORT" \
TEST_RUNNER_BITMATCH_LIVE_SFTP_KNOWN_HOSTS="$SCRATCH/known_hosts" \
TEST_RUNNER_BITMATCH_LIVE_SFTP_AGENT_SOCK="$SCRATCH/agent.sock" \
TEST_RUNNER_BITMATCH_LIVE_SFTP_REMOTE_DIR="$SCRATCH/remote" \
xcodebuild -quiet -project "$ROOT/BitMatch.xcodeproj" \
  -derivedDataPath "$SCRATCH/derived-data" -resultBundlePath "$SCRATCH/live.xcresult" \
  test -scheme BitMatch -destination 'platform=macOS' \
  -only-testing:BitMatchTests/SFTPRemoteBackupLiveTests \
  -parallel-testing-enabled NO CODE_SIGNING_ALLOWED=NO

xcrun xcresulttool get test-results summary --path "$SCRATCH/live.xcresult" --format json |
  python3 -c 'import json, sys; s=json.load(sys.stdin); assert (s["passedTests"], s["failedTests"], s["skippedTests"]) == (1, 0, 0), s; print("Live localhost SFTP test passed (1/1).")'
