# Privileged transaction contract

## State schema

Existing scripts changed host state directly and had no common persistent schema. The target schema is one mode-0700 directory per run containing `status`, `events.log`, optional snapshots, `checkpoint`, and `recovery.txt`. Files are mode 0600 and contain stage names, not command arguments or secret values.

Set `SAFE_STATE_ROOT` to migrate the journal offline to another protected directory. Existing host state needs no online migration.

## Recovery

`COMPLETE` means the script verified its final state. `RECOVERABLE` means an error or signal stopped the run. Read `checkpoint` and `recovery.txt`, inspect the protected snapshots, repair the named boundary, then rerun. A per-operation `flock` rejects concurrent execution.

For deterministic failure testing, set `USEFUL_SHELL_FAIL_STAGE` to a documented stage name. The harness must use fixture commands and a temporary `SAFE_STATE_ROOT`; never inject failures on a production host.

## Secret and report policy

Use environment variables, standard input, or mode-0600 descriptor files for credentials. Do not put credentials in command arguments. The transaction logger records only the stage and executable basename. Scripts set `umask 077`; generated logs, temporary files, ACL reports, and recovery data must remain private.
