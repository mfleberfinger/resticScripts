#!/usr/bin/env bash
# restic backup of home and the files currently on the external drive
# (expected to move to a directory on the RAID0 array).
#
# One script covers both runs. The flag selects the repository, the log
# name, and where the result goes:
#
#   --remote
#     Daily backup to the VPS. Writes logs/daily-vps-backup.log and emails
#     success or failure with msmtp. On failure the mail reminds you to
#     review the log. Schedule once a day.
#     Example crontab:
#       PLACEHOLDER_MINUTE PLACEHOLDER_HOUR * * * /path/to/backup.sh --remote
#
#   --local
#     Manual backup to the external drive, about once a week. Writes
#     logs/manual-external-backup.log, prints success or the errors, and
#     reminds you to check the log. Does not send email.
#
# The password file from the restic command is the relative path
# "resticPassword". Keep that file in this script's directory.
#
# Replace every PLACEHOLDER_* value before use. Mail settings are required
# only for --remote. Each run checks only the repository it uses.
set -uo pipefail

usage() {
  cat <<EOF >&2
usage: $(basename "$0") (--remote | --local)

  --remote    Backup to the VPS. Intended to be automated. Email the result with msmtp.
  --local     Manual backup to the external drive. Print the result.
EOF
}

if [[ $# -ne 1 ]]; then
  usage
  exit 2
fi

case "$1" in
  --remote)
    MODE="remote"
    ;;
  --local)
    MODE="local"
    ;;
  -h|--help)
    usage
    exit 0
    ;;
  *)
    usage
    exit 2
    ;;
esac

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
cd "${SCRIPT_DIR}"

# Home directory.
DIR_HOME="PLACEHOLDER_HOME_DIRECTORY"

# Files currently on the external drive. Probably move them to the RAID0 array.
DIR_SECOND="PLACEHOLDER_SECOND_BACKUP_DIRECTORY"

# msmtp account and envelope headers. Used only with --remote.
MSMTP_ACCOUNT="PLACEHOLDER_MSMTP_ACCOUNT"
EMAIL_FROM="PLACEHOLDER_EMAIL_FROM"
EMAIL_TO="PLACEHOLDER_EMAIL_RECIPIENT"

# restic -r repositories.
REPOSITORY_VPS="PLACEHOLDER_VPS_REPOSITORY"
REPOSITORY_EXTERNAL="PLACEHOLDER_EXTERNAL_DRIVE_REPOSITORY"

LOG_DIR="${SCRIPT_DIR}/logs"

case "${MODE}" in
  remote)
    REPOSITORY="${REPOSITORY_VPS}"
    LOG_STEM="daily-vps-backup"
    ;;
  local)
    REPOSITORY="${REPOSITORY_EXTERNAL}"
    LOG_STEM="manual-external-backup"
    ;;
esac

LOG_FILE="${LOG_DIR}/${LOG_STEM}.log"

abort_if_placeholder() {
  local name value missing=0
  for name in "$@"; do
    value="${!name}"
    if [[ "${value}" == PLACEHOLDER_* ]]; then
      printf 'error: replace %s (currently "%s") before running this script.\n' "${name}" "${value}" >&2
      missing=1
    fi
  done
  if [[ "${missing}" -ne 0 ]]; then
    exit 1
  fi
}

if [[ "${MODE}" == "remote" ]]; then
  abort_if_placeholder REPOSITORY DIR_SECOND MSMTP_ACCOUNT EMAIL_FROM EMAIL_TO DIR_HOME
else
  abort_if_placeholder REPOSITORY DIR_SECOND DIR_HOME
fi

mkdir -p "${LOG_DIR}"

stdout_file="$(mktemp)"
stderr_file="$(mktemp)"
trap 'rm -f "${stdout_file}" "${stderr_file}"' EXIT

# --iexclude options keep passwords out of the home backup.
restic -r "${REPOSITORY}" \
  --verbose --verbose \
  --password-file="resticPassword" \
  backup \
  --iexclude="*.kdbx" \
  --iexclude="resticPassword" \
  --compression="max" \
  "${DIR_HOME}" "${DIR_SECOND}" \
  >"${stdout_file}" 2>"${stderr_file}"
exit_code=$?

# Drop the previous run's log. Timestamped failure logs use other names
# and are left in place.
if [[ -f "${LOG_FILE}" ]]; then
  rm -f "${LOG_FILE}"
fi

{
  printf 'exit_code=%s\n' "${exit_code}"
  printf '===== stdout =====\n'
  cat "${stdout_file}"
  printf '===== stderr =====\n'
  cat "${stderr_file}"
} > "${LOG_FILE}"

final_log="${LOG_FILE}"
if [[ "${exit_code}" -ne 0 ]]; then
  timestamp="$(date +%Y%m%d-%H%M%S)"
  final_log="${LOG_DIR}/${LOG_STEM}-${timestamp}.log"
  if [[ -e "${final_log}" ]]; then
    final_log="${LOG_DIR}/${LOG_STEM}-${timestamp}-$$.log"
  fi
  mv "${LOG_FILE}" "${final_log}"
fi

if [[ "${MODE}" == "remote" ]]; then
  if [[ "${exit_code}" -eq 0 ]]; then
    subject="Restic daily backup succeeded"
    printf -v body '%s\n' \
      "The daily restic backup to the VPS succeeded." \
      "Exit code: ${exit_code}" \
      "Log file: ${final_log}"
  else
    subject="Restic daily BACKUP FAILED"
    printf -v body '%s\n' \
      "The daily restic backup to the VPS failed." \
      "Remember to review the log file." \
      "Exit code: ${exit_code}" \
      "Log file: ${final_log}"
  fi

  if ! msmtp --account="${MSMTP_ACCOUNT}" --read-recipients <<EOF
From: ${EMAIL_FROM}
To: ${EMAIL_TO}
Subject: ${subject}

${body}
EOF
  then
    # These errors probably go to the journal (journalctl).
    printf 'error: msmtp failed to send the status email.\n' >&2
    printf '%s\n' "${body}" >&2
    if [[ "${exit_code}" -eq 0 ]]; then
      exit 1
    fi
  fi
else
  if [[ "${exit_code}" -eq 0 ]]; then
    printf 'Backup succeeded (exit code %s).\n' "${exit_code}"
  else
    printf 'Backup failed (exit code %s).\n' "${exit_code}" >&2
    if [[ -s "${stderr_file}" ]]; then
      cat "${stderr_file}" >&2
    fi
    printf 'Reminder: check the log file: %s\n' "${final_log}" >&2
  fi
fi

exit "${exit_code}"
