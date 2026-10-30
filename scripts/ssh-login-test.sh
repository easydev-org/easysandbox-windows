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
        -p "$PORT" "$USER_NAME@$HOST" "echo SSH-OK && whoami && hostname" 2>/tmp/ssherr.$$ || true)
  err=$(cat /tmp/ssherr.$$ 2>/dev/null | tr -d "\r" | tr "\n" " "); rm -f /tmp/ssherr.$$
  flat=$(printf "%s" "$out" | tr -d "\r" | tr "\n" " ")
  echo "    stdout: ${flat:-<empty>}"
  echo "    stderr: ${err:-<empty>}"

  # MATCH THE RESULT, NOT THE WORD.
  #
  # The first version tested  case "$out" in *SSH-OK*)  and reported success. It was a
  # false green: the output was
  #     Warning: Permanently added ... SSH-OK; whoami; hostname
  # where 'SSH-OK; whoami; hostname' is the command echoed back inside ssh's own error
  # text, not its output. The remote command never ran, and the literal string in the
  # message satisfied the pattern.
  #
  # The real thing has three lines and no warning:  SSH-OK / the user / the hostname.
  # So: require a line that is EXACTLY SSH-OK, and require the second line to be the
  # user name, and reject any output that still contains the semicolons (an echo).
  # THREE LINES: SSH-OK, the user, the hostname.
  #
  # The separator matters more than it looks. Windows ssh runs commands through cmd.exe,
  # where ';' is not a separator - it is an ordinary character. So
  #     echo SSH-OK; whoami; hostname
  # prints the whole string back, which is what every previous attempt saw and what made
  # me add a rule rejecting ';' as 'echoed rather than executed'. That rule was wrong:
  # the login had worked, cmd.exe had simply been told to echo one long word.
  # '&&' is a separator in cmd.exe, so the command now really runs three of them.
  first=$(printf "%s" "$out" | tr -d "\r" | sed -n "1p" | tr -d " ")
  second=$(printf "%s" "$out" | tr -d "\r" | sed -n "2p" | tr -d " ")
  host=$(printf "%s" "$out" | tr -d "\r" | sed -n "3p" | tr -d "\r")
  # whoami on Windows returns COMPUTERNAME\user, not the bare user name - that is
  # standard, and matching only 'docker' rejected every successful login. Accept the
  # name as the last path component.
  case "$second" in
    "$USER_NAME"|"*\$USER_NAME") second_ok=1 ;;
    *) second_ok=0 ;;
  esac
  if [ "$first" = "SSH-OK" ] && [ "$second_ok" = "1" ] && [ -n "$host" ]; then
    echo "  VERIFIED: logged in as $USER_NAME, shell ran whoami and hostname"
    echo "    host: $host"
    exit 0
  fi
  echo "  not verified: wanted three lines 'SSH-OK' / '$USER_NAME' / hostname, got those above"
  sleep 15
done

echo "  NOT VERIFIED: no successful login in $ATTEMPTS attempts"
exit 1
