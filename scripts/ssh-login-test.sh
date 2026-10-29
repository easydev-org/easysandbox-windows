#!/usr/bin/env bash
# Prove SSH works end to end, by logging in - not by reading a banner.
#
# A banner only says something on that port spoke SSH first. It does not say the account
# exists, that password authentication is enabled, that the shell starts, or that the
# session survives. sshpass asks all of that at once and prints the reason when it fails:
#
#   Permission denied (publickey,password)  user exists, password auth offered, wrong password
#   Permission denied (publickey)           password auth is disabled in sshd_config
#   No such user                            the account is not there
#   Connection refused / timed out          nothing listening, or the port unreachable
#
# Same pattern as the bake, which has done exactly this from the start.
set -u

PORT="${PORT:-2222}"
HOST="${HOST:-127.0.0.1}"
USER_NAME="${USER_NAME:-docker}"
PASSWORD="${PASSWORD:-admin}"
ATTEMPTS="${ATTEMPTS:-6}"

for i in $(seq 1 "$ATTEMPTS"); do
  echo "  attempt $i/$ATTEMPTS: ssh $USER_NAME@$HOST:$PORT"
  out=$(sshpass -p "$PASSWORD" ssh -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null -o ConnectTimeout=20 \
        -o PreferredAuthentications=password -o PubkeyAuthentication=no \
        -p "$PORT" "$USER_NAME@$HOST" "echo SSH-OK; whoami; hostname" 2>&1 || true)
  flat=$(printf "%s" "$out" | tr -d "\r" | tr "\n" " ")
  echo "    -> ${flat:-no output}"
  case "$out" in
    *SSH-OK*)
      echo "  VERIFIED: logged in as $USER_NAME, shell responded"
      exit 0
      ;;
  esac
  sleep 15
done

echo "  NOT VERIFIED: no successful login in $ATTEMPTS attempts"
exit 1
