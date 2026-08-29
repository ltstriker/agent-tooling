#!/usr/bin/env bash
# Shared lock-state transformations for the verdict runner and its prompt hook.
# Source this file; it performs no work on load.

# One protocol, consumed by both the runner and Stop gate. The runner reserves the
# final minute for group teardown, so its configured model timeout must fit below this
# full lease ceiling rather than publishing a deadline the gate will reject.
# shellcheck disable=SC2034 # Public constants for scripts that source this library.
verdict_audit_lock_max_seconds=3600
# shellcheck disable=SC2034 # Public constants for scripts that source this library.
verdict_audit_deadline_slack_seconds=60

# Persisted decimal fields are untrusted. Keep them below 10^18 so Bash 3's signed
# integer arithmetic cannot wrap a huge value into the live deadline window. The caller
# still enforces its much tighter semantic bound relative to the current epoch.
verdict_audit_epoch_is_bounded() {
  [[ "$1" =~ ^[1-9][0-9]*$ && ${#1} -le 18 ]]
}

# Snapshot workspace state without letting a FIFO, symlink, or replacement pathname
# choose what gets parsed. `record` mode validates the bytes before command substitution
# can erase trailing LFs. `json` mode prefixes the selected inode's mtime, keeping
# freshness and content in one snapshot. Raw NUL cannot be transported through Bash.
verdict_audit_read_regular_state() {  # path max-bytes record|json
  command -v perl >/dev/null 2>&1 || return 1
  perl -MFcntl=:DEFAULT -e '
    my ($path, $max, $mode) = @ARGV;
    exit 1 unless $max =~ /^[1-9][0-9]*$/
      && ($mode eq "record" || $mode eq "record_snapshot" || $mode eq "json");
    $SIG{ALRM} = sub { exit 1 };
    alarm 1;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDONLY | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    my $body = "";
    while (length($body) <= $max) {
      my $chunk = "";
      my $count = sysread($fh, $chunk, $max + 1 - length($body));
      exit 1 unless defined $count;
      last if $count == 0;
      $body .= $chunk;
    }
    exit 1 if length($body) > $max;
    my @named_after = lstat($path);
    exit 1 unless @named_after
      && $opened[0] == $named_after[0] && $opened[1] == $named_after[1];
    alarm 0;
    exit 1 if $body =~ /\0/;
    if ($mode eq "record" || $mode eq "record_snapshot") {
      exit 1 if $body =~ /\r/;
      $body =~ s/\n\z//;
      exit 1 if $body eq "" || index($body, "\n") >= 0;
      print $opened[9], "\n" if $mode eq "record_snapshot";
      print $body;
    } else {
      print $opened[9], "\n", $body;
    }
  ' "$1" "$2" "$3"
}

# Writers use one final LF; legacy records without it remain readable, while CR, an
# embedded LF, or a second blank record fails.
verdict_audit_read_single_record() {  # record-path
  verdict_audit_read_regular_state "$1" 4096 record
}

verdict_audit_read_single_record_snapshot() {  # record-path
  verdict_audit_read_regular_state "$1" 4096 record_snapshot
}

# JSON dossiers may be formatted across lines. The caller parses the returned
# "mtime LF body" snapshot from memory and never opens the shared pathname with jq.
verdict_audit_read_json_snapshot() {  # dossier-path
  verdict_audit_read_regular_state "$1" 1048576 json
}

# Normalize exactly one verdict dossier only when it matches the published wire contract.
# Legacy/manual dossiers may omit `generation`; a present generation is always a string.
# Keeping this policy in one function prevents the runner and Stop gate from drifting on
# which JSON has authority.
verdict_audit_normalize_dossier() {  # JSON on stdin
  jq -ecs '
    def exact_keys($wanted): (keys | sort) == ($wanted | sort);
    def nonempty_line:
      type == "string" and length > 0
      and (explode | all(. != 0 and . != 10 and . != 13));
    def nonempty_text:
      type == "string" and length > 0 and (explode | all(. != 0));
    def valid_proof:
      type == "object"
      and exact_keys(["claim", "kind", "evidence", "method", "status", "blocker"])
      and (.claim | nonempty_line)
      and (.kind == "fix-works" or .kind == "tests-pass"
           or .kind == "root-cause" or .kind == "removal-safe"
           or .kind == "finding" or .kind == "factual" or .kind == "other")
      and (.evidence | nonempty_text)
      and (.method == "structural" or .method == "transcript"
           or .method == "rerun" or .method == "two-side")
      and (.status == "verified" or .status == "blocked")
      and (if .status == "verified"
           then .blocker == null
           else (.blocker | nonempty_line)
           end);
    if length == 1
       and (.[0] | type) == "object"
       and ((.[0] | exact_keys(["branch", "head", "tree_hash", "verdict", "proof", "findings"]))
            or (.[0] | exact_keys(["branch", "head", "tree_hash", "generation", "verdict", "proof", "findings"])))
       and (.[0].branch | type) == "string"
       and (.[0].head | type) == "string"
       and (.[0].tree_hash | type) == "string"
       and ((.[0] | has("generation") | not) or (.[0].generation | type) == "string")
       and (.[0].verdict == "PASS" or .[0].verdict == "FAIL"
            or .[0].verdict == "IN_PROGRESS")
       and (.[0].proof | type) == "array"
       and all(.[0].proof[]; valid_proof)
       and (.[0].findings | type) == "array"
       and all(.[0].findings[]; nonempty_line)
       and (if .[0].verdict == "PASS"
            then (.[0].findings | length) == 0
            else (.[0].findings | length) > 0
            end)
    then .[0]
    else empty
    end
  '
}

# Perl's syscalls keep source and destination exact. BSD `mv file directory` and
# `ln file directory` reinterpret the destination as a container, which can hide the
# selected state object under an attacker-created directory.
verdict_audit_rename_exact() {  # source destination
  perl -e 'rename($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"
}

verdict_audit_restore_no_clobber() {  # quarantined-path stable-path
  if perl -e 'link($ARGV[0], $ARGV[1]) or exit 1' "$1" "$2"; then
    rm -f "$1"
    return 0
  fi
  return 1
}

# Two-phase restore for callers that must revalidate external authority after publishing
# the stable name. Retaining the quarantine hardlink preserves an exact inode identity;
# if authority changes, only that same published inode can be retracted.
verdict_audit_link_no_clobber_identity() {  # quarantined-path stable-path
  perl -e '
    my ($source, $destination) = @ARGV;
    my @source_before = lstat($source);
    exit 1 unless @source_before && -f _;
    link($source, $destination) or exit 1;
    my @source_after = lstat($source);
    my @destination = lstat($destination);
    my $linked = @destination
      && $destination[0] == $source_before[0]
      && $destination[1] == $source_before[1];
    if (!@source_after || !$linked
        || $source_after[0] != $source_before[0]
        || $source_after[1] != $source_before[1]) {
      if ($linked) {
        my @current = lstat($destination);
        unlink($destination) if @current
          && $current[0] == $source_before[0]
          && $current[1] == $source_before[1];
      }
      exit 1;
    }
    print $source_before[0], ":", $source_before[1];
  ' "$1" "$2"
}

verdict_audit_link_no_clobber() {  # quarantined-path stable-path
  verdict_audit_link_no_clobber_identity "$1" "$2" >/dev/null
}

verdict_audit_unlink_if_identity() {  # stable-path expected-device:inode
  local stable_path="$1" expected_identity="$2"
  local selected_path="${1}.unlink-$$-${RANDOM:-0}"
  verdict_audit_rename_exact "$stable_path" "$selected_path" 2>/dev/null || return 1
  if verdict_audit_selected_identity_matches \
      "$selected_path" "$expected_identity" 2>/dev/null; then
    rm -f "$selected_path"
    return 0
  fi
  verdict_audit_restore_no_clobber \
    "$selected_path" "$stable_path" 2>/dev/null || return 2
  return 1
}

verdict_audit_unlink_if_same_inode() {  # stable-path quarantined-path
  local owned_identity
  owned_identity="$(verdict_audit_path_identity "$2" 2>/dev/null)" || return 1
  verdict_audit_unlink_if_identity "$1" "$owned_identity"
}

# Capture and compare lstat identity around a rename. This lets callers distinguish the
# object they observed before an epoch check from a replacement that appeared afterward,
# without trusting pathname contents or timestamps.
verdict_audit_path_identity() {  # path
  perl -e '
    my @selected = lstat($ARGV[0]);
    exit 1 unless @selected;
    print $selected[0], ":", $selected[1];
  ' "$1"
}

verdict_audit_selected_identity_matches() {  # selected-path device:inode
  perl -e '
    my ($path, $expected) = @ARGV;
    exit 1 unless $expected =~ /\A[0-9]+:[0-9]+\z/;
    my @selected = lstat($path);
    exit 1 unless @selected;
    exit(($selected[0] . ":" . $selected[1]) eq $expected ? 0 : 1);
  ' "$1" "$2"
}

# A PID is only an observation; pair it with the process start instant before trusting
# persisted metadata across crashes. ps(1) exposes the same portable lstart field on the
# macOS and Linux hosts supported by this plugin, and cksum makes it one record token.
verdict_audit_process_start_token() {  # pid
  local started checksum bytes extra
  [[ "$1" =~ ^[1-9][0-9]*$ ]] || return 1
  started="$(ps -p "$1" -o lstart= 2>/dev/null)" || return 1
  [[ -n "$started" ]] || return 1
  read -r checksum bytes extra <<< "$(printf '%s' "$started" | cksum)"
  [[ "$checksum" =~ ^[0-9]+$ && "$bytes" =~ ^[0-9]+$ && -z "$extra" ]] || return 1
  printf 'cksum-%s-%s' "$checksum" "$bytes"
}

# A repository handoff may be read by every process in that checkout. Bind it to the
# long-lived harness process that launched the originating hook, then require later git
# hooks to descend from that same live process. The start token closes PID-reuse races.
verdict_audit_process_has_ancestor() {  # ancestor-pid ancestor-start-token [start-pid]
  local expected_pid="$1" expected_token="$2" current_pid="${3:-$$}" parent_pid token
  local depth=0
  [[ "$expected_pid" =~ ^[1-9][0-9]*$ \
     && "$expected_token" =~ ^cksum-[0-9]+-[0-9]+$ \
     && "$current_pid" =~ ^[1-9][0-9]*$ ]] || return 1
  while (( depth < 64 )); do
    if [[ "$current_pid" == "$expected_pid" ]]; then
      token="$(verdict_audit_process_start_token "$current_pid" 2>/dev/null)" || return 1
      [[ "$token" == "$expected_token" ]]
      return $?
    fi
    parent_pid="$(ps -p "$current_pid" -o ppid= 2>/dev/null)" || return 1
    parent_pid="${parent_pid//[[:space:]]/}"
    [[ "$parent_pid" =~ ^[1-9][0-9]*$ && "$parent_pid" != "$current_pid" ]] || return 1
    current_pid="$parent_pid"
    depth=$((depth + 1))
  done
  return 1
}

# Write stdin only when the exact destination path does not already exist. O_EXCL and
# O_NONBLOCK make a pre-created FIFO/symlink/directory a fast error; inode checks prove
# the opened descriptor is the regular file now named at that path.
verdict_audit_write_exclusive_regular() {  # destination-path
  perl -MFcntl=:DEFAULT -e '
    my $path = shift;
    my $flags = O_WRONLY | O_CREAT | O_EXCL | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags, 0600) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    my $remove_owned = sub {
      my @current = lstat($path);
      unlink($path) if @current
        && $opened[0] == $current[0] && $opened[1] == $current[1];
    };
    if (!@opened || !@named || !-f $fh
        || $opened[0] != $named[0] || $opened[1] != $named[1]) {
      $remove_owned->() if @opened;
      exit 1;
    }
    binmode(STDIN);
    binmode($fh);
    while (1) {
      my $chunk = "";
      my $read = sysread(STDIN, $chunk, 65536);
      if (!defined $read) { $remove_owned->(); exit 1 }
      last if $read == 0;
      my $offset = 0;
      while ($offset < length($chunk)) {
        my $written = syswrite($fh, $chunk, length($chunk) - $offset, $offset);
        if (!defined $written || $written == 0) { $remove_owned->(); exit 1 }
        $offset += $written;
      }
    }
    close($fh) or do { $remove_owned->(); exit 1 };
  ' "$1"
}

# Atomic replacement for small state records. The caller supplies bytes on stdin.
verdict_audit_write_atomic() {  # destination-path
  local destination="$1" temporary="${1}.tmp.$$-${RANDOM:-0}"
  if ! verdict_audit_write_exclusive_regular "$temporary"; then
    rm -f "$temporary" 2>/dev/null || true
    return 1
  fi
  if ! verdict_audit_rename_exact "$temporary" "$destination"; then
    rm -f "$temporary" 2>/dev/null || true
    return 1
  fi
}

# Remove only the exact record body the caller previously authorized. Renaming first
# selects one inode; a replacement written before selection is restored, and one written
# afterward remains untouched at the stable path.
verdict_audit_remove_record_if_matches() {  # record-path expected-body
  local record_path="$1" expected_body="$2"
  local quarantine="${1}.retire.$$-${RANDOM:-0}" actual_body
  verdict_audit_rename_exact "$record_path" "$quarantine" 2>/dev/null || return 1
  if actual_body="$(verdict_audit_read_single_record "$quarantine" 2>/dev/null)" \
     && [[ "$actual_body" == "$expected_body" ]]; then
    rm -f "$quarantine"
    return 0
  fi
  verdict_audit_restore_no_clobber "$quarantine" "$record_path" 2>/dev/null || return 2
  return 1
}

# Last-resort revocation when the containing directory cannot accept a rename or sibling
# tombstone. Mutate only the already-authorized regular inode after an exclusive lock and
# two pathname-identity checks. The replacement text is deliberately outside the request
# grammar, so a later Stop cannot reload the canceled generation.
verdict_audit_invalidate_record_if_matches() {  # record-path expected-body
  perl -MFcntl=:DEFAULT,:flock -e '
    my ($path, $expected) = @ARGV;
    $SIG{ALRM} = sub { exit 1 };
    alarm 1;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDWR | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags) or exit 1;
    flock($fh, LOCK_EX) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    my $body = "";
    while (length($body) <= 4096) {
      my $chunk = "";
      my $count = sysread($fh, $chunk, 4097 - length($body));
      exit 1 unless defined $count;
      last if $count == 0;
      $body .= $chunk;
    }
    exit 1 if length($body) > 4096 || $body =~ /[\0\r]/;
    $body =~ s/\n\z//;
    exit 1 unless $body eq $expected;
    @named = lstat($path);
    exit 1 unless @named
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    truncate($fh, 0) or exit 1;
    seek($fh, 0, 0) or exit 1;
    print {$fh} "revoked\n" or exit 1;
    close($fh) or exit 1;
    alarm 0;
  ' "$1" "$2"
}

# Best-effort bounded decision logging on one selected regular inode. Unsafe path types
# are rejected without opening, and an oversized/corrupt history is replaced by the new
# line rather than read without bound.
verdict_audit_append_log_line() {  # log-path line-without-LF
  perl -MFcntl=:DEFAULT,:flock -e '
    my ($path, $line) = @ARGV;
    $SIG{ALRM} = sub { exit 1 };
    alarm 1;
    exit 1 if $line =~ /[\0\r\n]/;
    exit 1 if lstat($path) && -l _;
    my $flags = O_RDWR | O_CREAT | O_NONBLOCK;
    $flags |= Fcntl::O_NOFOLLOW() if defined &Fcntl::O_NOFOLLOW;
    sysopen(my $fh, $path, $flags, 0600) or exit 1;
    my @opened = stat($fh);
    my @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    flock($fh, LOCK_EX | LOCK_NB) or exit 1;
    @opened = stat($fh);
    @named = lstat($path);
    exit 1 unless @opened && @named && -f $fh && $opened[3] == 1
      && $opened[0] == $named[0] && $opened[1] == $named[1];
    my @lines = ();
    if ($opened[7] <= 1048576) {
      seek($fh, 0, 0) or exit 1;
      local $/;
      my $body = <$fh> // "";
      @lines = split(/\n/, $body);
    }
    push @lines, $line;
    @lines = @lines[-500 .. -1] if @lines > 1000;
    truncate($fh, 0) or exit 1;
    seek($fh, 0, 0) or exit 1;
    print {$fh} join("\n", @lines), "\n" or exit 1;
    close($fh) or exit 1;
    alarm 0;
  ' "$1" "$2"
}

# Hash an untrusted harness session id into one whitespace-free lock field. Empty is a
# deliberate legacy/manual scope. Git is already required by both callers and supports
# SHA-1 and SHA-256 repositories, so accept either output length at the read boundary.
verdict_audit_scope_identity() {  # raw-session-id git-repo
  [[ -n "$1" ]] || { printf '-'; return; }
  local object_id
  object_id="$(printf '%s' "$1" | git -C "$2" hash-object --stdin)" || return 1
  [[ "$object_id" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  printf 'git-%s' "$object_id"
}

# Hook payloads can carry control characters that shell command substitution cannot
# preserve at the end of a string. Stream the JSON value straight into Git instead of
# round-tripping it through a shell variable; the resulting hash stays identical to the
# raw-argument helper above for every byte sequence.
verdict_audit_scope_from_hook_payload() {  # hook-payload git-repo
  local object_id
  object_id="$(printf '%s' "$1" | jq -j -e '
    if (.session_id | type) == "string" and (.session_id | length) > 0
    then .session_id
    else error("missing session id")
    end
  ' | git -C "$2" hash-object --stdin)" || return 1
  [[ "$object_id" =~ ^[0-9a-f]{40}([0-9a-f]{24})?$ ]] || return 1
  printf 'git-%s' "$object_id"
}

# Keep legacy/manual invocations on their established path. Harness sessions get one
# opaque suffix shared by request, lock, dossier, and gate bookkeeping, so tasks using
# the same worktree cannot consume or cancel each other's runtime state.
verdict_audit_state_path() {  # base-path session-scope
  if [[ "$2" == "-" ]]; then
    printf '%s' "$1"
  else
    printf '%s.%s' "$1" "$2"
  fi
}

# INT/TERM has no UserPromptSubmit hook to revoke a session request. A generation-named
# tombstone gives the Stop gate an atomic, pathname-local way to reject late output from
# exactly that canceled run without racing a newer generation's request or dossier.
verdict_audit_cancellation_path() {  # state-dir session-scope generation
  printf '%s.%s' "$(verdict_audit_state_path "$1/verdict-canceled" "$2")" "$3"
}

# Cancellation is fail-closed. The canonical generation pathname itself (of any type)
# revokes authority, and a runner that cannot publish there may use one unpredictable
# fallback sibling. Literal directory scanning avoids shell-glob metacharacters in roots.
verdict_audit_cancellation_exists() {  # canonical-cancellation-path
  [[ -e "$1" || -L "$1" ]] && return 0
  perl -e '
    my $path = shift;
    my $slash = rindex($path, "/");
    exit 1 if $slash < 0;
    my $directory = substr($path, 0, $slash);
    my $prefix = substr($path, $slash + 1) . ".fallback-";
    opendir(my $dir, $directory) or exit 1;
    while (defined(my $entry = readdir($dir))) {
      if (index($entry, $prefix) == 0) { closedir($dir); exit 0 }
    }
    closedir($dir);
    exit 1;
  ' "$1"
}

verdict_audit_clear_cancellation_records() {  # canonical-cancellation-path
  perl -e '
    my $path = shift;
    unlink($path);
    my $slash = rindex($path, "/");
    exit 0 if $slash < 0;
    my $directory = substr($path, 0, $slash);
    my $prefix = substr($path, $slash + 1) . ".fallback-";
    if (opendir(my $dir, $directory)) {
      while (defined(my $entry = readdir($dir))) {
        unlink($directory . "/" . $entry) if index($entry, $prefix) == 0;
      }
      closedir($dir);
    }
  ' "$1"
}
